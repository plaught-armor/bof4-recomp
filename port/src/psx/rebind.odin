// Keyboard and mouse rebinding from the game's menus: the sources bound to a
// console button, catching the next key or mouse press, moving a source to a
// button, and the default layout.
//
// Sources are named as in config files: SDL scancode names ("E", "Left
// Shift") and MOUSE_NAMES ("Mouse Left", "Wheel Up").
//
// While a catch is armed the next key press, mouse button press or wheel
// notch is taken by it and reaches nothing else (not the window keys, not
// the pad). Every button held when the catch ends stays hidden from the game
// until released (input.blocked), so the caught press does not also act.
package psx

import "core:hash/xxhash"
import "core:mem"
import "core:strings"
import "ps:core"
import sdl "vendor:sdl2"

// Every keyboard and mouse binding, to put back later.
Key_Binds :: struct {
	keys:  [sdl.NUM_SCANCODES]core.Buttons,
	mouse: [Mouse_Source]u16,
}

@(private)
catch: struct {
	armed: bool,
	// The caught source's name; "" until one is caught.
	name:  string,
}

// Arm the catch: the next key or mouse press is taken by key_catch_take.
key_catch_start :: proc() {
	catch = {armed = true}
}

// The caught source's name, once one has been caught; the catch is then
// over.
key_catch_take :: proc() -> (name: string, ok: bool) {
	if !catch.armed || catch.name == "" {
		return "", false
	}
	name = catch.name
	catch = {}
	input.blocked = 0xffff
	return name, true
}

// Take a key press for an armed catch; false when none is armed.
@(private)
catch_key :: proc(k: sdl.KeyboardEvent) -> bool {
	if !catch.armed {
		return false
	}
	if k.repeat == 0 && catch.name == "" {
		catch.name = string(sdl.GetScancodeName(k.keysym.scancode))
	}
	return true
}

// Take a mouse press (button or wheel) for an armed catch; false when none
// is armed or the window does not have focus.
@(private)
catch_mouse :: proc(s: Mouse_Source) -> bool {
	if !catch.armed || !mouse.focused {
		return false
	}
	if catch.name == "" {
		catch.name = MOUSE_NAMES[s]
	}
	return true
}

// A hash of every binding (keys, mouse, pad buttons and triggers) and the
// device in use: button prompts drawn from them are still current while it
// stays the same, so they need not be worked out again every vblank.
binds_hash :: proc() -> u64 {
	h := xxhash.XXH3_64_with_seed(mem.ptr_to_bytes(&core.input.keys), u64(core.input.device))
	h = xxhash.XXH3_64_with_seed(mem.ptr_to_bytes(&core.input.buttons), h)
	h = xxhash.XXH3_64_with_seed(mem.ptr_to_bytes(&core.input.triggers), h)
	return xxhash.XXH3_64_with_seed(mem.ptr_to_bytes(&mouse.binds), h)
}

// The names of the keys and mouse sources that hold `bit`, keys first, as
// many as fit in `out`; returns how many there are in all.
key_sources :: proc(bit: u16, out: []string) -> (n: int) {
	for b, code in core.input.keys {
		if b & pad_set(bit) != {} {
			if n < len(out) {
				out[n] = string(sdl.GetScancodeName(sdl.Scancode(code)))
			}
			n += 1
		}
	}
	for b, s in mouse.binds {
		if b & bit != 0 {
			if n < len(out) {
				out[n] = MOUSE_NAMES[s]
			}
			n += 1
		}
	}
	return n
}

// Make the named source hold `bit` and nothing else.
key_bind_move :: proc(name: string, bit: u16) -> bool {
	if s, ok := mouse_source_from_name(name); ok {
		mouse.binds[s] = bit
		return true
	}
	code := sdl.GetScancodeFromName(strings.clone_to_cstring(name, context.temp_allocator))
	if code == .UNKNOWN {
		return false
	}
	core.input.keys[code] = pad_set(bit)
	return true
}

// Unbind every key and mouse source from `bit`.
key_bind_clear :: proc(bit: u16) {
	for &k in core.input.keys {
		k -= pad_set(bit)
	}
	mouse_unbind(bit)
}

key_binds_get :: proc() -> Key_Binds {
	return {core.input.keys, mouse.binds}
}

key_binds_set :: proc(b: Key_Binds) {
	core.input.keys = b.keys
	mouse.binds = b.mouse
}

// The default keyboard and mouse layout.
key_binds_default :: proc() -> (b: Key_Binds) {
	k := &b.keys
	// PC layout: WASD (or the arrows) move, E interacts and confirms, Esc
	// cancels, Shift runs (Circle is the game's default dash button), Tab
	// opens the camp menu, Space does what Triangle does. The mouse turns the
	// camera and its wheel stands in for L1/R1; Q and R are L2 and R2, which
	// the game uses for few things (fishing's lure change among them).
	k[sdl.Scancode.W] = pad_set(PAD_UP)
	k[sdl.Scancode.S] = pad_set(PAD_DOWN)
	k[sdl.Scancode.A] = pad_set(PAD_LEFT)
	k[sdl.Scancode.D] = pad_set(PAD_RIGHT)
	k[sdl.Scancode.UP] = pad_set(PAD_UP)
	k[sdl.Scancode.DOWN] = pad_set(PAD_DOWN)
	k[sdl.Scancode.LEFT] = pad_set(PAD_LEFT)
	k[sdl.Scancode.RIGHT] = pad_set(PAD_RIGHT)
	k[sdl.Scancode.E] = pad_set(PAD_CROSS)
	k[sdl.Scancode.ESCAPE] = pad_set(PAD_CIRCLE)
	k[sdl.Scancode.LSHIFT] = pad_set(PAD_CIRCLE)
	k[sdl.Scancode.TAB] = pad_set(PAD_SQUARE)
	k[sdl.Scancode.SPACE] = pad_set(PAD_TRIANGLE)
	k[sdl.Scancode.RETURN] = pad_set(PAD_START)
	k[sdl.Scancode.BACKSPACE] = pad_set(PAD_SELECT)
	k[sdl.Scancode.Q] = pad_set(PAD_L2)
	k[sdl.Scancode.R] = pad_set(PAD_R2)
	b.mouse[.Left] = PAD_CROSS
	b.mouse[.Right] = PAD_CIRCLE
	b.mouse[.Wheel_Up] = PAD_L1
	b.mouse[.Wheel_Down] = PAD_R1
	return b
}
