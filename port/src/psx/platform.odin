// Host window, frame pacing and controller input (SDL2).
package psx

import "base:runtime"
import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import sdl "vendor:sdl2"

WINDOW_W :: 640
WINDOW_H :: 480
// NTSC field rate.
VBLANK_NS :: 1_000_000_000 / 60

PAD_SELECT :: 0x0100
PAD_START :: 0x0800
PAD_UP :: 0x1000
PAD_RIGHT :: 0x2000
PAD_DOWN :: 0x4000
PAD_LEFT :: 0x8000
PAD_L2 :: 0x0001
PAD_R2 :: 0x0002
PAD_L1 :: 0x0004
PAD_R1 :: 0x0008
PAD_TRIANGLE :: 0x0010
PAD_CIRCLE :: 0x0020
PAD_CROSS :: 0x0040
PAD_SQUARE :: 0x0080

@(private)
host: struct {
	window:      ^sdl.Window,
	renderer:    ^sdl.Renderer,
	texture:     ^sdl.Texture,
	// The picture a hold keeps on screen (hold_picture), shown while it
	// lasts and then faded out over the live one for `fade` presents: the
	// texture the window showed when the hold began, of size `held_area`.
	held:        ^sdl.Texture,
	held_area:   sdl.Rect,
	holding:     bool,
	fade:        int,
	// Size of the picture last put in `texture`.
	shown_w:     i32,
	shown_h:     i32,
	// Displayed area converted to XRGB8888, at the shown target's
	// resolution (render_scale_apply).
	converted:   []u32,
	// The picture this vblank shows: `converted`, or an extra picture of a
	// frozen-time pass (shown in place, not copied). Nil while it is a GL
	// frame slot's still converting: read it through frame_pixels.
	frame:       []u32,
	// The GL frame slot the picture is the buffer of (gl_frame_take), or -1.
	frame_slot:  int,
	// The GL conversions (Gl_Frame.mark) of this present's picture and the
	// last one's, -1 when none.
	frame_mark:  int,
	last_mark:   int,
	// Pacing origin: emulated vblank N is due at start + N * VBLANK_NS / speed.
	start:       time.Tick,
	// Emulated time per real time; 1 is the console's own speed.
	speed:       f64,
	perf_mark:   time.Tick,
	// End of the last vblank's pacing wait: the emulation and drawing of a
	// vblank are timed from here (.Perf "late vblank" lines; not with vsync,
	// whose wait is in the present).
	work_mark:   time.Tick,
	unpaced:     bool,
	// Whether RenderPresent waits for the display's vblank (see vsync_update),
	// and how many display refreshes each emulated vblank is shown for.
	vsync:       bool,
	vsync_shows: int,
	// Pacing is off while the disc loads (instant_loading) or the screen is
	// black (skip_black).
	fast:        bool,
	// Whether the last present showed nothing but black (see skip_black).
	black:       bool,
	// Presents in a row, while the disc loads, whose picture matched the
	// one before (see instant_loading), and that picture's hash.
	still:       u64,
	still_hash:  u64,
	// When the current fast-forward began, for the perf trace.
	fast_start:  time.Tick,
	fast_vblank: u64,
	quit:        bool,
	presents:    u64,
	// Display area (x, y, w, h) at the previous present, to tell a repeated
	// game frame from a new one.
	last_area:   [4]i32,
	dump_dir:    string,
	// BOF4_DUMP_RAM: presents between main RAM dumps into dump_dir.
	ram_every:   u64,
	// BOF4_DUMP_EVERY: presents between frame dumps into dump_dir.
	frame_every: u64,
	// BOF4_DUMP_FROM: first present whose frame is dumped.
	dump_from:   u64,
	// BOF4_DUMP_WINDOW=1: frame dumps also save the finished window picture.
	dump_window: bool,
	script:      [dynamic]Scripted_Press,
	stick_script: [dynamic]Scripted_Stick,
	poke_script: [dynamic]Scripted_Poke,
	drag_script: [dynamic]Scripted_Drag,
	audio_dev:   sdl.AudioDeviceID,
	// The audio subsystem started; audio_apply opens the device.
	audio_ok:    bool,
	// Frames to keep in the host queue, from the latency setting.
	audio_target: int,
	// Since the last .Perf report: times the queue ran dry, and batches
	// dropped for a queue over target.
	audio_dry:     int,
	audio_dropped: int,
	// Since the last .Perf report: frames mixed, which over the cycles run
	// should come to 44100 Hz (the host can only correct AUDIO_RATE_MAX
	// off it), and the lowest the host queue was when a batch came.
	audio_mixed:   int,
	audio_low:     int,
	perf_cycles:   u64,
	// Resampling state: output position within the batch being read (in
	// input frames), and the last input frame of the previous batch.
	stretch_pos:  f64,
	stretch_prev: [2]i16,
	stretch_buf:  [AUDIO_STRETCH_MAX][2]i16,
	// Zeros queued after the device ran dry.
	silence:      [AUDIO_HZ * AUDIO_LATENCY_MAX / 1000][2]i16,
	// BOF4_AUDIO_DUMP: raw s16le stereo 44100 Hz copy of everything mixed.
	audio_dump:  ^os.File,
}

@(private)
AUDIO_HZ :: 44100

// Range of the output latency setting, in ms: queued sound plus the device's
// own buffer.
AUDIO_LATENCY_MIN :: 20
AUDIO_LATENCY_MAX :: 250

