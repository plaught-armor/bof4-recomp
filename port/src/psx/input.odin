// Host input for the console pad, on ps:core's input (core/input.odin):
// bindings, controllers, rumble and taps live there. This file keeps what is
// BoF4's: the pad bit layout, mouse sources, the left stick driving the
// d-pad, scripted and replayed input, the autopilot, and the OSD panel and
// qol hooks between the player and the game.
//
// Every controller feeds the one pad (core.input_init(shared = true)). The
// left stick also drives the d-pad, pressing the direction of the 45 degree
// sector it points into once past the dead zone, so menus work with it;
// `sticks` gives the analog positions to features that use them directly.
package psx

import "core:math"
import "ps:core"

// D-pad bits of the eight 45 degree sectors around a stick, clockwise from up.
STICK_SECTORS := [8]u16 {
	PAD_UP,
	PAD_UP | PAD_RIGHT,
	PAD_RIGHT,
	PAD_RIGHT | PAD_DOWN,
	PAD_DOWN,
	PAD_DOWN | PAD_LEFT,
	PAD_LEFT,
	PAD_LEFT | PAD_UP,
}

@(private)
input: struct {
	// Buttons kept from the game until released: those held while the panel
	// was up (pad_game).
	blocked: u16,
}

Input_Device :: core.Input_Device
Pad_Control :: core.Pad_Control

input_device :: core.input_device
input_pad_device :: core.input_pad_device
stick_angle :: core.stick_angle

// core.Buttons is in pad wire order with byte 3 in the low half; the game's
// PAD_ masks have it in the high half.
@(private)
pad_bits :: proc(b: core.Buttons) -> u16 {
	v := transmute(u16)b
	return v << 8 | v >> 8
}

@(private)
pad_set :: proc(bits: u16) -> core.Buttons {
	return transmute(core.Buttons)(bits << 8 | bits >> 8)
}

// The first controller control (in Pad_Control order) that holds `bit`.
pad_source :: proc(bit: u16) -> (c: Pad_Control, ok: bool) {
	return core.pad_source(pad_set(bit))
}

// Emulated vblanks a tap (press_for) usually lasts: two game ticks at the
// slowest tick rate the game uses (15 per second), so its pad poll sees it.
TAP_HOLD :: 8

// Hold `bits` for the next `vblanks` emulated vblanks, on top of whatever the
// player holds; a later call extends a tap still running.
press_for :: proc(bits: u16, vblanks: u64) {
	core.input_tap(0, pad_set(bits), host.presents + vblanks)
}

// Console button names as used in config files.
PAD_NAMES := [?]struct {
	name: string,
	bit:  u16,
} {
	{"cross", PAD_CROSS},
	{"circle", PAD_CIRCLE},
	{"square", PAD_SQUARE},
	{"triangle", PAD_TRIANGLE},
	{"l1", PAD_L1},
	{"r1", PAD_R1},
	{"l2", PAD_L2},
	{"r2", PAD_R2},
	{"start", PAD_START},
	{"select", PAD_SELECT},
	{"up", PAD_UP},
	{"down", PAD_DOWN},
	{"left", PAD_LEFT},
	{"right", PAD_RIGHT},
}

@(private)
input_init :: proc() {
	core.input_init(shared = true)
	key_binds_set(key_binds_default())
	core.input_bind_standard()
	// The digital pad has no L3/R3.
	core.bind_buttons({.L3, .R3}, nil)
}

// The pad bit for a config name such as "cross" or "l1".
pad_bit_from_name :: proc(name: string) -> (bit: u16, ok: bool) {
	for p in PAD_NAMES {
		if p.name == name {
			return p.bit, true
		}
	}
	return 0, false
}

