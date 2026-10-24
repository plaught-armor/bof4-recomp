// Host input: keyboard and SDL game controllers, mapped to the console pad.
//
// Every keyboard key, controller button and trigger has a binding: the pad
// bits it holds down. Bindings start at the defaults below and can be
// replaced with bind_keys / bind_buttons (the qol config does this). Held
// state is sampled once per poll, so several sources may hold the same bit.
//
// Controllers go through SDL's GameController layer, which maps any known
// pad to an Xbox-style layout. The left stick also drives the d-pad, pressing
// the direction of the 45 degree sector it points into once past the dead
// zone, so menus work with it; `sticks` gives the analog positions to
// features that use them directly.
package psx

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import sdl "vendor:sdl2"

@(private)
MAX_GAMEPADS :: 4

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
// Trigger deflection (0..1) that counts as pressed.
@(private)
TRIGGER_PRESS :: 0.5
// Radial dead zone of the analog sticks (0..1); `sticks` rescales past it.
@(private)
STICK_DEADZONE :: 0.2

// Each rumble sent to the controllers lasts this long (real time) and is
// renewed at half of it while a motor runs, so a motor left on stops soon
// after the game stops polling.
@(private)
RUMBLE_HOLD_MS :: 500

@(private)
Trigger :: enum {
	Left,
	Right,
}

@(private)
input: struct {
	keys:     [sdl.NUM_SCANCODES]u16,
	buttons:  [sdl.GameControllerButton.MAX]u16,
	triggers: [Trigger]u16,
	pads:     [MAX_GAMEPADS]^sdl.GameController,
	pad_ids:  [MAX_GAMEPADS]sdl.JoystickID,
	// Pads that refused a rumble; reported once each.
	no_rumble: [MAX_GAMEPADS]bool,
	// Vblank until which each pad bit stays held by press_for.
	tap_until: [16]u64,
	// Buttons kept from the game until released: those held while the panel
	// was up (pad_game).
	blocked:  u16,
	// The kind of device last used, for button prompts.
	device:   Input_Device,
	// The family of the controller last used or connected; PlayStation
	// until there is one.
	pad_device: Input_Device,
	// Set from BOF4_DEVICE: device and pad_device stay as set.
	device_fixed: bool,
}

// The kind of device the player last pressed something on. Button prompts
// follow it: keycaps for the keyboard and mouse, face-button symbols or
// letters for each controller family.
Input_Device :: enum u8 {
	Keyboard,
	PlayStation,
	Xbox,
	Nintendo,
}

// The kind of device last used.
input_device :: proc() -> Input_Device {
	return input.device
}

// The family of the controller last used or connected (PlayStation when
// none has been): what controller buttons are called.
input_pad_device :: proc() -> Input_Device {
	return input.pad_device == .Keyboard ? .PlayStation : input.pad_device
}

// The controls of an SDL game controller, by their Xbox-style names; A is
// the south face button (on Nintendo pads, the button labelled A).
Pad_Control :: enum u8 {
	A,
	B,
	X,
	Y,
	Back,
	Guide,
	Start,
	Left_Stick,
	Right_Stick,
	Left_Shoulder,
	Right_Shoulder,
	Up,
	Down,
	Left,
	Right,
	Left_Trigger,
	Right_Trigger,
}

// The first controller control (in Pad_Control order) that holds `bit`.
pad_source :: proc(bit: u16) -> (c: Pad_Control, ok: bool) {
	#assert(int(Pad_Control.Right) == int(sdl.GameControllerButton.DPAD_RIGHT))
	for c in Pad_Control.A ..= Pad_Control.Right {
		if input.buttons[sdl.GameControllerButton(c)] & bit != 0 {
			return c, true
		}
	}
	if input.triggers[.Left] & bit != 0 {
		return .Left_Trigger, true
	}
	if input.triggers[.Right] & bit != 0 {
		return .Right_Trigger, true
	}
	return {}, false
}

// Controller axis deflection that counts as using the pad (of 32767).
@(private)
DEVICE_AXIS_USE :: 16000

// The prompt family of an open controller. Unknown pads use Xbox prompts,
// since SDL lays every pad out like one.
@(private)
device_of_pad :: proc(pad: ^sdl.GameController) -> Input_Device {
	#partial switch sdl.GameControllerGetType(pad) {
	case .PS3, .PS4, .PS5:
		return .PlayStation
	case .NINTENDO_SWITCH_PRO:
		return .Nintendo
	}
	// Joy-Con types (left, right, pair) postdate the binding's enum.
	if t := int(sdl.GameControllerGetType(pad)); t >= 11 && t <= 13 {
		return .Nintendo
	}
	return .Xbox
}

// Note a press on a device of kind `d`.
@(private)
device_used :: proc(d: Input_Device) {
	if input.device_fixed {
		return
	}
	input.device = d
	if d != .Keyboard {
		input.pad_device = d
	}
}