// Largest playback rate correction that keeps the queue at its target: 0.5%,
// about 9 cents of pitch.
@(private)
AUDIO_RATE_MAX :: 0.005

// Queue beyond the target before new batches are dropped: two vblanks of
// sound. Paced emulation makes a vblank's sound in one burst, so the queue
// swings by one vblank; it outgrows this only while emulation runs ahead
// (battle speed). During fast-forward batches are dropped from the target
// on, so the queue is not left long when pacing resumes.
@(private)
AUDIO_SLACK :: AUDIO_HZ * 2 / 60

// Slowest emulated speed. Audio below speed 1 is stretched to fill real
// time, into a buffer sized for this.
MIN_SPEED :: 0.25

// One mixed batch stretched for the slowest speed, plus one frame for the
// rate correction (0.5% of 128 frames) and one for the fractional frame a
// stretch can carry over.
@(private)
AUDIO_STRETCH_MAX :: int(SPU_BATCH / MIN_SPEED) + 2

// Debug aid: BOF4_INPUT="<present>:<hex mask>[:<presents>],..." holds each
// mask from the given present count, for SCRIPT_HOLD presents by default.
@(private)
Scripted_Press :: struct {
	at:   u64,
	mask: u16,
	hold: u64,
}

@(private)
SCRIPT_HOLD :: 4

@(private)
parse_script :: proc(spec: string) {
	for item in strings.split(spec, ",", context.temp_allocator) {
		parts := strings.split(item, ":", context.temp_allocator)
		if len(parts) != 2 && len(parts) != 3 {
			fmt.eprintln("BOF4_INPUT: bad entry", item)
			continue
		}
		at, at_ok := strconv.parse_u64(parts[0])
		mask, mask_ok := strconv.parse_u64(parts[1], 16)
		hold, hold_ok := u64(SCRIPT_HOLD), true
		if len(parts) == 3 {
			hold, hold_ok = strconv.parse_u64(parts[2])
		}
		if !at_ok || !mask_ok || !hold_ok {
			fmt.eprintln("BOF4_INPUT: bad entry", item)
			continue
		}
		append(&host.script, Scripted_Press{at, u16(mask), hold})
	}
}

// Debug aid: BOF4_STICK="<present>:<lx>/<ly>/<rx>/<ry>[:<presents>],..."
// holds analog stick positions (-1..1, after the dead zone) the same way.
@(private)
Scripted_Stick :: struct {
	at:     u64,
	sticks: Sticks,
	hold:   u64,
}

@(private)
parse_stick_script :: proc(spec: string) {
	for item in strings.split(spec, ",", context.temp_allocator) {
		parts := strings.split(item, ":", context.temp_allocator)
		axes := strings.split(len(parts) >= 2 ? parts[1] : "", "/", context.temp_allocator)
		ok := (len(parts) == 2 || len(parts) == 3) && len(axes) == 4
		e := Scripted_Stick{hold = SCRIPT_HOLD}
		at_ok, hold_ok := false, true
		if ok {
			e.at, at_ok = strconv.parse_u64(parts[0])
			if len(parts) == 3 {
				e.hold, hold_ok = strconv.parse_u64(parts[2])
			}
			v: [4]f32
			for a, i in axes {
				f, f_ok := strconv.parse_f32(a)
				ok = ok && f_ok && f >= -1 && f <= 1
				v[i] = f
			}
			e.sticks = {left = {v[0], v[1]}, right = {v[2], v[3]}}
		}
		if !ok || !at_ok || !hold_ok {
			fmt.eprintln("BOF4_STICK: bad entry", item)
			continue
		}
		append(&host.stick_script, e)
	}
}

// Debug aid: BOF4_POKE="<present>:<hex addr>:<hex byte>,..." stores a byte
// into main RAM at the given present, to drive game state no route reaches.
@(private)
Scripted_Poke :: struct {
	at:    u64,
	addr:  u32,
	value: u8,
}

@(private)
parse_poke_script :: proc(spec: string) {
	for item in strings.split(spec, ",", context.temp_allocator) {
		parts := strings.split(item, ":", context.temp_allocator)
		if len(parts) != 3 {
			fmt.eprintln("BOF4_POKE: bad entry", item)
			continue
		}
		at, at_ok := strconv.parse_u64(parts[0])
		addr, addr_ok := strconv.parse_u64(parts[1], 16)
		value, value_ok := strconv.parse_u64(parts[2], 16)
		if !at_ok || !addr_ok || !value_ok || value > 0xff || addr & 0x1fffffff >= RAM_SIZE {
			fmt.eprintln("BOF4_POKE: bad entry", item)
			continue
		}
		append(&host.poke_script, Scripted_Poke{at, u32(addr), u8(value)})
	}
}

@(private)
run_poke_script :: proc() {
	for e in host.poke_script {
		if e.at == host.presents {
			mem_slice(e.addr, 1)[0] = e.value
		}
	}
}

