// The Setting screen's Options screen, hand-ported from the game's tick
// (OPTIONS_TICK) and its right-hand windows draw (setting_menu.odin hooks
// that one) so the port's options sit among the game's own rows: the stick
// under Dash, the camera rows under Camera, Hold to read under Text, Latency
// under SE. The list scrolls, VISIBLE rows at a time.
//
// Game rows keep the game's look and data: labels, choice labels and Info
// messages by message id, value bytes through the game's pointer table,
// choice positions and ranges from its tables. The Text row gains a fourth
// choice, Instant: the game's Fast plus `text.instant`, since the game's
// text code indexes its tables by the byte (0..2). The port's rows show
// toggles as the game's ON/OFF choices, other values as text, and their help
// in the Info window. Leaving the screen writes what changed of the port's
// options to the config file.
//
// Not ported: the draw's mode for menu state 3 (the game's Screen command,
// now the port's Display page), which shows a second value table.
package qol

import cpu "ps:psx/cpu"
import host "ps:psx/host"

// a0 the menu record. Per overlay (setting_menu.odin), as the tables and
// message ids.
@(private = "file")
OPTIONS_TICK := [Setting_Overlay]u32{.Camp = 0x801b6c04, .Title = 0x801acf2c}
// Game tables: u32 address of each row's value byte; u8 most value of each
// row; u8 count of each row's choices; s16 x, y of each choice, three per
// row; s16 x, y, u16 width, u8 height of the two windows; u8 u0, v0, u1, v1
// of each volume bar's texture.
@(private = "file")
GAME_VALUES := [Setting_Overlay]u32{.Camp = 0x801e8400, .Title = 0x801b744c}
@(private = "file")
GAME_MOST := [Setting_Overlay]u32{.Camp = 0x801b99bc, .Title = 0x801b5014}
@(private = "file")
GAME_CHOICES := [Setting_Overlay]u32{.Camp = 0x801b9700, .Title = 0x801b5278}
@(private = "file")
GAME_CHOICE_AT := [Setting_Overlay]u32{.Camp = 0x801b9708, .Title = 0x801b5280}
@(private = "file")
GAME_WINDOWS := [Setting_Overlay]u32{.Camp = 0x801b96e0, .Title = 0x801b5258}
@(private = "file")
GAME_BAR_UV := [Setting_Overlay]u32{.Camp = 0x801b96f8, .Title = 0x801b5270}
// Message ids: + row; + choice, counted over the rows; + row.
@(private = "file")
GAME_LABEL := [Setting_Overlay]u32{.Camp = 0x803d, .Title = 0x8094}
@(private = "file")
GAME_CHOICE_LABEL := [Setting_Overlay]u32{.Camp = 0x8045, .Title = 0x809d}
@(private = "file")
GAME_INFO := [Setting_Overlay]u32{.Camp = 0x8058, .Title = 0x80b0}
@(private = "file")
SELECT_MESSAGE := [Setting_Overlay]u32{.Camp = 0x909d, .Title = 0x90ba}
// a0 x0, a1 y0, a2 x1, a3 y1, [sp+16] style.
@(private = "file")
LINE_DRAW :: 0x8015241c
// The tick sets the sound mode from the Sound row's byte each frame.
@(private = "file")
OPTION_SOUND :: 0x8011ad75
@(private = "file")
SOUND_STEREO :: 0x80160b64
@(private = "file")
SOUND_MONO :: 0x80160b54
// Pad state: switching Vib on gives a pulse (timer, on, strength).
@(private = "file")
PAD_STATE :: 0x80116d0c
@(private = "file")
RUMBLE_TIMER :: 41
@(private = "file")
RUMBLE_ON :: 36
@(private = "file")
RUMBLE_LEVEL :: 37
@(private = "file")
RUMBLE_PULSE :: 10
// In SETTING_WIN: the game's cursor row (u8).
@(private = "file")
OPTIONS_ROW :: 0xc

@(private = "file")
Game_Row :: enum u8 {
	Vib,
	Dash,
	Camera,
	D_Pad,
	Text,
	Sound,
	BGM,
	SE,
}
// Rows from BGM on are volume bars, stepped by VOLUME_STEP.
@(private = "file")
VOLUME_FIRST :: Game_Row.BGM
@(private = "file")
VOLUME_STEP :: 4
@(private = "file")
TEXT_CHOICES :: 4
@(private = "file")
TEXT_INSTANT :: 3
@(private = "file")
// The Text row's choices, short so a fourth fits: the game's own words
// (Slow, Norm, Fast) leave no room for Instant.
TEXT_LABELS :: [TEXT_CHOICES]string{"Slow", "Nrml", "Fast", "Inst"}
// x span the Text row's choices spread over, evenly spaced.
@(private = "file")
TEXT_SPAN :: [2]int{76, 206}