// Make exactly the named keys (SDL scancode names, e.g. "Z", "Space",
// "Left Shift") and mouse sources (MOUSE_NAMES, e.g. "Mouse Left", "Wheel
// Up") hold `bit`. All names are checked before anything changes.
bind_keys :: proc(bit: u16, names: []string) -> bool {
	keys := make([dynamic]string, 0, len(names), context.temp_allocator)
	mice := make([dynamic]Mouse_Source, 0, len(names), context.temp_allocator)
	for name in names {
		if m, ok := mouse_source_from_name(name); ok {
			append(&mice, m)
		} else {
			append(&keys, name)
		}
	}
	core.bind_keys(pad_set(bit), keys[:]) or_return
	mouse_unbind(bit)
	for m in mice {
		mouse_bind(m, bit)
	}
	return true
}

// Make exactly the named controller buttons (SDL names: a, b, x, y, back,
// start, leftshoulder, rightshoulder, leftstick, rightstick, dpup, dpdown,
// dpleft, dpright, plus lefttrigger and righttrigger) hold `bit`.
bind_buttons :: proc(bit: u16, names: []string) -> bool {
	return core.bind_buttons(pad_set(bit), names)
}

// Drive the controller motors from the emulated pad's.
@(private)
pad_rumble :: proc(small: bool, large: u8) {
	core.input_rumble(0, small, large)
}

// Stop the motors (pause); the next poll that runs one starts them again.
@(private)
rumble_stop :: proc() {
	core.input_rumble_stop()
}

// Held buttons, active-high, in the game's bit layout.
pad_buttons :: proc() -> (held: u16) {
	held = pad_bits(core.input_poll(host.presents)[0].buttons + core.replay_buttons(0, host.presents))
	for p in host.script {
		if host.presents >= p.at && host.presents < p.at + p.hold {
			held |= p.mask
		}
	}
	if left := sticks().left; left != {} {
		held |= STICK_SECTORS[stick_sector(left)]
	}
	held |= mouse_held()
	held |= auto_pad
	record_pad(held)
	return held
}

// The buttons the game sees. While the OSD panel is up it takes the pad, so
// the game sees none; a button held when the panel closes stays hidden until
// it is released, so the press that closed the panel does not reach the game.
@(private)
pad_game :: proc() -> u16 {
	if preload_child {
		return 0
	}
	held := pad_buttons()
	if osd_panel_shown {
		input.blocked = held
		return 0
	}
	input.blocked &= held
	held &~= input.blocked
	if pad_hook != nil {
		held = pad_hook(held)
	}
	return held
}

// Test autopilot input (qol autoplay.odin): buttons held and the left
// stick, merged with the player's like scripted input.
auto_pad: u16
auto_stick: [2]f32

// Rewrites the buttons the game sees (after the panel's blocking), e.g. to
// move a button's job to another on some screens; set by the qol package.
pad_hook: proc(held: u16) -> u16

@(private)
stick_sector :: proc(v: [2]f32) -> int {
	return int(math.round(stick_angle(v) / 45)) & 7
}

// Analog stick positions, x right and y down, each component in -1..1 with
// the dead zone removed. With several pads, the most deflected stick wins.
Sticks :: struct {
	left, right: [2]f32,
}

sticks :: proc() -> (s: Sticks) {
	if preload_child {
		return
	}
	p := core.input_poll(host.presents)[0]
	s.left = core.dead_zone(p.left)
	s.right = core.dead_zone(p.right)
	if auto_stick != {} {
		s.left = core.stronger(s.left, auto_stick)
	}
	rl, rr := core.replay_sticks(0, host.presents)
	s.left = core.stronger(s.left, rl)
	s.right = core.stronger(s.right, rr)
	for e in host.stick_script {
		if host.presents >= e.at && host.presents < e.at + e.hold {
			s.left = core.stronger(s.left, e.sticks.left)
			s.right = core.stronger(s.right, e.sticks.right)
		}
	}
	// After the scripted and replayed moves, as pad_buttons records its
	// merged buttons, so recording during a replay keeps them.
	record_sticks(s)
	if sticks_left_blocked {
		s.left = {}
	}
	return
}

// While set, the game and the qol walking code see the left stick at rest
// (the map editor takes the pad); set by the qol package.
sticks_left_blocked: bool
