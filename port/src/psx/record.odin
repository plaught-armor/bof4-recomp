// Debug sessions. With BOF4_DEBUG_DIR=<dir>, every pad state and camera
// drag the game takes is written to <dir>/input.rec as it happens, and F12
// saves a snapshot there: the window picture and game frame (PNG), main RAM
// and VRAM. Emulation is driven by emulated vblanks (presents), so
// BOF4_REPLAY=<dir>/input.rec plays the session back exactly, given the same
// disc, config and starting memory cards; live input still adds on top, so a
// replay can be taken over at its end.
//
// input.rec has one entry per line, keyed by present count:
//   I <present> <hex mask>   pad buttons held from that present on
//   S <present> <lx> <ly> <rx> <ry>
//                            analog sticks from that present on, each axis
//                            as the hex bits of its f32 so replay is exact
//   D <present> <x> <y>      camera drag taken at that present (y optional)
//   P <present> 0            panel shown or hidden (it takes the pad); only
//                            older recordings have these, from the F2 key
//                            the port no longer has
//   M <present> <n>          F12 snapshot n (ignored by replay)
//   T <present> <n>          timing from that present on: 2 when the native
//                            rewrites take no emulated time, 1 when they
//                            charge the game's cycles (see charge_native); a
//                            record with no T at present 0 starts at 1
package psx

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../png"

// A replayed mask with no later entry stays held this long.
@(private = "file")
REPLAY_LAST_HOLD :: u64(1) << 40

// The present of the replay's last entry (0 without a replay): the test
// autopilot (qol/autoplay.odin) takes over only after it.
replay_end: u64

// Native rewrites of game routines (qol/map_geometry.odin, collision.odin)
// charge the emulated cycles the game's own code would take, as every
// session did before 2026-10-22: set when replaying a record from then, so
// its interrupts and vblanks land where they did and it plays back the same.
// Live play after the replay's end takes the new timing again.
charge_native: bool

@(private = "file")
debug: struct {
	dir:      string,
	rec:      ^os.File,
	// Last recorded pad state and stick positions.
	mask:     u16,
	sticks:   Sticks,
	snaps:    int,
	snap_due: bool,
	// Replayed panel toggles, by present, in order; panel_next is the next due.
	panel:      [dynamic]u64,
	panel_next: int,
	// Replayed timing changes, in order; timing_next is the next due.
	timing:      [dynamic]Timing_Change,
	timing_next: int,
	// charge_native as last written to the record.
	charged:     bool,
}

@(private = "file")
Timing_Change :: struct {
	at:     u64,
	charge: bool,
}

// Read BOF4_DEBUG_DIR and BOF4_REPLAY. Returns false when the record cannot
// be created or the replay cannot be read.
@(private)
record_init :: proc() -> bool {
	if path := os.get_env("BOF4_REPLAY", context.temp_allocator); path != "" {
		if !replay_load(path) {
			return false
		}
	}
	debug.dir = os.get_env("BOF4_DEBUG_DIR", context.allocator)
	if debug.dir == "" {
		return true
	}
	path := fmt.tprintf("%s/input.rec", debug.dir)
	f, err := os.create(path)
	if err != nil {
		fmt.eprintln("BOF4_DEBUG_DIR: cannot create", path, err)
		return false
	}
	debug.rec = f
	debug.charged = charge_native
	record_write(fmt.tprintf("T 0 %d\n", charge_native ? 1 : 2))
	fmt.eprintln("debug: recording input to", path, "- F12 saves a snapshot")
	return true
}

@(private)
record_close :: proc() {
	if debug.rec != nil {
		os.close(debug.rec)
		debug.rec = nil
	}
}

// Note the pad state the game reads, when it changed.
@(private)
record_pad :: proc(held: u16) {
	if debug.rec == nil || held == debug.mask {
		return
	}
	debug.mask = held
	record_write(fmt.tprintf("I %d %x\n", host.presents, held))
}