// The rows in order: a game row, or a port option by section and key.
@(private = "file")
Layout_Row :: struct {
	game:         Game_Row,
	section, key: string,
}
@(private = "file")
LAYOUT := [?]Layout_Row {
	{game = .Vib},
	{game = .Dash},
	{section = "move", key = "stick"},
	{section = "move", key = "run_tilt"},
	{game = .Camera},
	{section = "camera", key = "third_person"},
	{section = "camera", key = "rotate_speed"},
	{section = "camera", key = "hold_to_spin"},
	{section = "camera", key = "stick"},
	{section = "camera", key = "stick_speed"},
	{section = "camera", key = "stick_all_maps"},
	{section = "camera", key = "mouse"},
	{section = "camera", key = "mouse_speed"},
	{section = "mouse", key = "menus"},
	{section = "camera", key = "screen_shake"},
	{game = .D_Pad},
	{game = .Text},
	{section = "text", key = "hold_to_advance"},
	{game = .Sound},
	{game = .BGM},
	{game = .SE},
	{section = "audio", key = "latency_ms"},
}

// Layout: rows shown at once, the first one's y and the step, in the
// windows. x of labels and their underline, choices and their underline,
// volume bars, and a port value; the label room.
@(private = "file")
VISIBLE :: 8
@(private = "file")
ROW_TOP :: 9
@(private = "file")
ROW_STEP :: 16
@(private = "file")
LABEL_X :: 6
@(private = "file")
LABEL_LINE :: [2]int{8, 66}
@(private = "file")
LABEL_W :: 60
@(private = "file")
CHOICE_LINE :: [2]int{80, 196}
@(private = "file")
LINE_BELOW :: 12
@(private = "file")
LINE_STYLE :: 2
@(private = "file")
VALUE_X :: 80
// A toggle's ON and OFF: the game's Vib choices (+ GAME_CHOICE_LABEL) and
// their x.
@(private = "file")
TOGGLE_ON :: 1
@(private = "file")
TOGGLE_OFF :: 0
@(private = "file")
TOGGLE_X :: [2]int{162, 80} // off, on
// Volume bar: quad from x BAR_X, BAR_TOP..BAR_BOTTOM below the row's y,
// length from the value; its line; the Min and Max marks (u in the texture
// page the quad sets) BAR_MARK_Y below.
@(private = "file")
BAR_X :: 92
@(private = "file")
BAR_TOP :: 6
@(private = "file")
BAR_BOTTOM :: 10
@(private = "file")
BAR_LINE :: [2]int{92, 188}
@(private = "file")
BAR_LINE_BELOW :: 11
@(private = "file")
BAR_LINE_STYLE :: 3
@(private = "file")
BAR_QUAD_TAG :: 0x09000000
@(private = "file")
BAR_QUAD :: 0x2c808080
@(private = "file")
BAR_CLUT :: 0x3c41
@(private = "file")
BAR_PAGE :: 0x0d
@(private = "file")
BAR_QUAD_BYTES :: 40
@(private = "file")
MARK_TAG :: 0x04000000
@(private = "file")
MARK_SPRITE :: 0x64808080
@(private = "file")
MARK_UV_CLUT :: 0x3c472000
@(private = "file")
MARK_SIZE :: 0x00080018
@(private = "file")
MARK_BYTES :: 20
@(private = "file")
MARK_Y :: -2
@(private = "file")
MARK_MIN :: [2]int{80, 112} // x, u
@(private = "file")
MARK_MAX :: [2]int{182, 88}
@(private = "file")
CURSOR_AT :: [2]int{3, -2}
@(private = "file")
CURSOR_SIZE :: [2]u32{67, 16}

@(private = "file")
Screen_Row :: struct {
	game:   Game_Row,
	// Index into options, or -1 for a game row.
	option: int,
}

@(private = "file")
screen: struct {
	rows:    [len(LAYOUT)]Screen_Row,
	// The cursor's row and the first row shown.
	row:     int,
	top:     int,
	// Index of text.instant in options.
	instant: int,
	changed: [len(options)]bool,
}