platform_init :: proc(title: cstring) -> bool {
	if sdl.Init({.VIDEO, .EVENTS, .GAMECONTROLLER}) != 0 {
		fmt.eprintln("SDL_Init:", sdl.GetError())
		return false
	}
	input_init()
	host.window = sdl.CreateWindow(
		title,
		sdl.WINDOWPOS_CENTERED,
		sdl.WINDOWPOS_CENTERED,
		WINDOW_W * 2,
		WINDOW_H * 2,
		{.RESIZABLE},
	)
	if host.window == nil {
		fmt.eprintln("SDL_CreateWindow:", sdl.GetError())
		return false
	}
	// Focus that arrived before the first event poll; later changes come as
	// window events.
	mouse.focused = .INPUT_FOCUS in sdl.GetWindowFlags(host.window)
	host.renderer = sdl.CreateRenderer(host.window, -1, {.ACCELERATED})
	if host.renderer == nil {
		fmt.eprintln("SDL_CreateRenderer:", sdl.GetError())
		return false
	}
	sdl.RenderSetLogicalSize(host.renderer, WINDOW_W, WINDOW_H)
	gl_init()
	if !render_scale_apply() {
		return false
	}
	host.start = time.tick_now()
	host.speed = 1
	host.perf_mark = host.start
	host.audio_low = max(int)
	host.dump_dir = os.get_env("BOF4_DUMP", context.allocator)
	host.unpaced = os.get_env("BOF4_FAST", context.temp_allocator) == "1"
	host.ram_every = env_period("BOF4_DUMP_RAM", 1500) or_return
	host.frame_every = env_period("BOF4_DUMP_EVERY", 30) or_return
	host.dump_from = env_period("BOF4_DUMP_FROM", 1) or_return
	capture_init()
	sprite_dump_init()
	host.dump_window = host.dump_dir != "" && os.get_env("BOF4_DUMP_WINDOW", context.temp_allocator) == "1"
	// Debug aid: BOF4_OSD_PANEL=<n> starts with the panel shown on page n
	// (from 1).
	if page, ok := strconv.parse_int(os.get_env("BOF4_OSD_PANEL", context.temp_allocator)); ok && page > 0 {
		osd_panel_shown = true
		osd_panel_page = page - 1
	}
	if spec := os.get_env("BOF4_INPUT", context.temp_allocator); spec != "" {
		parse_script(spec)
	}
	if spec := os.get_env("BOF4_STICK", context.temp_allocator); spec != "" {
		parse_stick_script(spec)
	}
	if spec := os.get_env("BOF4_POKE", context.temp_allocator); spec != "" {
		parse_poke_script(spec)
	}
	if spec := os.get_env("BOF4_DRAG", context.temp_allocator); spec != "" {
		parse_drag_script(spec)
	}
	return record_init() && audio_init()
}

// Start the audio subsystem. A missing device leaves the game silent but
// running; a dump file that cannot be created is an error.
@(private)
audio_init :: proc() -> bool {
	if path := os.get_env("BOF4_AUDIO_DUMP", context.temp_allocator); path != "" {
		f, err := os.create(path)
		if err != nil {
			fmt.eprintln("BOF4_AUDIO_DUMP: cannot create", path, err)
			return false
		}
		host.audio_dump = f
	}
	if sdl.InitSubSystem({.AUDIO}) != 0 {
		fmt.eprintln("audio disabled: SDL_InitSubSystem:", sdl.GetError())
		return true
	}
	host.audio_ok = true
	return true
}

// Open the output device for about `latency_ms` from a sound being mixed to
// it reaching the speakers (plus whatever the OS mixer adds). The device
// buffer takes about a quarter of it, as a power of two of 256 frames or
// more; the host queue is kept at the rest.
audio_apply :: proc(latency_ms: int) {
	assert(latency_ms >= AUDIO_LATENCY_MIN && latency_ms <= AUDIO_LATENCY_MAX)
	total := AUDIO_HZ * latency_ms / 1000
	samples := 256
	for samples * 2 <= total / 4 && samples < 4096 {
		samples *= 2
	}
	host.audio_target = total - samples
	if !host.audio_ok {
		return
	}
	if host.audio_dev != 0 {
		sdl.CloseAudioDevice(host.audio_dev)
	}
	want := sdl.AudioSpec {
		freq     = AUDIO_HZ,
		format   = sdl.AUDIO_S16LSB,
		channels = 2,
		samples  = u16(samples),
	}
	host.audio_dev = sdl.OpenAudioDevice(nil, false, &want, nil, {})
	if host.audio_dev == 0 {
		fmt.eprintln("audio disabled: SDL_OpenAudioDevice:", sdl.GetError())
		return
	}
	sdl.PauseAudioDevice(host.audio_dev, false)
}

// A batch of mixed SPU output.
platform_audio :: proc(frames: [][2]i16) {
	bytes := len(frames) * size_of([2]i16)
	host.audio_mixed += len(frames)
	if host.audio_dump != nil {
		if _, err := os.write(host.audio_dump, ([^]u8)(raw_data(frames))[:bytes]); err != nil {
			fmt.eprintln("BOF4_AUDIO_DUMP: write failed:", err)
			os.close(host.audio_dump)
			host.audio_dump = nil
		}
	}
	if host.audio_dev == 0 || host.unpaced || skipping {
		return
	}
	queued := int(sdl.GetQueuedAudioSize(host.audio_dev)) / size_of([2]i16)
	host.audio_low = min(host.audio_low, queued)
	if queued > host.audio_target + (host.fast ? 0 : AUDIO_SLACK) {
		if !host.fast {
			host.audio_dropped += 1
		}
		return
	}
	if queued == 0 {
		host.audio_dry += 1
		if .Perf in trace.active {
			tracef(.Perf, "audio ran dry")
		}
		// Ran dry (a slow frame): refill the target at once, or the rate
		// correction would take seconds and every vblank would click.
		audio_queue(host.silence[:host.audio_target])
	}
	audio_queue(audio_resample(frames, audio_step(queued)))
}