// Note a press on the controller with joystick instance id `id`.
@(private)
device_pad_used :: proc(id: sdl.JoystickID) {
	if pad := sdl.GameControllerFromInstanceID(id); pad != nil {
		device_used(device_of_pad(pad))
	}
}

// Emulated vblanks a tap (press_for) usually lasts: two game ticks at the
// slowest tick rate the game uses (15 per second), so its pad poll sees it.
TAP_HOLD :: 8

// Hold `bits` for the next `vblanks` emulated vblanks, on top of whatever the
// player holds; a later call extends a tap still running.
press_for :: proc(bits: u16, vblanks: u64) {
	for i in 0 ..< len(input.tap_until) {
		if bits & (1 << u16(i)) != 0 {
			input.tap_until[i] = max(input.tap_until[i], host.presents + vblanks)
		}
	}
}

// Motor strength scale 0..1, set by pad_set_rumble.
@(private)
rumble_strength: f32

// Motor state last sent to the controllers and when (SDL ticks, ms).
@(private)
rumble: struct {
	small: bool,
	large: u8,
	sent:  u32,
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
	key_binds_set(key_binds_default())
	b := &input.buttons
	b[sdl.GameControllerButton.A] = PAD_CROSS
	b[sdl.GameControllerButton.B] = PAD_CIRCLE
	b[sdl.GameControllerButton.X] = PAD_SQUARE
	b[sdl.GameControllerButton.Y] = PAD_TRIANGLE
	b[sdl.GameControllerButton.LEFTSHOULDER] = PAD_L1
	b[sdl.GameControllerButton.RIGHTSHOULDER] = PAD_R1
	b[sdl.GameControllerButton.BACK] = PAD_SELECT
	b[sdl.GameControllerButton.START] = PAD_START
	b[sdl.GameControllerButton.DPAD_UP] = PAD_UP
	b[sdl.GameControllerButton.DPAD_DOWN] = PAD_DOWN
	b[sdl.GameControllerButton.DPAD_LEFT] = PAD_LEFT
	b[sdl.GameControllerButton.DPAD_RIGHT] = PAD_RIGHT
	input.triggers = {.Left = PAD_L2, .Right = PAD_R2}
	// BOF4_DEVICE fixes the prompt family (for tests).
	input.device_fixed = true
	switch os.get_env("BOF4_DEVICE", context.temp_allocator) {
	case "keyboard":
		input.device = .Keyboard
	case "ps":
		input.device = .PlayStation
	case "xbox":
		input.device = .Xbox
	case "switch":
		input.device = .Nintendo
	case:
		input.device_fixed = false
	}
	input.pad_device = input.device
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
	Source :: union {
		sdl.Scancode,
		Mouse_Source,
	}
	sources := make([]Source, len(names), context.temp_allocator)
	for name, i in names {
		if m, ok := mouse_source_from_name(name); ok {
			sources[i] = m
			continue
		}
		code := sdl.GetScancodeFromName(strings.clone_to_cstring(name, context.temp_allocator))
		if code == .UNKNOWN {
			fmt.eprintln("input: unknown key", name)
			return false
		}
		sources[i] = code
	}
	for &k in input.keys {
		k &= ~bit
	}
	mouse_unbind(bit)
	for s in sources {
		switch v in s {
		case sdl.Scancode:
			input.keys[v] |= bit
		case Mouse_Source:
			mouse_bind(v, bit)
		}
	}
	return true
}

// Make exactly the named controller buttons (SDL names: a, b, x, y, back,
// start, leftshoulder, rightshoulder, leftstick, rightstick, dpup, dpdown,
// dpleft, dpright, plus lefttrigger and righttrigger) hold `bit`.
bind_buttons :: proc(bit: u16, names: []string) -> bool {
	Source :: union {
		sdl.GameControllerButton,
		Trigger,
	}
	sources := make([]Source, len(names), context.temp_allocator)
	for name, i in names {
		switch name {
		case "lefttrigger":
			sources[i] = Trigger.Left
		case "righttrigger":
			sources[i] = Trigger.Right
		case:
			b := sdl.GameControllerGetButtonFromString(strings.clone_to_cstring(name, context.temp_allocator))
			if b == .INVALID {
				fmt.eprintln("input: unknown controller button", name)
				return false
			}
			sources[i] = b
		}
	}
	for &b in input.buttons {
		b &= ~bit
	}
	for &t in input.triggers {
		t &= ~bit
	}
	for s in sources {
		switch v in s {
		case sdl.GameControllerButton:
			input.buttons[v] |= bit
		case Trigger:
			input.triggers[v] |= bit
		}
	}
	return true
}

