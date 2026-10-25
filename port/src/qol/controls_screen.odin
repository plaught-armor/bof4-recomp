// The Setting screen's Buttons screen, redrawn by the port as a controls
// screen: the controller's action layout and the keyboard and mouse keys.
//
// The game keeps its actions in a table of pad masks (ACTION_TABLE: Confirm,
// Cancel, Action, Menu, Dash, the two camera turns, the two rank changes),
// filled from one of its four layouts (Type 1..4, the byte GAME_TYPE in the
// save) when the Buttons screen or the camp menu closes. The Controller
// device offers those four plus Custom, any button per action, kept in the
// config file ([controller] custom) and written over the game's table each
// vblank the table holds the saved type's layout.
//
// The Keyboard device lists the console buttons with the keys and mouse
// sources that hold each (psx rebinding): Confirm catches the next key or
// mouse press and moves it to the row's button, Square clears the row. Its
// scheme is Default or Custom; going back to Default keeps the custom
// layout to return to while the screen is open. Leaving the screen writes
// what changed to the config file ([keys], [controller]).
//
// The game's tick still slides the window in and out (steps 0 and 4); the
// port takes step 1 once the window has settled, and draws the window
// (kind 9) in place of the game's pad picture.
package qol

import "core:fmt"
import "core:strings"

import "ps:psx"

// a0 the menu record; and the window kind's draw (no arguments, the window
// in WIN_CURRENT).
// Per overlay (setting_menu.odin).
@(private = "file")
BUTTONS_TICK := [Setting_Overlay]u32{.Camp = 0x801b6fd4, .Title = 0x801ad2fc}
@(private = "file")
BUTTONS_DRAW := [Setting_Overlay]u32{.Camp = 0x801afcac, .Title = 0x801b2688}
@(private = "file")
BUTTONS_WIN :: 0x8011dd34
// In a window: s16 x, y.
@(private = "file")
WIN_X :: 8
@(private = "file")
WIN_Y :: 0xa
// x where the window stops sliding in.
@(private = "file")
SETTLED_X :: 64
// In the menu record: the screen's step.
@(private = "file")
STEP :: 3
@(private = "file")
STEP_OPEN :: 1
@(private = "file")
STEP_CLOSE :: 4
// u8 the game's layout, 0..3.
@(private = "file")
GAME_TYPE :: 0x8011ad78
@(private = "file")
SELECT_MESSAGE := [Setting_Overlay]u32{.Camp = 0x909e, .Title = 0x90bb}
// The windows' "Setting" tab.
@(private = "file")
TITLE_TAB :: 0x16

@(private)
ACTION_TABLE :: 0x80116d84 // u16 pad mask per Action

@(private)
Action :: enum u8 {
	Confirm,
	Cancel,
	Action,
	Menu,
	Dash,
	Turn_R,
	Turn_L,
	Rank_R,
	Rank_L,
}
@(private = "file")
Layout :: [Action]u16

// The game's four layouts (in its camp overlay at 0x801e8464, the title's
// at 0x801b7498), in Action
// order.
@(private = "file")
GAME_LAYOUTS := [4][len(Action)]u16 {
	{psx.PAD_CROSS, psx.PAD_TRIANGLE, psx.PAD_TRIANGLE, psx.PAD_SQUARE, psx.PAD_CIRCLE, psx.PAD_R1, psx.PAD_L1, psx.PAD_R2, psx.PAD_L2},
	{psx.PAD_CROSS, psx.PAD_TRIANGLE, psx.PAD_TRIANGLE, psx.PAD_SQUARE, psx.PAD_CIRCLE, psx.PAD_R2, psx.PAD_L2, psx.PAD_R1, psx.PAD_L1},
	{psx.PAD_CROSS, psx.PAD_TRIANGLE, psx.PAD_CIRCLE, psx.PAD_SQUARE, psx.PAD_TRIANGLE, psx.PAD_R1, psx.PAD_L1, psx.PAD_R2, psx.PAD_L2},
	{psx.PAD_CROSS, psx.PAD_TRIANGLE, psx.PAD_CIRCLE, psx.PAD_SQUARE, psx.PAD_TRIANGLE, psx.PAD_R2, psx.PAD_L2, psx.PAD_R1, psx.PAD_L1},
}
@(private = "file")
ACTION_LABELS := [Action]string {
	.Confirm = "Confirm",
	.Cancel  = "Cancel",
	.Action  = "Action",
	.Menu    = "Menu",
	.Dash    = "Dash",
	.Turn_R  = "Turn R",
	.Turn_L  = "Turn L",
	.Rank_R  = "Rank R",
	.Rank_L  = "Rank L",
}
// Buttons an action may take: not the d-pad.
@(private = "file")
ACTION_BUTTONS :: ~u16(psx.PAD_UP | psx.PAD_DOWN | psx.PAD_LEFT | psx.PAD_RIGHT)

