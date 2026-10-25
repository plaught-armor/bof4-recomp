// Debug sessions. With BOF4_DEBUG_DIR=<dir>, every pad state and camera
// drag the game takes is written to <dir>/input.rec as it happens, and F12
// saves a snapshot there: the window picture and game frame (PNG), main RAM
// and VRAM. Emulation is driven by emulated vblanks (presents), so
// BOF4_REPLAY=<dir>/input.rec plays the session back exactly, given the same
// disc, config and starting memory cards; live input still adds on top, so a
// replay can be taken over at its end.
//
// input.rec is a ps:core input record (core/record.odin: buttons and
// sticks, keyed by present count) with these entries of the port's own:
//   D <present> <x> <y>      camera drag taken at that present (y optional)
//   C <present> <x> <y>      pointer moved to display pixel (x, y), as a
//                            menu took it at that present
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

import "ps:core"


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
	if !core.record_open(path) {
		return false
	}
	debug.charged = charge_native
	core.record_write(fmt.tprintf("T 0 %d\n", charge_native ? 1 : 2))
	fmt.eprintln("debug: recording input to", path, "- F12 saves a snapshot")
	return true
}

@(private)
record_close :: proc() {
	core.record_close()
}

// Note the pad state the game reads, when it changed.
@(private)
record_pad :: proc(held: u16) {
	core.record_buttons(0, host.presents, pad_set(held))
}

// Note the pads' stick positions, when they changed.
@(private)
record_sticks :: proc(s: Sticks) {
	core.record_sticks(0, host.presents, s.left, s.right)
}

@(private)
record_drag :: proc(pixels: [2]f32) {
	if core.record.out != nil && pixels != 0 {
		core.record_write(fmt.tprintf("D %d %v %v\n", host.presents, pixels.x, pixels.y))
	}
}

@(private)
record_point :: proc(pos: [2]f32) {
	if core.record.out != nil {
		core.record_write(fmt.tprintf("C %d %v %v\n", host.presents, pos.x, pos.y))
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
	if core.record.out != nil && debug.charged != charge_native {
		debug.charged = charge_native
		core.record_write(fmt.tprintf("T %d %d\n", host.presents, charge_native ? 1 : 2))
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
	if core.record.out != nil {
		core.record_write(fmt.tprintf("M %d %d\n", host.presents, debug.snaps))
	}
	fmt.eprintf("snapshot %d at present %d: %s_*\n", debug.snaps, host.presents, base)
	core.tracef(.Game, "snapshot %d", debug.snaps)
}

@(private = "file")
write_png :: proc(path: string, rgb: []u8, w, h: i32) {
	assert(len(rgb) >= int(w * h * 3), "picture smaller than its size")
	if !core.png_write(path, rgb, int(w), int(h), 3) {
		fmt.eprintln("snapshot: png write failed:", path)
	}
}

// Load an input record: buttons and sticks into ps:core's replay, the port's
// own entries as scripted drags, pointer moves, panel toggles and timing.
@(private = "file")
replay_load :: proc(path: string) -> bool {
	charge_native = true
	if !core.replay_load(path, replay_entry) {
		return false
	}
	replay_end = max(replay_end, core.replay.end)
	fmt.eprintf("replay: %d drags, %d pointer moves%s\n", len(host.drag_script), len(host.point_script),
		charge_native ? " (old timing: native code charges game cycles)" : "")
	return true
}

// One of the port's own record entries (see the top of this file).
@(private = "file")
replay_entry :: proc(kind: string, at: u64, f: []string) -> bool {
	// Not a T entry: the switch to the new timing that a record made while
	// replaying an old one ends with lands just past its end.
	if kind != "T" {
		replay_end = max(replay_end, at)
	}
	switch kind {
	case "M":
		return len(f) == 1
	case "D":
		if len(f) < 1 || len(f) > 2 {
			return false
		}
		px := parse_drag_pixels(strings.join(f, "/", context.temp_allocator)) or_return
		append(&host.drag_script, Scripted_Drag{at = at, pixels = px, hold = 1})
	case "C":
		if len(f) != 2 {
			return false
		}
		px := parse_drag_pixels(strings.join(f, "/", context.temp_allocator)) or_return
		append(&host.point_script, Scripted_Point{at = at, pos = px})
	case "P":
		if len(f) != 1 {
			return false
		}
		append(&debug.panel, at)
	case "T":
		if len(f) != 1 {
			return false
		}
		timing := strconv.parse_u64(f[0]) or_return
		if timing < 1 || timing > 2 {
			return false
		}
		if at == 0 {
			charge_native = timing == 1
		} else {
			append(&debug.timing, Timing_Change{at = at, charge = timing == 1})
		}
	case:
		return false
	}
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