@(private)
options_screen_init :: proc() -> bool {
	#assert(ROW_TOP + VISIBLE * ROW_STEP <= PANEL_H_GAME)
	shown := 0
	for l, i in LAYOUT {
		screen.rows[i] = {l.game, -1}
		if l.key != "" {
			screen.rows[i].option = option_find(l.section, l.key)
			shown += 1
		}
	}
	screen.instant = option_find("text", "instant")
	// Every option of the Options page has a row, but Instant: a choice of
	// the Text row.
	_, count := options_on(.Options)
	assert(shown + 1 == count, "options screen layout misses an option")
	_, ok := setting_hook(OPTIONS_TICK, {.Camp = proc() {setting_overlay = .Camp; options_screen_tick()}, .Title = proc() {setting_overlay = .Title; options_screen_tick()}}, "options")
	return ok
}

// The game's windows are this tall.
@(private = "file")
PANEL_H_GAME :: 144

@(private = "file")
option_find :: proc(section, key: string) -> int {
	for o, i in options {
		if o.page == .Options && o.section == section && o.key == key {
			return i
		}
	}
	panic("options screen: no such option")
}

// The Setting screen opened the Options screen.
@(private)
options_screen_open :: proc() {
	screen.row = 0
	screen.top = 0
}

// The game's Text value with Instant: 0..3.
@(private = "file")
text_value :: proc(byte: u32) -> int {
	return byte == 2 && config.text_instant ? TEXT_INSTANT : int(byte)
}

@(private = "file")
game_value_at :: proc(row: Game_Row) -> u32 {
	return cpu.lw(GAME_VALUES[setting_overlay] + 4 * u32(row))
}

// The Options screen's tick (a0 the menu record), as the game's with the
// port's rows.
@(private = "file")
options_screen_tick :: proc() {
	menu := cpu.state.r[4]
	pressed := cpu.lhu(PAD_PRESSED)
	if pressed & host.PAD_SELECT != 0 {
		if cpu.lbu(SETTING_WIN + OPTIONS_STEP) == 0 {
			cpu.sb(SELECT_STATE, 0)
			game_routine(SHOW_MESSAGE, {SELECT_MESSAGE[setting_overlay], 0, 0, 0, 0})
		}
		return
	}
	repeat := cpu.lhu(PAD_REPEAT)
	confirm := pressed & cpu.lhu(CONFIRM_MASK) != 0
	r := screen.rows[screen.row]
	toggle := confirm && r.option >= 0 && option_toggles(options[r.option])
	switch {
	case repeat & (host.PAD_UP | host.PAD_DOWN) != 0:
		game_routine(SOUND, {SOUND_MOVE, 0, 0, 0, 0})
		screen.row = (screen.row + (repeat & host.PAD_DOWN != 0 ? 1 : -1)) %% len(screen.rows)
		screen.top = clamp(screen.top, screen.row - VISIBLE + 1, screen.row)
	case repeat & (host.PAD_LEFT | host.PAD_RIGHT) != 0 || toggle:
		dir := repeat & host.PAD_LEFT != 0 ? -1 : 1
		if r.option >= 0 {
			port_step(r.option, dir)
		} else {
			game_step(r.game, dir)
		}
	}
	r = screen.rows[screen.row]
	cpu.sb(SETTING_WIN + OPTIONS_ROW, u32(r.game))
	cpu.sh(INFO_TEXT, r.option >= 0 ? INFO_NONE : GAME_INFO[setting_overlay] + u32(r.game))
	game_routine(cpu.lbu(OPTION_SOUND) == 0 ? SOUND_STEREO : SOUND_MONO, {})
	if pressed & cpu.lhu(CANCEL_MASK) != 0 {
		game_routine(SOUND, {SOUND_CANCEL, 0, 0, 0, 0})
		cpu.sb(SETTING_WIN + OPTIONS_OPEN, 0)
		cpu.sb(menu + MENU_STATE, 0)
		cpu.sb(SETTING_WIN + OPTIONS_STEP, 0)
		cpu.sh(COMMAND_WIN + WIN_GREY, 0)
		options_screen_save()
	}
}

@(private = "file")
port_step :: proc(i, dir: int) {
	if !option_step(options[i], dir) {
		game_routine(SOUND, {SOUND_REFUSE, 0, 0, 0, 0})
		return
	}
	game_routine(SOUND, {SOUND_MOVE, 0, 0, 0, 0})
	screen.changed[i] = true
}