// The Keyboard device's rows: console button, label, what it does beyond
// the action table.
@(private = "file")
Key_Row :: struct {
	bit:   u16,
	label: string,
	hint:  string,
}
@(private = "file")
KEY_ROWS := [?]Key_Row {
	{psx.PAD_UP, "Up", "Move"},
	{psx.PAD_DOWN, "Down", "Move"},
	{psx.PAD_LEFT, "Left", "Move"},
	{psx.PAD_RIGHT, "Right", "Move"},
	{psx.PAD_CROSS, "Cross", ""},
	{psx.PAD_CIRCLE, "Circle", ""},
	{psx.PAD_SQUARE, "Square", ""},
	{psx.PAD_TRIANGLE, "Triangle", ""},
	{psx.PAD_L1, "L1", ""},
	{psx.PAD_R1, "R1", ""},
	{psx.PAD_L2, "L2", ""},
	{psx.PAD_R2, "R2", ""},
	{psx.PAD_START, "Start", "Menu"},
	{psx.PAD_SELECT, "Select", "Help"},
}
// Short names of sources whose config names do not fit a row.
@(private = "file")
SHORT_NAMES := [?][2]string {
	{"Left Shift", "LShift"},
	{"Right Shift", "RShift"},
	{"Left Ctrl", "LCtrl"},
	{"Right Ctrl", "RCtrl"},
	{"Left Alt", "LAlt"},
	{"Right Alt", "RAlt"},
	{"Escape", "Esc"},
	{"Return", "Enter"},
	{"Backspace", "BkSp"},
	{"Mouse Left", "M-Left"},
	{"Mouse Middle", "M-Mid"},
	{"Mouse Right", "M-Right"},
	{"Mouse X1", "M-X1"},
	{"Mouse X2", "M-X2"},
	{"Wheel Up", "Whl-Up"},
	{"Wheel Down", "Whl-Dn"},
}
// Sources shown per key row; a row with more ends in "..".
@(private = "file")
KEY_SHOWN :: 3

@(private = "file")
Device :: enum u8 {
	Controller,
	Keyboard,
}
@(private = "file")
DEVICE_LABELS := [Device]string {
	.Controller = "Controller",
	.Keyboard   = "Keyboard",
}
@(private = "file")
SCHEME_CUSTOM :: 4

// Layout: the window (x from the game's slide, less WIN_LEFT), its two
// parts, rows and columns.
@(private = "file")
WIN_LEFT :: 32
@(private = "file")
WIN_W :: 256
@(private = "file")
HEAD_H :: 40
@(private = "file")
LIST_H :: 124
@(private = "file")
ROW_TOP :: 6
@(private = "file")
TEXT_X :: 10
@(private = "file")
HINT_X :: 72
@(private = "file")
KEYS_X :: 136
@(private = "file")
VISIBLE :: 8
@(private = "file")
INFO_LINE :: 14

@(private = "file")
controls: struct {
	ticks:       [Setting_Overlay]psx.Func_Proc,
	device:      Device,
	// Cursor: 0 device, 1 scheme, then the list; the list's first row shown.
	row:         int,
	top:         int,
	// Waiting for the press to give the row.
	catching:    bool,
	// The controller's Custom layout and whether it is on.
	custom:      Layout,
	custom_on:   bool,
	// The keyboard's custom layout put aside by choosing Default.
	keys_custom: psx.Key_Binds,
	keys_kept:   bool,
	keys_dirty:  bool,
	pad_dirty:   bool,
}

@(private)
controls_init :: proc() -> bool {
	ok: bool
	if controls.ticks, ok = setting_hook(BUTTONS_TICK, {.Camp = proc() {setting_overlay = .Camp; controls_tick()}, .Title = proc() {setting_overlay = .Title; controls_tick()}}, "buttons"); !ok {
		return false
	}
	_, ok = setting_hook(BUTTONS_DRAW, {.Camp = proc() {setting_overlay = .Camp; controls_draw()}, .Title = proc() {setting_overlay = .Title; controls_draw()}}, "buttons")
	return ok
}