// Note the pads' stick positions, when they changed.
@(private)
record_sticks :: proc(s: Sticks) {
	if debug.rec == nil || s == debug.sticks {
		return
	}
	debug.sticks = s
	axes := [4]f32{s.left.x, s.left.y, s.right.x, s.right.y}
	b := transmute([4]u32)axes
	record_write(fmt.tprintf("S %d %08x %08x %08x %08x\n", host.presents, b[0], b[1], b[2], b[3]))
}

@(private)
record_drag :: proc(pixels: [2]f32) {
	if debug.rec != nil && pixels != 0 {
		record_write(fmt.tprintf("D %d %v %v\n", host.presents, pixels.x, pixels.y))
	}
}

// Replay the panel toggles and timing changes due at this present, and note
// a timing change in the record; called before it counts.
@(private)
replay_panel :: proc() {
	for debug.panel_next < len(debug.panel) && debug.panel[debug.panel_next] <= host.presents {
		if debug.panel[debug.panel_next] == host.presents {
			osd_toggle_panel()
		}
		debug.panel_next += 1
	}
	for debug.timing_next < len(debug.timing) && debug.timing[debug.timing_next].at <= host.presents {
		charge_native = debug.timing[debug.timing_next].charge
		debug.timing_next += 1
	}
	if charge_native && host.presents > replay_end {
		charge_native = false
	}
	if debug.rec != nil && debug.charged != charge_native {
		debug.charged = charge_native
		record_write(fmt.tprintf("T %d %d\n", host.presents, charge_native ? 1 : 2))
	}
}

// Unbuffered, so a crash loses nothing written before it. A failed write
// stops the recording.
@(private = "file")
record_write :: proc(line: string) {
	if _, err := os.write_string(debug.rec, line); err != nil {
		fmt.eprintln("BOF4_DEBUG_DIR: input record write failed, recording stopped:", err)
		record_close()
	}
}

// F12: snapshot at the next draw, so the window picture is complete.
@(private)
snapshot_request :: proc() {
	if debug.dir == "" {
		fmt.eprintln("F12: snapshots need BOF4_DEBUG_DIR (run bof4-debug)")
		return
	}
	debug.snap_due = true
}

// Called by draw before the picture is shown.
@(private)
snapshot_take :: proc() {
	if !debug.snap_due {
		return
	}
	debug.snap_due = false
	debug.snaps += 1
	base := fmt.tprintf("%s/snap%02d_%06d", debug.dir, debug.snaps, host.presents)
	if pix, w, h, ok := window_pixels(); ok {
		write_png(fmt.tprintf("%s_window.png", base), pix, w, h)
	}
	if display.w > 0 && display.h > 0 {
		fw, fh := frame_size()
		write_png(fmt.tprintf("%s_frame.png", base), frame_rgb(frame_pixels()[:fw * fh]), fw, fh)
	}
	write_png(fmt.tprintf("%s_vram.png", base), vram_rgb(), VRAM_W, VRAM_H)
	ram_name := fmt.tprintf("%s_ram.bin", base)
	if err := os.write_entire_file(ram_name, ram[:]); err != nil {
		fmt.eprintln("snapshot: ram write failed:", ram_name, err)
	}
	vram_name := fmt.tprintf("%s_vram.bin", base)
	if err := os.write_entire_file(vram_name, slice.to_bytes(vram[:])); err != nil {
		fmt.eprintln("snapshot: vram write failed:", vram_name, err)
	}
	if debug.rec != nil {
		record_write(fmt.tprintf("M %d %d\n", host.presents, debug.snaps))
	}
	fmt.eprintf("snapshot %d at present %d: %s_*\n", debug.snaps, host.presents, base)
	tracef(.Qol, "snapshot %d", debug.snaps)
}

@(private = "file")
write_png :: proc(path: string, rgb: []u8, w, h: i32) {
	assert(len(rgb) >= int(w * h * 3), "picture smaller than its size")
	if !png.write(path, rgb, int(w), int(h), 3) {
		fmt.eprintln("snapshot: png write failed:", path)
	}
}