// Input frames per output frame. Below speed 1, sound is stretched to fill
// real time: it plays lower and slower, in step with the picture. On top of
// that, up to AUDIO_RATE_MAX faster or slower keeps the queue at its target
// against drift between the emulated clock and the sound card's.
@(private)
audio_step :: proc(queued: int) -> f64 {
	error := f64(queued - host.audio_target) / f64(host.audio_target)
	return min(host.speed, 1) * (1 + AUDIO_RATE_MAX * clamp(error, -1, 1))
}

// Sound waiting in the host queue, for .Perf reports.
@(private)
audio_queued_ms :: proc() -> f64 {
	if host.audio_dev == 0 {
		return 0
	}
	return f64(sdl.GetQueuedAudioSize(host.audio_dev) / size_of([2]i16)) * 1000 / AUDIO_HZ
}


@(private)
audio_queue :: proc(frames: [][2]i16) {
	bytes := len(frames) * size_of([2]i16)
	if sdl.QueueAudio(host.audio_dev, raw_data(frames), u32(bytes)) != 0 {
		fmt.eprintln("audio disabled: SDL_QueueAudio:", sdl.GetError())
		sdl.CloseAudioDevice(host.audio_dev)
		host.audio_dev = 0
	}
}

// Resample a batch to 1/step times its length by linear interpolation. The
// previous batch's last frame joins the two.
@(private)
audio_resample :: proc(frames: [][2]i16, step: f64) -> [][2]i16 {
	assert(len(frames) <= SPU_BATCH && step >= MIN_SPEED * (1 - AUDIO_RATE_MAX))
	n := 0
	for host.stretch_pos < f64(len(frames)) && n < AUDIO_STRETCH_MAX {
		i := int(host.stretch_pos)
		t := host.stretch_pos - f64(i)
		a := i == 0 ? host.stretch_prev : frames[i - 1]
		b := frames[i]
		for c in 0 ..< 2 {
			host.stretch_buf[n][c] = i16(f64(a[c]) + (f64(b[c]) - f64(a[c])) * t)
		}
		n += 1
		host.stretch_pos += step
	}
	host.stretch_pos -= f64(len(frames))
	if len(frames) > 0 {
		host.stretch_prev = frames[len(frames) - 1]
	}
	return host.stretch_buf[:n]
}

platform_shutdown :: proc() {
	spu_sync()
	record_close()
	capture_close()
	sdl.DestroyTexture(host.texture)
	sdl.DestroyTexture(host.held)
	sdl.DestroyRenderer(host.renderer)
	sdl.DestroyWindow(host.window)
	sdl.Quit()
}

platform_should_quit :: proc() -> bool {
	return host.quit
}

@(private)
poll_events :: proc() {
	ev: sdl.Event
	for sdl.PollEvent(&ev) {
		#partial switch ev.type {
		case .QUIT:
			host.quit = true
		case .KEYDOWN:
			if ev.key.repeat == 0 {
				device_used(.Keyboard)
			}
			if !catch_key(ev.key) && (key_hook == nil || !key_hook(ev.key)) {
				window_key(ev.key)
			}
		case .MOUSEBUTTONDOWN, .MOUSEBUTTONUP:
			if ev.type == .MOUSEBUTTONDOWN {
				device_used(.Keyboard)
			}
			mouse_button(ev.button)
		case .MOUSEMOTION:
			mouse_motion(ev.motion)
		case .MOUSEWHEEL:
			device_used(.Keyboard)
			mouse_wheel(ev.wheel)
		case .CONTROLLERAXISMOTION:
			if abs(i32(ev.caxis.value)) > DEVICE_AXIS_USE {
				device_pad_used(ev.caxis.which)
			}
		case .CONTROLLERBUTTONDOWN:
			device_pad_used(ev.cbutton.which)
			window_button(sdl.GameControllerButton(ev.cbutton.button))
		case .WINDOWEVENT:
			window_event(ev.window)
		case .CONTROLLERDEVICEADDED:
			gamepad_added(ev.cdevice.which)
		case .CONTROLLERDEVICEREMOVED:
			gamepad_removed(sdl.JoystickID(ev.cdevice.which))
		}
	}
}

// Emulated vblanks since power-on: the clock for anything that must advance
// with emulated time rather than with frames drawn.
vblanks :: proc() -> u64 {
	return host.presents
}

// Real nanoseconds from host.start until emulated vblank n is due.
@(private)
vblank_due_ns :: proc(n: u64) -> i64 {
	return i64(f64(n) * VBLANK_NS / host.speed)
}

// Run emulated time at `speed` times real time from the next vblank on.
// Game logic still advances per emulated tick, so this changes only how
// fast those ticks pass in real time. The last vblank keeps its due time, so
// the coming one is due one vblank at the new speed after it, with no gap or
// burst however often the speed changes.
set_speed :: proc(speed: f64) {
	assert(speed >= MIN_SPEED)
	if speed == host.speed {
		return
	}
	if .Perf in trace.active {
		tracef(.Perf, "speed %v -> %v", host.speed, speed)
	}
	last := host.presents - min(host.presents, 1)
	last_due := time.tick_add(host.start, time.Duration(vblank_due_ns(last)))
	host.speed = speed
	host.start = time.tick_add(last_due, -time.Duration(vblank_due_ns(last)))
}

// Refresh rates SDL reports for a display that runs at the console's own
// field rate (59.94 Hz NTSC timings round down).
@(private)
VSYNC_HZ_MIN :: 59
@(private)
VSYNC_HZ_MAX :: 60
// Most display refreshes per emulated vblank (240 Hz).
@(private)
VSYNC_SHOWS_MAX :: 4