// [controller] custom: "off", or a console button name per action in Action
// order, comma separated.
@(private)
parse_controller_custom :: proc(value: string) -> bool {
	if strings.trim_space(value) == "off" {
		controls.custom_on = false
		return true
	}
	names := strings.split(value, ",", context.temp_allocator)
	if len(names) != len(Action) {
		return false
	}
	for n, i in names {
		controls.custom[Action(i)] = psx.pad_bit_from_name(strings.trim_space(n)) or_return
	}
	controls.custom_on = true
	return true
}

// Put the Custom layout in the game's table whenever the game has filled it
// with its saved layout.
@(private)
controls_vblank :: proc() {
	if !controls.custom_on {
		return
	}
	game := game_layout()
	if table_get() == game {
		table_set(controls.custom)
	}
}

@(private)
action_mask :: proc(a: Action) -> u16 {
	return u16(psx.lhu(ACTION_TABLE + 2 * u32(a)))
}

@(private = "file")
table_get :: proc() -> (l: Layout) {
	for a in Action {
		l[a] = action_mask(a)
	}
	return
}

@(private = "file")
table_set :: proc(l: Layout) {
	for a in Action {
		psx.sh(ACTION_TABLE + 2 * u32(a), u32(l[a]))
	}
}

// The saved type's layout.
@(private = "file")
game_layout :: proc() -> Layout {
	return transmute(Layout)GAME_LAYOUTS[psx.lbu(GAME_TYPE) & 3]
}

// The layout in force: Custom, or the saved type's.
@(private = "file")
layout_now :: proc() -> Layout {
	return controls.custom_on ? controls.custom : game_layout()
}

@(private = "file")
list_len :: proc() -> int {
	return controls.device == .Controller ? len(Action) : len(KEY_ROWS)
}

// The Buttons screen's tick (a0 the menu record): the game's while the
// window slides, the port's once it has settled.
@(private = "file")
controls_tick :: proc() {
	menu := psx.cpu.r[4]
	step := psx.lbu(menu + STEP)
	settled := i16(psx.lhu(BUTTONS_WIN + WIN_X)) == SETTLED_X
	if step != STEP_OPEN || !settled {
		if step == 0 {
			controls.row = 0
			controls.top = 0
			controls.catching = false
		}
		controls.ticks[setting_overlay]()
		psx.sh(INFO_TEXT, INFO_NONE)
		return
	}
	psx.sh(INFO_TEXT, INFO_NONE)
	if controls.catching {
		catch_tick()
		return
	}
	pressed := u16(psx.lhu(PAD_PRESSED))
	repeat := u16(psx.lhu(PAD_REPEAT))
	confirm := pressed & u16(psx.lhu(CONFIRM_MASK)) != 0
	switch {
	case pressed & psx.PAD_SELECT != 0:
		psx.sb(SELECT_STATE, 0)
		game_routine(SHOW_MESSAGE, {SELECT_MESSAGE[setting_overlay], 0, 0, 0, 0})
	case pressed & u16(psx.lhu(CANCEL_MASK)) != 0:
		game_routine(SOUND, {SOUND_CANCEL, 0, 0, 0, 0})
		table_set(layout_now())
		controls_save()
		psx.sb(menu + STEP, STEP_CLOSE)
	case repeat & (psx.PAD_UP | psx.PAD_DOWN) != 0:
		game_routine(SOUND, {SOUND_MOVE, 0, 0, 0, 0})
		rows := 2 + list_len()
		controls.row = (controls.row + (repeat & psx.PAD_DOWN != 0 ? 1 : -1)) %% rows
		if controls.row >= 2 {
			i := controls.row - 2
			controls.top = clamp(controls.top, i - VISIBLE + 1, i)
		}
	case controls.row < 2 && (repeat & (psx.PAD_LEFT | psx.PAD_RIGHT) != 0 || confirm):
		dir := repeat & psx.PAD_LEFT != 0 ? -1 : 1
		if controls.row == 0 {
			game_routine(SOUND, {SOUND_MOVE, 0, 0, 0, 0})
			controls.device = Device((int(controls.device) + 1) %% len(Device))
			controls.top = 0
		} else {
			scheme_step(dir)
		}
	case controls.row >= 2 && confirm:
		game_routine(SOUND, {SOUND_CONFIRM, 0, 0, 0, 0})
		controls.catching = true
		if controls.device == .Keyboard {
			psx.key_catch_start()
		}
	case controls.row >= 2 && controls.device == .Keyboard && pressed & psx.PAD_SQUARE != 0:
		game_routine(SOUND, {SOUND_CANCEL, 0, 0, 0, 0})
		psx.key_bind_clear(KEY_ROWS[controls.row - 2].bit)
		controls.keys_dirty = true
	}
}

