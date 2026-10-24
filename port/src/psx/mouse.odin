// Host mouse: buttons and wheel as console buttons, right-button drag as a
// camera turn.
//
// Mouse buttons and wheel notches are bound under [keys] like keyboard keys,
// by the names in MOUSE_NAMES. A button holds its bits while it is down. A
// wheel notch has no held state, so it taps its bits (press_for, TAP_HOLD);
// further notches extend the tap.
//
// The mouse only counts while the window has input focus: buttons and the
// wheel are ignored without it (X11 sends wheel events to unfocused windows
// under the pointer), and the click that gives the window focus is
// swallowed, so focusing never presses a button.
// Held buttons follow the button events, not SDL's global mouse state, so
// a press is only seen once it has been accepted.
//
// While `mouse_drag` is on, motion with the right button down collects into
// a drag distance (both axes) that the camera takes with mouse_drag_take.
// The pointer is captured (relative mode) for the drag, so it never leaves
// the window or hits the screen edge. The right button then holds nothing
// while down; released having moved less than CLICK_SLOP, it was a click and
// taps its bits (Circle by default, to cancel in menus).
package psx

import "core:fmt"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl2"

@(private)
Mouse_Source :: enum {
	Left,
	Middle,
	Right,
	X1,
	X2,
	Wheel_Up,
	Wheel_Down,
}

// Config names of the mouse sources, matched without regard to case.
@(private)
MOUSE_NAMES := [Mouse_Source]string {
	.Left       = "Mouse Left",
	.Middle     = "Mouse Middle",
	.Right      = "Mouse Right",
	.X1         = "Mouse X1",
	.X2         = "Mouse X2",
	.Wheel_Up   = "Wheel Up",
	.Wheel_Down = "Wheel Down",
}

// A button pressed within this long (real time, SDL ms) of the window
// gaining focus is taken as the click that focused it.
@(private)
FOCUS_CLICK_MS :: 250

// Pointer travel (window pixels, both axes) under which a right-button
// press and release is a click rather than a camera drag.
@(private)
CLICK_SLOP :: 6

@(private)
mouse: struct {
	binds:       [Mouse_Source]u16,
	// Buttons held down since an accepted press.
	down:        bit_set[Mouse_Source],
	focused:     bool,
	// SDL ticks when the window last gained focus.
	focus_at:    u32,
	dragging:    bool,
	// Drag distance not yet taken, in window pixels.
	drag:        [2]f32,
	// Pointer travel since the right button went down, in window pixels.
	drag_moved:  f32,
	// Relative mode was refused once (reported then).
	no_relative: bool,
}

// Right-button drag turns the camera (set from the config).
mouse_drag := true

// The mouse source for a config name, if it is one.
mouse_source_from_name :: proc(name: string) -> (Mouse_Source, bool) {
	for n, s in MOUSE_NAMES {
		if strings.equal_fold(name, n) {
			return s, true
		}
	}
	return {}, false
}

@(private)
mouse_unbind :: proc(bit: u16) {
	for &b in mouse.binds {
		b &= ~bit
	}
}

@(private)
mouse_bind :: proc(s: Mouse_Source, bit: u16) {
	mouse.binds[s] |= bit
}

@(private)
mouse_held :: proc() -> (held: u16) {
	for s in mouse.down {
		if s != .Right || !mouse_drag {
			held |= mouse.binds[s]
		}
	}
	return
}

// Follow window focus. Losing it drops every held button and any drag.
@(private)
mouse_focus :: proc(gained: bool, timestamp: u32) {
	mouse.focused = gained
	if gained {
		mouse.focus_at = timestamp
		return
	}
	mouse.down = {}
	mouse_release()
}

@(private)
mouse_wheel :: proc(ev: sdl.MouseWheelEvent) {
	y := ev.y
	if ev.direction == u32(sdl.MouseWheelDirection.FLIPPED) {
		y = -y
	}
	if y == 0 || !mouse.focused {
		return
	}
	s := y > 0 ? Mouse_Source.Wheel_Up : Mouse_Source.Wheel_Down
	if catch_mouse(s) {
		return
	}
	press_for(mouse.binds[s], TAP_HOLD)
}