// Step a game row as the game does: choices wrap, volumes stop at the ends.
@(private = "file")
game_step :: proc(row: Game_Row, dir: int) {
	at := game_value_at(row)
	v := int(cpu.lbu(at))
	most := int(cpu.lbu(GAME_MOST[setting_overlay] + u32(row)))
	switch {
	case row == .Text:
		t := (text_value(u32(v)) + dir) %% TEXT_CHOICES
		instant := t == TEXT_INSTANT
		if instant != config.text_instant {
			config.text_instant = instant
			screen.changed[screen.instant] = true
		}
		v = min(t, most)
	case row >= VOLUME_FIRST:
		next := clamp(v + dir * VOLUME_STEP, 0, most)
		if next == v {
			return
		}
		v = next
	case:
		v = (v + dir) %% (most + 1)
	}
	game_routine(SOUND, {SOUND_MOVE, 0, 0, 0, 0})
	cpu.sb(at, u32(v))
	if row == .Vib && v != 0 {
		cpu.sb(PAD_STATE + RUMBLE_TIMER, RUMBLE_PULSE)
		cpu.sb(PAD_STATE + RUMBLE_ON, 1)
		cpu.sb(PAD_STATE + RUMBLE_LEVEL, 0)
	}
}

@(private = "file")
options_screen_save :: proc() {
	dirty := false
	for c in screen.changed {
		dirty ||= c
	}
	if dirty && !options_save(screen.changed[:]) {
		host.osd_toast("Settings not saved")
		return
	}
	screen.changed = {}
}

// The right-hand windows (rec SETTING_WIN) showing the Options screen, as
// the game's draw with the port's rows and scrolling.
@(private)
options_screen_draw :: proc(rec: u32) {
	x := int(i16(cpu.lhu(rec + SETTING_X)))
	y := int(i16(cpu.lhu(rec + SETTING_Y)))
	for i in u32(0) ..< 2 {
		w := GAME_WINDOWS[setting_overlay] + 8 * i
		wx := x + int(i16(cpu.lhu(w)))
		wy := y + int(i16(cpu.lhu(w + 2)))
		game_routine(WINDOW_DRAW, {u32(wx), u32(wy), cpu.lhu(w + 4), cpu.lbu(w + 6), 0})
	}
	game_routine(TITLE_DRAW, {u32(x + 4), u32(y - 4), TITLE_TAB, 0, 0})
	open := cpu.lbu(rec + OPTIONS_OPEN)
	for i in screen.top ..< min(screen.top + VISIBLE, len(screen.rows)) {
		r := screen.rows[i]
		ry := y + ROW_TOP + (i - screen.top) * ROW_STEP
		lit := open != 0 && i == screen.row
		if r.option >= 0 {
			port_row_draw(options[r.option], x, ry, lit)
		} else {
			game_row_draw(r.game, x, ry, lit)
		}
		line_draw(x + LABEL_LINE[0], x + LABEL_LINE[1], ry + LINE_BELOW, LINE_STYLE)
	}
	if open == 0 {
		return
	}
	cy := y + ROW_TOP + (screen.row - screen.top) * ROW_STEP
	at := CURSOR_AT
	size := CURSOR_SIZE
	game_routine(CURSOR_DRAW, {u32(x + at.x), u32(cy + at.y), size.x, size.y, open - 1})
	if r := screen.rows[screen.row]; r.option >= 0 {
		info := INFO_AT
		menu_text(info.x, info.y, menu_text_fit(options[r.option].help, INFO_W))
	}
}

@(private = "file")
line_draw :: proc(x0, x1, y: int, style: u32) {
	game_routine(LINE_DRAW, {u32(x0), u32(y), u32(x1), u32(y), style})
}

// The colour of a choice: the value's white (red under the cursor), others
// grey.
@(private = "file")
choice_colour :: proc(chosen, lit: bool) -> u32 {
	if !chosen {
		return MENU_GREY
	}
	return lit ? MENU_RED : MENU_WHITE
}

@(private = "file")
game_text :: proc(x, y: int, id: u32, colour: u32) {
	text := game_routine(MESSAGE_TEXT, {id, 0, 0, 0, 0})
	game_routine(TEXT_DRAW, {u32(x), u32(y), colour, 0xff, text})
}