// Step the scheme row: the game's types and Custom, or Default and Custom.
@(private = "file")
scheme_step :: proc(dir: int) {
	if controls.device == .Keyboard {
		current := psx.key_binds_get()
		if current == psx.key_binds_default() {
			if !controls.keys_kept {
				game_routine(SOUND, {SOUND_REFUSE, 0, 0, 0, 0})
				return
			}
			psx.key_binds_set(controls.keys_custom)
		} else {
			controls.keys_custom = current
			controls.keys_kept = true
			psx.key_binds_set(psx.key_binds_default())
		}
		game_routine(SOUND, {SOUND_MOVE, 0, 0, 0, 0})
		controls.keys_dirty = true
		return
	}
	game_routine(SOUND, {SOUND_MOVE, 0, 0, 0, 0})
	scheme := (pad_scheme() + dir) %% (SCHEME_CUSTOM + 1)
	if scheme == SCHEME_CUSTOM {
		if !controls.custom_on && controls.custom == (Layout{}) {
			controls.custom = game_layout()
		}
		controls.custom_on = true
	} else {
		controls.custom_on = false
		psx.sb(GAME_TYPE, u32(scheme))
	}
	table_set(layout_now())
	controls.pad_dirty = true
}

@(private = "file")
pad_scheme :: proc() -> int {
	return controls.custom_on ? SCHEME_CUSTOM : int(psx.lbu(GAME_TYPE) & 3)
}

// Wait for the press that gives the cursor's row its button or key.
@(private = "file")
catch_tick :: proc() {
	i := controls.row - 2
	if controls.device == .Keyboard {
		name, caught := psx.key_catch_take()
		if !caught {
			return
		}
		controls.catching = false
		if !psx.key_bind_move(name, KEY_ROWS[i].bit) {
			game_routine(SOUND, {SOUND_REFUSE, 0, 0, 0, 0})
			return
		}
		game_routine(SOUND, {SOUND_CONFIRM, 0, 0, 0, 0})
		controls.keys_dirty = true
		return
	}
	pressed := u16(psx.lhu(PAD_PRESSED)) & ACTION_BUTTONS
	if pressed == 0 {
		return
	}
	controls.catching = false
	bit := pressed & (~pressed + 1) // the lowest
	a := Action(i)
	l := layout_now()
	// Confirm and Cancel must stay apart, or no menu can be left.
	other := a == .Confirm ? Action.Cancel : Action.Confirm
	if (a == .Confirm || a == .Cancel) && l[other] == bit {
		game_routine(SOUND, {SOUND_REFUSE, 0, 0, 0, 0})
		return
	}
	game_routine(SOUND, {SOUND_CONFIRM, 0, 0, 0, 0})
	l[a] = bit
	controls.custom = l
	controls.custom_on = true
	table_set(l)
	controls.pad_dirty = true
}

@(private = "file")
controls_save :: proc() {
	entries := make([dynamic]Config_Entry, context.temp_allocator)
	if controls.pad_dirty {
		value := "off"
		if controls.custom_on {
			names: [len(Action)]string
			for a in Action {
				names[a] = pad_name(controls.custom[a])
			}
			value = strings.join(names[:], ", ", context.temp_allocator)
		}
		append(&entries, Config_Entry{"controller", "custom", value})
	}
	if controls.keys_dirty {
		for r in KEY_ROWS {
			sources: [32]string
			n := min(psx.key_sources(r.bit, sources[:]), len(sources))
			value := strings.join(sources[:n], ", ", context.temp_allocator)
			append(&entries, Config_Entry{"keys", pad_name(r.bit), value})
		}
	}
	controls.pad_dirty = false
	controls.keys_dirty = false
	controls.keys_kept = false
	if len(entries) > 0 && !config_write(entries[:]) {
		psx.osd_toast("Controls not saved")
	}
}

// The config name of one console button.
@(private = "file")
pad_name :: proc(bit: u16) -> string {
	for p in psx.PAD_NAMES {
		if p.bit == bit {
			return p.name
		}
	}
	return "?"
}

// A console button by what the controller in use calls the control bound to
// it; by the console's name when none is.
@(private = "file")
pad_label :: proc(bit: u16) -> string {
	if c, ok := psx.pad_source(bit); ok {
		return PAD_CONTROL_NAMES[psx.input_pad_device()][c]
	}
	for r in KEY_ROWS {
		if r.bit == bit {
			return r.label
		}
	}
	return "?"
}

// A source name short enough for a menu row or a line of text.
@(private)
short_name :: proc(name: string) -> string {
	for s in SHORT_NAMES {
		if strings.equal_fold(s[0], name) {
			return s[1]
		}
	}
	return name
}