// Lock presents to the display's vblank when it refreshes at the console's
// rate or a whole multiple of it (120, 240 Hz) and emulated time runs at
// console speed: every emulated vblank then shows for exactly that many
// display refreshes, with no tearing and no dropped or doubled frame from
// the two clocks drifting apart. The display clock then sets emulated time;
// audio_step absorbs its small difference from 60 Hz. Any other refresh rate
// (144 Hz: 2.4 refreshes a vblank) or speed, or no pacing at all (`paced`
// false), keeps vsync off.
@(private)
vsync_update :: proc(paced: bool) {
	mode: sdl.DisplayMode
	shows := 0
	if paced && host.speed == 1 && sdl.GetWindowDisplayMode(host.window, &mode) == 0 {
		for n in 1 ..= VSYNC_SHOWS_MAX {
			if mode.refresh_rate >= VSYNC_HZ_MIN * i32(n) && mode.refresh_rate <= VSYNC_HZ_MAX * i32(n) {
				shows = n
			}
		}
	}
	want := shows > 0
	host.vsync_shows = max(shows, 1)
	if want == host.vsync {
		return
	}
	if sdl.RenderSetVSync(host.renderer, sdl.bool(want)) != 0 {
		// Backend cannot switch: stay on sleep pacing.
		want = false
	}
	host.vsync = want
	if .Perf in trace.active {
		tracef(.Perf, "vsync %v (%d Hz)", want, mode.refresh_rate)
	}
}

// Make the current vblank due now.
@(private)
pacing_rebase :: proc() {
	host.start = time.tick_add(time.tick_now(), -time.Duration(vblank_due_ns(host.presents)))
}

// A positive present count from the environment variable `name`, or `def`
// when it is unset.
@(private)
env_period :: proc(name: string, def: u64) -> (u64, bool) {
	spec := os.get_env(name, context.temp_allocator)
	if spec == "" {
		return def, true
	}
	n, ok := strconv.parse_u64(spec, 10)
	if !ok || n == 0 {
		fmt.eprintf("%s: expected a positive present count: %s\n", name, spec)
		return 0, false
	}
	return n, true
}

// Debug aid: with BOF4_DUMP=<dir>, write the displayed area every frame_every
// presents and main RAM every ram_every presents, from present dump_from on.
@(private)
dump_frame :: proc() {
	if host.dump_dir == "" {
		return
	}
	if host.presents >= host.dump_from && host.presents % host.ram_every == 0 {
		ram_name := fmt.tprintf("%s/ram_%05d.bin", host.dump_dir, host.presents)
		if err := os.write_entire_file(ram_name, ram[:]); err != nil {
			fmt.eprintln("BOF4_DUMP: ram write failed:", ram_name, err)
		}
	}
	if !frame_dump_due() || display.w <= 0 || display.h <= 0 {
		return
	}
	buf := make([dynamic]u8, context.temp_allocator)
	fw, fh := frame_size()
	header := fmt.tprintf("P6\n%d %d\n255\n", fw, fh)
	append(&buf, ..transmute([]u8)header)
	append(&buf, ..frame_rgb(frame_pixels()[:fw * fh]))
	name := fmt.tprintf("%s/frame_%05d.ppm", host.dump_dir, host.presents)
	if err := os.write_entire_file(name, buf[:]); err != nil {
		fmt.eprintln("BOF4_DUMP: write failed:", name, err)
	}
	if host.presents % 150 == 0 {
		dump_vram()
	}
}

// XRGB8888 pixels as tightly packed RGB888 bytes, in temp memory.
frame_rgb :: proc(px: []u32) -> []u8 {
	out := make([]u8, len(px) * 3, context.temp_allocator)
	for c, i in px {
		out[i * 3] = u8(c >> 16)
		out[i * 3 + 1] = u8(c >> 8)
		out[i * 3 + 2] = u8(c)
	}
	return out
}

// Whether this present's frame is dumped (BOF4_DUMP_FROM, BOF4_DUMP_EVERY).
@(private)
frame_dump_due :: proc() -> bool {
	return host.presents >= host.dump_from && host.presents % host.frame_every == 0
}

// Whole VRAM as 15-bit color, for checking off-screen uploads.
@(private)
dump_vram :: proc() {
	buf := make([dynamic]u8, context.temp_allocator)
	header := fmt.tprintf("P6\n%d %d\n255\n", VRAM_W, VRAM_H)
	append(&buf, ..transmute([]u8)header)
	append(&buf, ..vram_rgb())
	name := fmt.tprintf("%s/vram_%05d.ppm", host.dump_dir, host.presents)
	if err := os.write_entire_file(name, buf[:]); err != nil {
		fmt.eprintln("BOF4_DUMP: write failed:", name, err)
	}
}

// VRAM as RGB888 read as 15-bit color, in temp memory.
@(private)
vram_rgb :: proc() -> []u8 {
	out := make([]u8, VRAM_W * VRAM_H * 3, context.temp_allocator)
	for c, i in vram {
		out[i * 3] = u8(c & 0x1f) << 3
		out[i * 3 + 1] = u8((c >> 5) & 0x1f) << 3
		out[i * 3 + 2] = u8((c >> 10) & 0x1f) << 3
	}
	return out
}