// CONTROLLERDEVICEADDED: `index` is a device index. Pads present at startup
// arrive through this event too.
@(private)
gamepad_added :: proc(index: i32) {
	for p, k in input.pads {
		if p != nil {
			continue
		}
		pad := sdl.GameControllerOpen(index)
		if pad == nil {
			fmt.eprintln("gamepad: cannot open device", index, sdl.GetError())
			return
		}
		input.pads[k] = pad
		input.no_rumble[k] = false
		input.pad_ids[k] = sdl.JoystickInstanceID(sdl.GameControllerGetJoystick(pad))
		device_used(device_of_pad(pad))
		fmt.eprintln("gamepad: connected", sdl.GameControllerName(pad))
		return
	}
	fmt.eprintln("gamepad: ignoring device", index, "- all", MAX_GAMEPADS, "slots in use")
}

// CONTROLLERDEVICEREMOVED: `id` is a joystick instance id.
@(private)
gamepad_removed :: proc(id: sdl.JoystickID) {
	for &p, k in input.pads {
		if p != nil && input.pad_ids[k] == id {
			sdl.GameControllerClose(p)
			p = nil
			fmt.eprintln("gamepad: disconnected")
		}
	}
}

// Drive the controller motors from the emulated pad's: the large (low
// frequency) motor takes a speed, the small (high frequency) one is on or off.
@(private)
pad_rumble :: proc(small: bool, large: u8) {
	now := sdl.GetTicks()
	running := small || large != 0
	if small == rumble.small && large == rumble.large {
		if !running || now - rumble.sent < RUMBLE_HOLD_MS / 2 {
			return
		}
	}
	rumble = {small, large, now}
	lo := u16(f32(large) / 255 * rumble_strength * 0xffff)
	hi := small ? u16(rumble_strength * 0xffff) : 0
	rumble_send(lo, hi, running ? RUMBLE_HOLD_MS : 0)
}

// Stop the motors (pause); the next poll that runs one starts them again.
@(private)
rumble_stop :: proc() {
	rumble = {}
	rumble_send(0, 0, 0)
}

@(private)
rumble_send :: proc(lo, hi: u16, ms: u32) {
	for p, k in input.pads {
		if p == nil || input.no_rumble[k] {
			continue
		}
		if sdl.GameControllerRumble(p, lo, hi, ms) != 0 {
			input.no_rumble[k] = true
			fmt.eprintln("gamepad: no rumble on", sdl.GameControllerName(p), "-", sdl.GetError())
		}
	}
}

// Held buttons, active-high, in the game's bit layout.
pad_buttons :: proc() -> (held: u16) {
	for down, code in sdl.GetKeyboardStateAsSlice() {
		if down != 0 && code < len(input.keys) {
			held |= input.keys[code]
		}
	}
	for p in input.pads {
		if p != nil {
			held |= gamepad_held(p)
		}
	}
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
	for until, i in input.tap_until {
		if host.presents < until {
			held |= 1 << u16(i)
		}
	}
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

// Clockwise angle of a stick from up, in degrees (-180..180).
stick_angle :: proc(v: [2]f32) -> f64 {
	return math.to_degrees(math.atan2(f64(v.x), f64(-v.y)))
}

@(private)
stick_sector :: proc(v: [2]f32) -> int {
	return int(math.round(stick_angle(v) / 45)) & 7
}

@(private)
gamepad_held :: proc(p: ^sdl.GameController) -> (held: u16) {
	for bits, b in input.buttons {
		if bits != 0 && sdl.GameControllerGetButton(p, sdl.GameControllerButton(b)) != 0 {
			held |= bits
		}
	}
	if axis(p, .TRIGGERLEFT) >= TRIGGER_PRESS {
		held |= input.triggers[.Left]
	}
	if axis(p, .TRIGGERRIGHT) >= TRIGGER_PRESS {
		held |= input.triggers[.Right]
	}
	return
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
	for p in input.pads {
		if p == nil {
			continue
		}
		s.left = stronger(s.left, dead_zone({axis(p, .LEFTX), axis(p, .LEFTY)}))
		s.right = stronger(s.right, dead_zone({axis(p, .RIGHTX), axis(p, .RIGHTY)}))
	}
	if auto_stick != {} {
		s.left = stronger(s.left, auto_stick)
	}
	for e in host.stick_script {
		if host.presents >= e.at && host.presents < e.at + e.hold {
			s.left = stronger(s.left, e.sticks.left)
			s.right = stronger(s.right, e.sticks.right)
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

@(private)
axis :: proc(p: ^sdl.GameController, a: sdl.GameControllerAxis) -> f32 {
	return max(f32(sdl.GameControllerGetAxis(p, a)) / 32767, -1)
}

@(private)
dead_zone :: proc(v: [2]f32) -> [2]f32 {
	m := math.sqrt(v.x * v.x + v.y * v.y)
	if m <= STICK_DEADZONE {
		return {}
	}
	scaled := min((m - STICK_DEADZONE) / (1 - STICK_DEADZONE), 1)
	return v * (scaled / m)
}

@(private)
stronger :: proc(a, b: [2]f32) -> [2]f32 {
	return a.x * a.x + a.y * a.y >= b.x * b.x + b.y * b.y ? a : b
}