// What a console button does: its row hint, else the actions it holds.
@(private = "file")
key_hint :: proc(r: Key_Row) -> string {
	if r.hint != "" {
		return r.hint
	}
	l := layout_now()
	for a in Action {
		if l[a] == r.bit {
			return ACTION_LABELS[a]
		}
	}
	return ""
}

// The Buttons window's draw (kind 9), the window in WIN_CURRENT.
@(private = "file")
controls_draw :: proc() {
	win := psx.lw(WIN_CURRENT)
	x := int(i16(psx.lhu(win + WIN_X))) - WIN_LEFT
	y := int(i16(psx.lhu(win + WIN_Y)))
	settled := int(i16(psx.lhu(win + WIN_X))) == SETTLED_X
	menu_window(x, y, WIN_W, HEAD_H)
	menu_window(x, y + HEAD_H, WIN_W, LIST_H)
	game_routine(TITLE_DRAW, {u32(x + 4), u32(y - 4), TITLE_TAB, 0, 0})
	right := x + WIN_W - TEXT_X
	menu_text(x + TEXT_X, y + ROW_TOP, "Device")
	menu_text_right(right, y + ROW_TOP, DEVICE_LABELS[controls.device])
	menu_text(x + TEXT_X, y + ROW_TOP + MENU_LINE_H, "Scheme")
	menu_text_right(right, y + ROW_TOP + MENU_LINE_H, scheme_label())
	list_y := y + HEAD_H + ROW_TOP
	for i in controls.top ..< min(controls.top + VISIBLE, list_len()) {
		ry := list_y + (i - controls.top) * MENU_LINE_H
		catching := controls.catching && controls.row == i + 2
		if controls.device == .Controller {
			a := Action(i)
			menu_text(x + TEXT_X, ry, ACTION_LABELS[a])
			value := catching ? "Press a button" : pad_label(layout_now()[a])
			menu_text_right(right, ry, value, catching ? MENU_YELLOW : MENU_WHITE)
		} else {
			r := KEY_ROWS[i]
			menu_text(x + TEXT_X, ry, r.label)
			menu_text(x + HINT_X, ry, key_hint(r), MENU_GREY)
			value := catching ? "Press a key" : keys_text(r.bit)
			menu_text_right(right, ry, menu_text_fit(value, right - x - KEYS_X), catching ? MENU_YELLOW : MENU_WHITE)
		}
	}
	if !settled {
		return
	}
	cy := controls.row < 2 ? y + ROW_TOP + controls.row * MENU_LINE_H : list_y + (controls.row - 2 - controls.top) * MENU_LINE_H
	game_routine(CURSOR_DRAW, {u32(x + 4), u32(cy - 2), WIN_W - 8, MENU_LINE_H + 2, 0})
	line1, line2 := info_text()
	info := INFO_AT
	menu_text(info.x, info.y, line1)
	menu_text(info.x, info.y + INFO_LINE, line2)
}

@(private = "file")
scheme_label :: proc() -> string {
	if controls.device == .Keyboard {
		return psx.key_binds_get() == psx.key_binds_default() ? "Default" : "Custom"
	}
	s := pad_scheme()
	return s == SCHEME_CUSTOM ? "Custom" : fmt.tprintf("Type %d", s + 1)
}

@(private = "file")
keys_text :: proc(bit: u16) -> string {
	sources: [KEY_SHOWN]string
	n := psx.key_sources(bit, sources[:])
	if n == 0 {
		return "-"
	}
	shown := make([]string, min(n, KEY_SHOWN), context.temp_allocator)
	for &s, i in shown {
		s = short_name(sources[i])
	}
	text := strings.join(shown, ", ", context.temp_allocator)
	return n > KEY_SHOWN ? strings.concatenate({text, " .."}, context.temp_allocator) : text
}

@(private = "file")
info_text :: proc() -> (string, string) {
	switch {
	case controls.catching && controls.device == .Keyboard:
		return "Press the key or mouse button", "to move it to this button."
	case controls.catching:
		return "Press the button for this action.", ""
	case controls.row == 0:
		return "Controller or keyboard and mouse.", "(Use Right/Left to switch.)"
	case controls.row == 1 && controls.device == .Keyboard:
		return "Default or your own keys.", "(Use Right/Left to switch.)"
	case controls.row == 1:
		return "Type 1-4 or your own layout.", "(Use Right/Left to select.)"
	case controls.device == .Keyboard:
		return "Confirm: add a key or button.", "Square: clear this button."
	}
	return "Confirm, then press a button.", ""
}
