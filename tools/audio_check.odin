// Check what the host played for dropouts, and the game's audio report.
//
// The played stream is a recording of the output device, for example a
// PipeWire null sink's monitor taken with pw-record during a paced run (see
// tools/audio_test.sh). A dropout (the host queue ran dry, or the device
// thread came late) is a run of silence inside sound: at least `--gap` ms
// quieter than `--floor`, with sound on both sides.
//
// With the run's log (BOF4_TRACE=perf), the .Perf audio lines are listed
// too: "audio mixed" should be 44100.0 Hz (the host corrects at most 0.5%
// off it), the queue's lowest level should stay above 0, and "ran dry" /
// "dropped" should be 0 outside fast-forward.
package tools

import "core:strconv"
import "core:strings"

AUDIO_CHECK_USAGE :: `Usage: bof4tools audio-check <played.wav> [log] [--gap=ms] [--floor=level]
  --gap    shortest dropout reported, ms (3.0)
  --floor  largest sample counted as silent (2.0)`

Wav :: struct {
	hz:       int,
	channels: int,
	frames:   int,
	data:     []u8, // s16 little-endian, interleaved
}

wav_read :: proc(path: string) -> Wav {
	d := read_file(path)
	if len(d) < 12 || string(d[0:4]) != "RIFF" || string(d[8:12]) != "WAVE" {
		fail("%s: not a WAV file", path)
	}
	w: Wav
	bits := 0
	for pos := 12; pos + 8 <= len(d); {
		size := int(u32le(d, pos + 4))
		body := d[pos + 8:min(pos + 8 + size, len(d))]
		switch string(d[pos:pos + 4]) {
		case "fmt ":
			w.channels, w.hz, bits = int(u16le(body, 2)), int(u32le(body, 4)), int(u16le(body, 14))
		case "data":
			w.data = body
		}
		pos += 8 + size + size % 2
	}
	if bits != 16 || w.channels == 0 {
		fail("%s: need s16", path)
	}
	w.frames = len(w.data) / (2 * w.channels)
	return w
}

// The mean of `level` over [lo, hi) clipped to it; 0 when that is empty.
level_mean :: proc(level: []i32, from, to: int) -> f64 {
	lo, hi := max(from, 0), min(to, len(level))
	if hi <= lo {
		return 0
	}
	sum: f64
	for v in level[lo:hi] {
		sum += f64(v)
	}
	return sum / f64(hi - lo)
}

audio_check_main :: proc(args: []string) {
	gap, floor := 3.0, 2.0
	paths: [dynamic]string
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		for opt in ([]string{"--gap", "--floor"}) {
			if a != opt && !strings.has_prefix(a, concat(opt, "=")) {
				continue
			}
			text := a[min(len(opt) + 1, len(a)):]
			if a == opt {
				i += 1
				if i == len(args) {
					fail("%s", AUDIO_CHECK_USAGE)
				}
				text = args[i]
			}
			v, ok := strconv.parse_f64(text)
			if !ok {
				fail("%s: not a number: %s", opt, text)
			}
			(opt == "--gap" ? &gap : &floor)^ = v
			a = ""
		}
		if a != "" {
			append(&paths, a)
		}
	}
	usage(paths[:], AUDIO_CHECK_USAGE, 1, 2)

	w := wav_read(paths[0])
	level := make([]i32, w.frames)
	loud: [dynamic]int
	for f in 0 ..< w.frames {
		for c in 0 ..< w.channels {
			level[f] = max(level[f], abs(i32(i16le(w.data, 2 * (f * w.channels + c)))))
		}
		if f64(level[f]) > floor {
			append(&loud, f)
		}
	}
	hz := w.hz
	print("played %.1f s at %d Hz", f64(w.frames) / f64(hz), hz)
	gaps := 0
	// Silent runs between two sounding samples.
	need := int(gap * f64(hz) / 1000)
	for k in 0 ..< max(len(loud) - 1, 0) {
		d := loud[k + 1] - loud[k]
		if d <= need {
			continue
		}
		at, length := loud[k] + 1, d - 1
		// Sound on both sides: not a quiet passage or the music's end.
		if level_mean(level, at - hz / 50, at) > 64 && level_mean(level, at + length, at + length + hz / 50) > 64 {
			gaps += 1
			print("% 8.3f s  dropout %.1f ms", f64(at) / f64(hz), f64(length) / f64(hz) * 1000)
		}
	}
	print("%d dropouts", gaps)

	if len(paths) < 2 {
		return
	}
	for line in strings.split_lines(string(read_file(paths[1]))) {
		if vblank, text, ok := perf_line(strings.trim_right_space(line)); ok {
			print("vblank %6s  %s", vblank, text)
		}
	}
}

// A trace line "<vblank> <n> Perf <text>" whose text is about audio.
perf_line :: proc(line: string) -> (vblank, text: string, ok: bool) {
	digits :: proc(s: string) -> int {
		n := 0
		for n < len(s) && s[n] >= '0' && s[n] <= '9' {
			n += 1
		}
		return n
	}
	a := digits(line)
	if a == 0 || a == len(line) || line[a] != ' ' {
		return
	}
	b := digits(line[a + 1:])
	rest := line[a + 1 + b:]
	if b == 0 || !strings.has_prefix(rest, " Perf ") {
		return
	}
	text = rest[len(" Perf "):]
	for word in ([]string{"audio", "ran dry", "late vblank", "fast-forward"}) {
		if strings.contains(text, word) {
			return line[:a], text, true
		}
	}
	return
}