// Convert a w x h VRAM area at (x, y) into dst as XRGB8888 (the window
// texture's format, which the host GPU takes as is), tightly packed, at
// the shown target's resolution (frame_size): each VRAM pixel is a block of
// its pixels. 24-bit areas are read from VRAM and widened as blocks.
// `extra_step` names the extra picture being converted, if one is.
@(private)
convert_area :: proc(x, y, w, h: i32, depth24: bool, dst: []u32, extra_step := -1) {
	c := Convert{x = x, y = y, w = w, h = h, depth24 = depth24, dst = dst}
	k := shown_target().shift
	assert(len(dst) >= int((w << k) * (h << k)), "conversion target too small")
	if k == 0 {
		convert_rows(&c, 0, h)
		return
	}
	if !depth24 && shown_target().gl {
		// The GPU converts into its own buffer, which is shown as is
		// (convert_display, extra_due); dst is left alone.
		slot := extra_step >= 0 ? extra_step : EXTRA_FRAMES
		gl_frame(slot, x << k, y << k, w << k, h << k)
		return
	}
	c.bloom = bloom_effects && !depth24 && bloom_prepare(x, y, w, h)
	if !depth24 {
		c.post = post_now()
	}
	if c.post.focus > 0 {
		dof_prepare(x, y, w, h)
	}
	c.fx = c.bloom || c.post.focus > 0 || c.post.vignette || c.post.grade.on
	// A finer target's rows are converted on the raster threads.
	raster_parallel(proc(band, bands: i32, data: rawptr) {
			c := (^Convert)(data)
			y0, y1 := band_run(0, c.h << shown_target().shift, band, bands)
			convert_rows(c, y0, y1)
		}, &c)
}

@(private)
Convert :: struct {
	x, y, w, h: i32,
	depth24:    bool,
	dst:        []u32,
	// Add the glow worked out for the area (bloom_prepare); the effects
	// (post.odin); whether either has anything to do.
	bloom:      bool,
	post:       Post,
	fx:         bool,
}

// Convert rows r0 ..< r1 (shown target pixels from the top) of c.
@(private)
convert_rows :: proc(c: ^Convert, r0, r1: i32) #no_bounds_check {
	x, y, depth24, dst := c.x, c.y, c.depth24, c.dst
	t := shown_target()
	k := t.shift
	fw := c.w << k
	o := int(r0) * int(fw)
	for row in r0 ..< r1 {
		if depth24 {
			vy := (y + row >> k) & (VRAM_H - 1)
			bytes := ([^]u8)(&vram[vy * VRAM_W])[:VRAM_W * 2]
			start := int(x) * 2
			for px in 0 ..< int(fw) {
				b := start + (px >> k) * 3
				r := u32(bytes[b % (VRAM_W * 2)])
				g := u32(bytes[(b + 1) % (VRAM_W * 2)])
				bl := u32(bytes[(b + 2) % (VRAM_W * 2)])
				dst[o] = r << 16 | g << 8 | bl
				o += 1
			}
			continue
		}
		vy := (y << k + row) & (t.h - 1)
		if k > 0 {
			line := t.rgb[vy * t.w:][:t.w]
			if c.fx {
				fh := c.h << k
				for px in 0 ..< fw {
					dst[o] = post_pixel(line[(x << k + px) & (t.w - 1)], &c.post, c.bloom, px, row, fw, fh)
					o += 1
				}
				continue
			}
			for px in 0 ..< fw {
				dst[o] = line[(x << k + px) & (t.w - 1)] & 0xffffff
				o += 1
			}
			continue
		}
		line := t.pix[vy * t.w:][:t.w]
		for px in 0 ..< fw {
			c := u32(line[(x << k + px) & (t.w - 1)])
			dst[o] = (c & 0x1f) << 19 | (c >> 5 & 0x1f) << 11 | (c >> 10 & 0x1f) << 3
			o += 1
		}
	}
}

// Size of the displayed area as converted (convert_area).
frame_size :: proc() -> (w, h: i32) {
	k := shown_target().shift
	return display.w << k, display.h << k
}

// Whether the present about to run shows the same VRAM area as the last
// one: a repeat of the game frame on screen.
display_repeats :: proc() -> bool {
	return [4]i32{display.x, display.y, display.w, display.h} == host.last_area
}

// Point host.frame at what this vblank shows: the displayed VRAM area, or
// the extra picture of a frozen-time pass when the display is repeating a
// game frame (checkpoint.odin).
@(private)
convert_display :: proc() {
	repeat := display_repeats()
	host.last_area = {display.x, display.y, display.w, display.h}
	if picture, slot, due := extra_due(repeat); due {
		host.frame, host.frame_slot = picture, slot
	} else {
		host.frame, host.frame_slot = host.converted, -1
		convert_area(display.x, display.y, display.w, display.h, display.depth24, host.frame)
		if shown_target().gl && !display.depth24 && shown_target().shift > 0 {
			host.frame, host.frame_slot = nil, EXTRA_FRAMES
		}
	}
	if host.frame_slot >= 0 {
		host.frame_mark = gpu_gl.frames[host.frame_slot].mark
	}
}

// The picture this vblank shows (host.frame), waiting for the GPU to finish
// converting it when it is a GL frame slot's.
@(private)
frame_pixels :: proc() -> []u32 {
	if host.frame == nil && host.frame_slot >= 0 {
		host.frame = gl_frame_take(host.frame_slot)
	}
	return host.frame
}

// Presents between .Perf reports.
@(private)
PERF_PERIOD :: 1000