@(private = "file")
game_row_draw :: proc(row: Game_Row, x, ry: int, lit: bool) {
	game_text(x + LABEL_X, ry, GAME_LABEL[setting_overlay] + u32(row), MENU_WHITE)
	v := cpu.lbu(game_value_at(row))
	if row >= VOLUME_FIRST {
		bar_draw(row, int(v), x, ry)
		return
	}
	label := u32(GAME_CHOICE_LABEL[setting_overlay])
	for r in Game_Row(0) ..< row {
		label += cpu.lbu(GAME_CHOICES[setting_overlay] + u32(r))
	}
	choices := int(cpu.lbu(GAME_CHOICES[setting_overlay] + u32(row)))
	if row == .Text {
		t := text_value(v)
		names, span := TEXT_LABELS, TEXT_SPAN
		room := span[1] - span[0]
		for n in names {
			room -= menu_text_width(n)
		}
		cx := x + span[0]
		for k in 0 ..< TEXT_CHOICES {
			cx = menu_text(cx, ry, names[k], int(choice_colour(t == k, lit)))
			cx += max(room, 0) / (TEXT_CHOICES - 1)
		}
	} else {
		for k in 0 ..< choices {
			cx := int(i16(cpu.lhu(GAME_CHOICE_AT[setting_overlay] + 4 * (3 * u32(row) + u32(k)))))
			game_text(x + cx, ry, label + u32(k), choice_colour(int(v) == k, lit))
		}
	}
	line_draw(x + CHOICE_LINE[0], x + CHOICE_LINE[1], ry + LINE_BELOW, LINE_STYLE)
}

@(private = "file")
port_row_draw :: proc(o: Option, x, ry: int, lit: bool) {
	menu_text(x + LABEL_X, ry, menu_text_fit(o.label, LABEL_W))
	if b, ok := o.value.(^bool); ok {
		tx := TOGGLE_X
		game_text(x + tx[0], ry, GAME_CHOICE_LABEL[setting_overlay] + TOGGLE_OFF, choice_colour(!b^, lit))
		game_text(x + tx[1], ry, GAME_CHOICE_LABEL[setting_overlay] + TOGGLE_ON, choice_colour(b^, lit))
	} else {
		menu_text(x + VALUE_X, ry, option_text(o), int(choice_colour(true, lit)))
	}
	line_draw(x + CHOICE_LINE[0], x + CHOICE_LINE[1], ry + LINE_BELOW, LINE_STYLE)
}

// A volume bar as the game draws it: a textured quad as long as the value,
// a line under it, the Min and Max marks.
@(private = "file")
bar_draw :: proc(row: Game_Row, v, x, ry: int) {
	uv := GAME_BAR_UV[setting_overlay] + 4 * u32(row - VOLUME_FIRST)
	u0, v0, u1, v1 := cpu.lbu(uv), cpu.lbu(uv + 1), cpu.lbu(uv + 2), cpu.lbu(uv + 3)
	n := (v + 1) / 2 * 3 / 2
	x0 := u32(x + BAR_X) & 0xffff
	x1 := u32(x + BAR_X + n) & 0xffff
	top := u32(ry + BAR_TOP) << 16
	bottom := u32(ry + BAR_BOTTOM) << 16
	prim := cpu.lw(SPRITE_PACKETS)
	cpu.sw(prim, BAR_QUAD_TAG)
	cpu.sw(prim + 4, BAR_QUAD)
	cpu.sw(prim + 8, x0 | top)
	cpu.sw(prim + 12, u0 | v0 << 8 | BAR_CLUT << 16)
	cpu.sw(prim + 16, x1 | top)
	cpu.sw(prim + 20, u1 | v0 << 8 | BAR_PAGE << 16)
	cpu.sw(prim + 24, x0 | bottom)
	cpu.sw(prim + 28, u0 | v1 << 8)
	cpu.sw(prim + 32, x1 | bottom)
	cpu.sw(prim + 36, u1 | v1 << 8)
	game_routine(PRIM_COMMIT, {1, BAR_QUAD_BYTES, 0, 0, 0})
	line_draw(x + BAR_LINE[0], x + BAR_LINE[1], ry + BAR_LINE_BELOW, BAR_LINE_STYLE)
	for mark in ([2][2]int{MARK_MAX, MARK_MIN}) {
		prim = cpu.lw(SPRITE_PACKETS)
		cpu.sw(prim, MARK_TAG)
		cpu.sw(prim + 4, MARK_SPRITE)
		cpu.sw(prim + 8, u32(x + mark[0]) & 0xffff | u32(ry + MARK_Y) << 16)
		cpu.sw(prim + 12, MARK_UV_CLUT | u32(mark[1]))
		cpu.sw(prim + 16, MARK_SIZE)
		game_routine(PRIM_COMMIT, {1, MARK_BYTES, 0, 0, 0})
	}
}
