// Debug aid: real-time video capture. With BOF4_CAPTURE=<file.mkv>, the
// window pictures shown from present BOF4_CAPTURE_FROM on (default 1) are
// piped to ffmpeg as a 60 fps video on the wall clock: when a picture comes
// late (a stall, a frozen frame), the one before is repeated for the time it
// stayed up, so the video plays at the pace the window showed. Run paced
// (without BOF4_FAST). Matroska survives the process being killed; ffmpeg
// must be on the PATH.
package psx

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

@(private = "file")
capture: struct {
	path: string,
	from: u64,
	pipe: ^os.File, // ffmpeg's stdin
	ffmpeg: os.Process,
	size: [2]i32,
	start: time.Tick, // when the first picture was sent
	sent: i64, // video frames written
	last: []u8, // the picture sent before
	dead: bool, // the pipe failed: capture no more
}

@(private)
capture_init :: proc() {
	capture.path = os.get_env("BOF4_CAPTURE", context.allocator)
	capture.from = 1
	if n, ok := strconv.parse_u64(os.get_env("BOF4_CAPTURE_FROM", context.temp_allocator)); ok {
		capture.from = n
	}
}

// Send the window's back buffer, called just before it is presented.
@(private)
capture_frame :: proc() {
	if capture.path == "" || capture.dead || preload_child || host.presents < capture.from {
		return
	}
	pix, w, h, ok := window_pixels()
	if !ok {
		return
	}
	if capture.pipe == nil {
		cmd := []string{
			"ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pixel_format", "rgb24",
			"-video_size", fmt.tprintf("%dx%d", w, h), "-framerate", fmt.tprint(CAPTURE_FPS),
			"-i", "-", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "18", capture.path,
		}
		r, pw, pipe_err := os.pipe()
		if pipe_err != nil {
			fmt.eprintln("BOF4_CAPTURE: cannot start ffmpeg")
			capture.dead = true
			return
		}
		ffmpeg, start_err := os.process_start({command = cmd, stdin = r, stdout = os.stdout, stderr = os.stderr})
		os.close(r)
		if start_err != nil {
			os.close(pw)
			fmt.eprintln("BOF4_CAPTURE: cannot start ffmpeg")
			capture.dead = true
			return
		}
		capture.pipe, capture.ffmpeg = pw, ffmpeg
		capture.size = {w, h}
		capture.start = time.tick_now()
		capture.last = make([]u8, len(pix))
		fmt.eprintfln("capture: %dx%d to %s from present %d", w, h, capture.path, host.presents)
	}
	if capture.size != {w, h} {
		return // the window was resized: ffmpeg takes one size
	}
	// The frame the wall clock is at; the picture before stays up until it.
	due := i64(time.tick_since(capture.start)) * CAPTURE_FPS / i64(time.Second)
	for capture.sent > 0 && capture.sent < due {
		capture_write(capture.last)
	}
	capture_write(pix)
	copy(capture.last, pix)
}

@(private = "file")
CAPTURE_FPS :: 60

@(private = "file")
capture_write :: proc(pix: []u8) {
	if capture.dead {
		capture.sent += 1
		return
	}
	if n, err := os.write(capture.pipe, pix); err != nil || n != len(pix) {
		fmt.eprintln("BOF4_CAPTURE: ffmpeg stopped taking frames")
		capture.dead = true
	}
	capture.sent += 1
}

@(private)
capture_close :: proc() {
	if capture.pipe != nil {
		os.close(capture.pipe)
		capture.pipe = nil
		_, _ = os.process_wait(capture.ffmpeg)
	}
}