@(private)
perf_report :: proc() {
	if host.presents % PERF_PERIOD != 0 {
		return
	}
	now := time.tick_now()
	secs := time.duration_seconds(time.tick_diff(host.perf_mark, now))
	mixed_hz := f64(host.audio_mixed) * CPU_HZ * f64(clock_mul) / f64(max(cpu.cycles - host.perf_cycles, 1))
	low_ms := host.audio_low == max(int) ? 0 : f64(host.audio_low) * 1000 / AUDIO_HZ
	tracef(.Perf, "%d presents in %.3f s (%.1f/s), %d cycles, audio mixed %.1f Hz, queued %.1f ms (lowest %.1f), ran dry %d, dropped %d", PERF_PERIOD, secs, f64(PERF_PERIOD) / secs, cpu.cycles, mixed_hz, audio_queued_ms(), low_ms, host.audio_dry, host.audio_dropped)
	gl_perf()
	host.audio_dry = 0
	host.audio_dropped = 0
	host.audio_mixed = 0
	host.audio_low = max(int)
	host.perf_cycles = cpu.cycles
	host.perf_mark = now
}

// Render scale (not a PS1 feature): the display's picture is drawn at this
// many times VRAM's resolution, 1, 2 or 4 (render_targets_set). A change
// takes effect at the next present.
render_scale: i32 = 2

// Bring the hi-res target, the converted frame buffers and the window's
// textures to render_scale. Waits while a hold keeps a picture in a texture.
@(private)
render_scale_apply :: proc() -> bool {
	k: u32 = render_scale >= 4 ? 2 : render_scale >= 2 ? 1 : 0
	if host.texture != nil && (shown_target().shift == k || host.holding) {
		return true
	}
	render_targets_set(render_scale)
	w, h := i32(VRAM_W) << k, i32(VRAM_H) << k
	delete(host.converted)
	host.converted = make([]u32, w * h)
	host.frame, host.frame_slot = host.converted, -1
	for &f in extra.frames {
		delete(f)
		f = make([]u32, w * h)
	}
	extra.ready = false
	if host.texture != nil {
		sdl.DestroyTexture(host.texture)
		sdl.DestroyTexture(host.held)
	}
	gl_show_forget()
	host.texture = sdl.CreateTexture(host.renderer, .XRGB8888, .STREAMING, w, h)
	host.held = sdl.CreateTexture(host.renderer, .XRGB8888, .STREAMING, w, h)
	if host.texture == nil || host.held == nil {
		fmt.eprintln("SDL_CreateTexture:", sdl.GetError())
		return false
	}
	// Both blend: a hold swaps them.
	if sdl.SetTextureBlendMode(host.texture, .BLEND) != 0 || sdl.SetTextureBlendMode(host.held, .BLEND) != 0 {
		fmt.eprintln("SDL_SetTextureBlendMode:", sdl.GetError())
		return false
	}
	host.shown_w, host.shown_h = 0, 0
	return texture_filter_apply()
}

@(private)
present :: proc() {
	replay_panel()
	host.presents += 1
	trace_window()
	run_poke_script()
	run_drag_script()
	if .Perf in trace.active {
		perf_report()
	}
	render_scale_apply()
	host.last_mark, host.frame_mark = host.frame_mark, -1
	if display.w > 0 && display.h > 0 {
		convert_display()
	}
	if skip_black {
		host.black = frame_black()
	}
	if instant_loading && cd_loading() {
		picture_still()
	} else {
		host.still = 0
	}
	dump_frame()
	if hold_picture > 0 {
		// The picture on screen stays in its texture; the next live one
		// goes to the other.
		if !host.holding {
			host.holding = true
			host.held, host.texture = host.texture, host.held
			host.held_area = {0, 0, host.shown_w, host.shown_h}
		}
		hold_picture -= 1
	} else {
		if host.holding {
			host.holding = false
			host.fade = HOLD_FADE
		} else if host.fade > 0 {
			host.fade -= 1
		}
		if display.enabled && display.w > 0 && display.h > 0 {
			fw, fh := frame_size()
			src := sdl.Rect{0, 0, fw, fh}
			if host.frame_slot < 0 || !gl_show(host.texture, host.frame_slot, fw, fh) {
				sdl.UpdateTexture(host.texture, &src, &frame_pixels()[0], fw * 4)
			}
			host.shown_w, host.shown_h = fw, fh
		}
	}
	draw()
}

// Presents left to keep showing the picture already in the window instead
// of the displayed area: the qol package sets it while the game draws
// something not meant to be seen (a section change's set-up frame).
hold_picture := 0

// While set, emulated time runs as fast as the host allows with the sound
// muted: the qol package sets it to hurry through a scene the player chose
// not to watch, holding the picture from before it (hold_picture).
skipping := false

// Presents a held picture takes to fade out over the live one after the hold
// (0.6 s at 60 a second).
@(private)
HOLD_FADE :: 36

// Run at every emulated vblank after input is read, before pacing; the qol
// package uses it to follow the game's state (e.g. to change speed).
vblank_hook: proc()

// Run at every emulated vblank just before present, e.g. to draw the extra
// picture present is about to show (qol's smooth motion). Not run in a
// background machine (preload.odin), which shows nothing.
present_hook: proc()

// Instant loading: while the drive reads data behind a still picture,
// emulated time runs as fast as the host allows. The game still sees the
// drive's own speed, so its loaders behave exactly as on a console; only the
// wall-clock wait goes away. Movies and XA streams keep real time, and so does
// anything animated during a load (the swirl into a battle plays while the
// battle loads), which would otherwise flash past.
instant_loading := false