@(private)
mouse_button :: proc(ev: sdl.MouseButtonEvent) {
	// SDL numbers the buttons 1..5 in Mouse_Source order.
	if ev.button < 1 || ev.button > u8(Mouse_Source.X2) + 1 {
		return
	}
	s := Mouse_Source(ev.button - 1)
	if ev.type == .MOUSEBUTTONUP {
		if s == .Right && mouse.dragging {
			click := mouse.drag_moved < CLICK_SLOP
			mouse_capture(false)
			if click {
				press_for(mouse.binds[.Right], TAP_HOLD)
			}
		}
		mouse.down -= {s}
		return
	}
	if !mouse.focused || ev.timestamp - mouse.focus_at < FOCUS_CLICK_MS {
		if .Qol in trace.active {
			tracef(.Qol, "mouse: %v press swallowed (focused %v)", s, mouse.focused)
		}
		return
	}
	if catch_mouse(s) {
		return
	}
	mouse.down += {s}
	if s == .Right && mouse_drag && !mouse.dragging {
		mouse_capture(true)
	}
}

// Start or end a drag, capturing the pointer for it.
@(private)
mouse_capture :: proc(on: bool) {
	mouse.dragging = on
	mouse.drag = 0
	mouse.drag_moved = 0
	if sdl.SetRelativeMouseMode(sdl.bool(on)) != 0 && !mouse.no_relative {
		mouse.no_relative = true
		fmt.eprintln("mouse: no relative mode, the pointer may leave the window while dragging:", sdl.GetError())
	}
}

@(private)
mouse_motion :: proc(ev: sdl.MouseMotionEvent) {
	if mouse.dragging {
		mouse.drag += {f32(ev.xrel), f32(ev.yrel)}
		mouse.drag_moved += abs(f32(ev.xrel)) + abs(f32(ev.yrel))
	}
}

// Drag distance in window pixels since the last call (right and down
// positive); 0 while no drag is held.
mouse_drag_take :: proc() -> [2]f32 {
	d := mouse.drag
	mouse.drag = 0
	record_drag(d)
	return d
}

// Release the drag capture, e.g. when the game pauses.
mouse_release :: proc() {
	if mouse.dragging {
		mouse_capture(false)
	}
}

// Debug aid: BOF4_DRAG="<present>:<x>[/<y>][:<presents>],..." drags that
// many window pixels to the right and down (negative: left, up) at each
// vblank of the span, SCRIPT_HOLD presents by default, as if the right button
// were held.
@(private)
Scripted_Drag :: struct {
	at:     u64,
	pixels: [2]f32,
	hold:   u64,
}

@(private)
parse_drag_script :: proc(spec: string) {
	for item in strings.split(spec, ",", context.temp_allocator) {
		parts := strings.split(item, ":", context.temp_allocator)
		e := Scripted_Drag{hold = SCRIPT_HOLD}
		ok := len(parts) == 2 || len(parts) == 3
		at_ok, px_ok, hold_ok := false, false, true
		if ok {
			e.at, at_ok = strconv.parse_u64(parts[0])
			e.pixels, px_ok = parse_drag_pixels(parts[1])
			if len(parts) == 3 {
				e.hold, hold_ok = strconv.parse_u64(parts[2])
			}
		}
		if !ok || !at_ok || !px_ok || !hold_ok {
			fmt.eprintln("BOF4_DRAG: bad entry", item)
			continue
		}
		append(&host.drag_script, e)
	}
}

@(private)
run_drag_script :: proc() {
	if !mouse_drag {
		return
	}
	for e in host.drag_script {
		if host.presents >= e.at && host.presents < e.at + e.hold {
			mouse.drag += e.pixels
		}
	}
}

// "<x>" or "<x>/<y>" window pixels.
@(private)
parse_drag_pixels :: proc(s: string) -> (px: [2]f32, ok: bool) {
	x, _, y := strings.partition(s, "/")
	px.x = strconv.parse_f32(x) or_return
	if y != "" {
		px.y = strconv.parse_f32(y) or_return
	}
	return px, true
}