// Load an input record as scripted presses and drags.
@(private = "file")
replay_load :: proc(path: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintln("BOF4_REPLAY: cannot read", path, err)
		return false
	}
	presses, drags, moves := 0, 0, 0
	open, open_stick := -1, -1
	charge_native = true
	for line, n in strings.split_lines(string(data), context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) == 0 || f[0] == "M" {
			continue
		}
		at, at_ok := u64(0), false
		if len(f) == 3 || (f[0] == "D" && len(f) == 4) || (f[0] == "S" && len(f) == 6) {
			at, at_ok = strconv.parse_u64(f[1])
		}
		if !at_ok {
			fmt.eprintf("BOF4_REPLAY: %s:%d: bad entry %q\n", path, n + 1, line)
			return false
		}
		// Not a T entry: the switch to the new timing that a record made
		// while replaying an old one ends with lands just past its end.
		if f[0] != "T" {
			replay_end = max(replay_end, at)
		}
		switch f[0] {
		case "I":
			mask, ok := strconv.parse_u64(f[2], 16)
			if !ok || mask > 0xffff {
				fmt.eprintf("BOF4_REPLAY: %s:%d: bad mask %q\n", path, n + 1, line)
				return false
			}
			if open >= 0 {
				host.script[open].hold = at - host.script[open].at
			}
			open = -1
			if mask != 0 {
				append(&host.script, Scripted_Press{at = at, mask = u16(mask), hold = REPLAY_LAST_HOLD})
				open = len(host.script) - 1
				presses += 1
			}
		case "D":
			px, ok := parse_drag_pixels(len(f) == 4 ? strings.join(f[2:], "/", context.temp_allocator) : f[2])
			if !ok {
				fmt.eprintf("BOF4_REPLAY: %s:%d: bad drag %q\n", path, n + 1, line)
				return false
			}
			append(&host.drag_script, Scripted_Drag{at = at, pixels = px, hold = 1})
			drags += 1
		case "S":
			if !replay_stick(f[2:], at, &open_stick) {
				fmt.eprintf("BOF4_REPLAY: %s:%d: bad sticks %q\n", path, n + 1, line)
				return false
			}
			moves += 1
		case "P":
			append(&debug.panel, at)
		case "T":
			timing, ok := strconv.parse_u64(f[2])
			if !ok || timing < 1 || timing > 2 {
				fmt.eprintf("BOF4_REPLAY: %s:%d: unknown timing %q\n", path, n + 1, line)
				return false
			}
			if at == 0 {
				charge_native = timing == 1
			} else {
				append(&debug.timing, Timing_Change{at = at, charge = timing == 1})
			}
		case:
			fmt.eprintf("BOF4_REPLAY: %s:%d: unknown entry %q\n", path, n + 1, line)
			return false
		}
	}
	fmt.eprintf("replay: %d presses, %d drags, %d stick moves from %s%s\n", presses, drags, moves, path,
		charge_native ? " (old timing: native code charges game cycles)" : "")
	return true
}

// Script the stick positions of an S entry (four hex f32 bit patterns) from
// present `at` until the next S entry; open is the script index of the
// previous one, or -1.
@(private = "file")
replay_stick :: proc(axes: []string, at: u64, open: ^int) -> bool {
	v: [4]f32
	for a, i in axes {
		b, ok := strconv.parse_u64(a, 16)
		v[i] = transmute(f32)u32(b)
		if !ok || b > 0xffffffff || !(v[i] >= -1 && v[i] <= 1) {
			return false
		}
	}
	if open^ >= 0 {
		host.stick_script[open^].hold = at - host.stick_script[open^].at
	}
	sticks := Sticks{left = {v[0], v[1]}, right = {v[2], v[3]}}
	append(&host.stick_script, Scripted_Stick{at = at, sticks = sticks, hold = REPLAY_LAST_HOLD})
	open^ = len(host.stick_script) - 1
	return true
}

// A snapshot at the next draw when BOF4_DEBUG_DIR is set (for test tools).
snapshot_now :: proc() {
	if debug.dir != "" {
		debug.snap_due = true
	}
}

// Presents shown so far (for test tools' logs).
host_presents :: proc() -> u64 {
	return host.presents
}