// Presents the picture must hold still before a load is hurried. Longer than
// the few presents a game frame is repeated for, so an animation that only
// changes every second or third present never counts as still.
@(private = "file")
STILL_PRESENTS :: 8

// Black screens: while the picture shown is all black (the game holding a
// blank screen between scenes, with only music playing), pacing is off. The
// game still counts every tick of the wait; only the wall-clock wait goes
// away. Music queued during the skip is dropped, as in any fast-forward.
skip_black := false

// Brightest channel value still counted as black: the dither of a fade's
// last steps leaves values this low.
@(private = "file")
BLACK_MAX :: 0x10

// Whether the displayed picture is all black (or the display is off).
@(private = "file")
frame_black :: proc() -> bool {
	if !display.enabled || display.w <= 0 || display.h <= 0 {
		return true
	}
	if host.frame_mark >= 0 {
		// The GPU flags each conversion with a lit pixel. Waiting for this
		// one is only needed when the last picture was black too: a black
		// stretch begins one present later, its first picture paced.
		if lit, known := gl_frame_bright(host.last_mark); known && lit {
			return false
		}
		lit, _ := gl_frame_bright(host.frame_mark)
		return !lit
	}
	fw, fh := frame_size()
	s := Frame_Scan{bytes = slice.to_bytes(frame_pixels()[:fw * fh])}
	raster_parallel(proc(band, bands: i32, data: rawptr) {
			s := (^Frame_Scan)(data)
			lo, hi := band_run(0, i32(len(s.bytes)), band, bands)
			for b in s.bytes[lo:hi] {
				if b > BLACK_MAX {
					s.bright[band] = true
					return
				}
			}
		}, &s)
	for b in s.bright {
		if b {
			return false
		}
	}
	return true
}

// The frame split into the raster threads' bands, for frame_black and
// picture_still: whether each band has a pixel above black, and its hash.
@(private = "file")
Frame_Scan :: struct {
	bytes:  []u8,
	bright: [MAX_BANDS]bool,
	hash:   [MAX_BANDS]u64,
}

// Count presents the loading picture has held still.
@(private = "file")
picture_still :: proc() {
	fw, fh := frame_size()
	s := Frame_Scan{bytes = slice.to_bytes(frame_pixels()[:max(fw * fh, 0)])}
	raster_parallel(proc(band, bands: i32, data: rawptr) {
			s := (^Frame_Scan)(data)
			lo, hi := band_run(0, i32(len(s.bytes)), band, bands)
			s.hash[band] = xxhash.XXH3_64(s.bytes[lo:hi])
		}, &s)
	h := xxhash.XXH3_64(([^]u8)(&s.hash)[:size_of(s.hash)])
	host.still = h == host.still_hash ? host.still + 1 : 0
	host.still_hash = h
}

// Skip pacing while the disc loads, the screen is black or the window holds
// an earlier picture (hold_picture: nothing live is seen); when that ends,
// make the current vblank due now so pacing resumes from here instead of
// waiting out the skipped time.
@(private)
fast_forward :: proc() -> bool {
	loading := instant_loading && cd_loading() && host.still >= STILL_PRESENTS
	if (loading || skip_black && host.black || skipping || hold_picture > 0) && !movie_playing() {
		if !host.fast && .Perf in trace.active {
			tracef(.Perf, "fast-forward on")
			host.fast_start = time.tick_now()
			host.fast_vblank = host.presents
		}
		host.fast = true
		return true
	}
	if host.fast {
		if .Perf in trace.active {
			ms := time.duration_milliseconds(time.tick_since(host.fast_start))
			n := host.presents - host.fast_vblank
			tracef(.Perf, "fast-forward off: %d vblanks in %.1f ms (%.1f ms at console speed), audio queued %.1f ms", n, ms, f64(n) * VBLANK_NS / 1e6, audio_queued_ms())
		}
		host.fast = false
		pacing_rebase()
	}
	return false
}

// Called at every emulated vblank: show the frame, read input, and keep
// emulated time from running ahead of real time. BOF4_FAST=1 disables pacing.
platform_frame :: proc() {
	// Temp memory made during a vblank is dropped at its end; nothing in the
	// program frees the temp allocator otherwise, and frame dumps put
	// megabytes in it per dump.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if preload_child {
		preload_frame()
		return
	}
	if .Perf in trace.active {
		work := time.tick_since(host.work_mark)
		if host.work_mark != {} && work > VBLANK_NS && !host.vsync {
			tracef(.Perf, "late vblank: %.1f ms of work", time.duration_milliseconds(work))
		}
	}
	poll_events()
	if present_hook != nil {
		present_hook()
	}
	present()
	pause_wait()
	if host.quit {
		platform_shutdown()
		os.exit(0)
	}
	if vblank_hook != nil {
		vblank_hook()
	}
	unpaced := fast_forward() || host.unpaced
	vsync_update(!unpaced)
	defer host.work_mark = time.tick_now()
	if unpaced {
		return
	}
	if host.vsync {
		// RenderPresent already waited for the display; keep the origin
		// current so sleep pacing resumes from here if vsync goes off.
		pacing_rebase()
		return
	}
	due := vblank_due_ns(host.presents)
	for {
		remaining := due - i64(time.tick_since(host.start))
		if remaining <= 0 {
			break
		}
		if remaining > 1_000_000 {
			time.sleep(time.Duration(remaining - 500_000))
		}
	}
	if i64(time.tick_since(host.start)) > vblank_due_ns(host.presents + 6) {
		// Fell behind (slow frame or debugger stop): resync instead of racing.
		pacing_rebase()
	}
}
