// Camp menu Journal and Masters commands, and Start as the camp menu button.
//
// On field maps Start shows the game's PAUSE, which a PC port has no use for,
// while the camp menu sits on Square. While the field overlay is resident
// (battles load theirs in its place), Start reaches the game as Square, so
// Start opens the camp menu as on most modern consoles' games. Elsewhere
// (title, battles) Start is unchanged.
//
// The camp menu (SYSTEM/SGAMEN.EMI, overlay 0x11 at 0x801aa000) lists seven
// commands in its Command window: Item, Special, Equip, Status, Change,
// Setting and Save. The port adds Masters (with the masters tracker on),
// which shows the panel's masters page (masters.odin), and Journal, which
// shows its journal page (tracker.odin). Functions replaced by hand ports:
//
//   CAMP_TICK     the main menu's tick: cursor, confirm, cancel, the
//                 party's front/back swap and Select's message
//   COMMAND_DRAW  the Command window, once open: labels, icons, cursor
//   TIME_DRAW     the Time and Zenny windows under it, lower by the rows
//   ZENNY_DRAW    past eight (the game's own run with eight)
//
// The window's rows are 14 pixels apart instead of 16, and once open it is
// WIDEN pixels wider, into the margin before the party, to fit "Masters". The
// game's commands behave as before and keep their rows, so the cursor is
// also the game's command number for them. The added rows have no Info
// message of their own, so the port writes their line in the Info window.
package qol

import "core:fmt"

import "ps:psx"

@(private)
CAMP_ID :: 0x11
@(private = "file")
CAMP_TICK :: 0x801aa28c
@(private = "file")
COMMAND_DRAW :: 0x801ab57c
@(private = "file")
TIME_DRAW :: 0x801ac448
@(private = "file")
ZENNY_DRAW :: 0x801ac668

// Menu state.
@(private = "file")
MENU_LOCK :: 0x8011db9c // u8, nonzero: the tick reads no buttons
@(private)
// u8, nonzero while a command's screen is up: the Command window animates
// shut and the screen's own windows show.
COMMAND_SCREEN :: 0x8011a902
@(private = "file")
MENU_DRAWN :: 0x8011dc99 // u8, set by each draw of the Command window
@(private)
INFO_TEXT :: 0x8011dc9c // u16 message id in the Info window
@(private = "file")
INFO_COMMAND :: 0x800b // + command: the command's Info message
@(private)
INFO_NONE :: 0xffff
@(private)
SELECT_STATE :: 0x8011ded0 // u8, cleared before Select's message
@(private = "file")
SELECT_MESSAGE :: 0x9093
// Cleared when a command opens its screen: a byte, then six 5 apart.
@(private = "file")
SCREEN_STATE :: 0x801e8898
@(private = "file")
SCREEN_SLOTS :: 0x801e88a8
@(private = "file")
SCREEN_SLOT_COUNT :: 6
@(private = "file")
SCREEN_SLOT_STRIDE :: 5

// The menu record the tick gets: +0 page, +6 a command screen opens, +8 u16
// the command chosen.
@(private = "file")
PAGE_LEAVE :: 6

// Window records, 0x18 bytes: +4 u8 open, +6 u8 width (grows to WIN_OPEN_W
// as it opens), +0xc.. per window. The party window's +0xc is the front/back
// swap, +0xd swap allowed, +0xe and +0xf its state, +0x10 u16 a view toggled
// by Circle. The Command window's +0xc is the cursor (s8), +0xd and +0xe the
// chosen screen's state, +0x12 u16 counts draws to 2.
@(private = "file")
PARTY_WIN :: 0x8011dcd4
@(private)
COMMAND_WIN :: 0x8011dcec
@(private)
WIN_OPEN :: 4
@(private)
WIN_WIDTH :: 6
@(private = "file")
WIN_OPEN_W :: 0x4c
@(private = "file")
WIN_CURSOR :: 0xc
@(private)
WIN_DRAWS :: 0x12
@(private = "file")
PARTY_FOURTH :: PARTY_SLOTS + 3 // u8 record index, 0xff = no fourth member

// Pad words the menu reads, and the buttons it confirms and cancels with.
@(private)
PAD_PRESSED :: 0x80116d3a // u16 newly pressed
@(private)
PAD_REPEAT :: 0x80116d3e // u16 newly pressed or repeating
@(private)
CONFIRM_MASK :: 0x80116d84 // u16
@(private)
CANCEL_MASK :: 0x80116d86 // u16

// Game routines.
@(private)
SOUND :: 0x8013ea54 // a0 sound id
@(private)
SHOW_MESSAGE :: 0x8014c090 // a0 message id
@(private = "file")
MENU_FADE :: 0x8018f880 // a0 2 on leaving the menu
@(private = "file")
TICK_END :: 0x80150018
@(private)
TITLE_DRAW :: 0x801521c4 // a0 x, a1 y, a2 0x100: the "Command" tab
@(private)
CURSOR_DRAW :: 0x80151f54 // a0 x, a1 y, a2 width, a3 height, [sp+16] 0
@(private = "file")
SIDE_WINDOW_DRAW :: 0x801510e8 // a0 x, a1 y, a2 width, a3 0: Time's or Zenny's frame
@(private = "file")
SIDE_TITLE_DRAW :: 0x801521c4 // a0 x, a1 y, a2 tab (9 Time, 10 Zenny), a3 1
@(private = "file")
NUMBER_DRAW :: 0x80141104 // a0 x, a1 y, a2 width, a3 format, [sp+16] value
@(private = "file")
ZENNY_MARK_DRAW :: 0x801e7610 // a0 x, a1 y, a2 0x3c00, a3 5

@(private)
SOUND_MOVE :: 0x200
@(private)
SOUND_CONFIRM :: 0x201
@(private)
SOUND_CANCEL :: 0x204
@(private)
SOUND_REFUSE :: 0x205

@(private = "file")
Command :: enum i8 {
	Item,
	Special,
	Equip,
	Status,
	Change,
	Setting,
	Save,
	Masters,
	Journal,
}

// Command window layout: the frame, the first label, the row step, the tab.
@(private = "file")
FRAME :: [4]u32{0x10, 0x2c, WIN_OPEN_W, 0x7a}
@(private = "file")
WIDEN :: 8
@(private = "file")
CURSOR_W :: 0x47 + WIDEN
@(private = "file")
CURSOR_H :: 0x10
@(private = "file")
ROW_X :: 38
@(private = "file")
ROW_Y :: 50
@(private = "file")
ROW_STEP :: 14
@(private = "file")
TITLE_AT :: [2]int{16, 40}
@(private = "file")
LABEL_FIRST :: 0x8003 // message id of Item's label; Save's is 0x8009
@(private = "file")
LABEL_SAVE_OFF :: 0x8009 // Save's label where the party cannot save
@(private = "file")
MASTERS_LABEL :: "Masters"
@(private = "file")
MASTERS_INFO :: "Masters' progress and rewards"
@(private = "file")
JOURNAL_LABEL :: "Journal"
@(private = "file")
JOURNAL_INFO :: "The story so far, and what next"
@(private)
INFO_AT :: [2]int{22, 26}

// 12x12 command icons: a textured rectangle from the menu sheet, u from
// ICON_U + 12 * icon. The sheet is 4-bit, in texture page 13 (VRAM x 832),
// with its CLUT at (144, 241).
@(private = "file")
ICON_PRIM_TAG :: 0x04000000
@(private = "file")
ICON_PRIM_RECT :: 0x64808080
@(private = "file")
ICON_PRIM_CLUT :: 0x3c490000
@(private = "file")
ICON_PRIM_SIZE :: 0x000c000c
@(private = "file")
ICON_PRIM_BYTES :: 0x14
@(private = "file")
ICON_U :: 0x30
@(private = "file")
ICON_SIZE :: 12
@(private = "file")
ICON_V :: 0x80
@(private = "file")
SHEET_X :: 832 // texture page 13
// The added commands have their own icons in the sheet's palette and style,
// written into its unused texels: Masters a gold medal on a ribbon after the
// last number icon (u 0xcc-0xd7, v 0x80), Journal a book at the sheet's
// bottom right (u 0xe8-0xf3, v 0xf0). Should the game ever put something
// there, the command falls back to a game icon instead of overwriting it.
@(private = "file")
Added_Icon :: struct {
	u, v:     int,
	fallback: Command,
	pixels:   [ICON_SIZE]string,
}
@(private = "file")
MASTERS_ICON :: Added_Icon{0xcc, ICON_V, .Status, MASTERS_ICON_PIXELS}
@(private = "file")
JOURNAL_ICON :: Added_Icon{0xe8, 0xf0, .Item, JOURNAL_ICON_PIXELS}
@(private = "file")
MASTERS_ICON_PIXELS :: [ICON_SIZE]string {
	"ebb111199772",
	"eebb11997712",
	"e11bb9977112",
	"1113333711e2",
	"113cec4311e2",
	"13ceccc431e2",
	"13ecccc43112",
	"73cccc4a3112",
	"53ccc44a3172",
	"77344aa31772",
	"11e333317772",
	"222222222222",
}
@(private = "file")
JOURNAL_ICON_PIXELS :: [ICON_SIZE]string {
	"113333333311",
	"13aaaaaaa3e1",
	"13a44444a3e1",
	"13a4ccc4a3e1",
	"13a44444a3e1",
	"13aaaaaaa3e1",
	"13aaaaaaa3e1",
	"13aaaaaaa3e1",
	"13aaaaaaa3e1",
	"13aaaaaaa3e1",
	"1133333333e1",
	"222222222222",
}

@(private = "file")
camp: struct {
	tick:         psx.Func_Proc,
	command_draw: psx.Func_Proc,
	time_draw:    psx.Func_Proc,
	zenny_draw:   psx.Func_Proc,
}

@(private)
camp_menu_init :: proc() -> bool {
	psx.pad_hook = start_as_square
	ok: bool
	if camp.tick, ok = psx.hook_overlay(CAMP_TICK, SLOT_MENU, CAMP_ID, camp_tick); !ok {
		fmt.eprintf("qol: camp menu function %08x not found\n", CAMP_TICK)
		return false
	}
	if camp.command_draw, ok = psx.hook_overlay(COMMAND_DRAW, SLOT_MENU, CAMP_ID, command_draw); !ok {
		fmt.eprintf("qol: camp menu function %08x not found\n", COMMAND_DRAW)
		return false
	}
	if camp.time_draw, ok = psx.hook_overlay(TIME_DRAW, SLOT_MENU, CAMP_ID, time_draw); !ok {
		fmt.eprintf("qol: camp menu function %08x not found\n", TIME_DRAW)
		return false
	}
	if camp.zenny_draw, ok = psx.hook_overlay(ZENNY_DRAW, SLOT_MENU, CAMP_ID, zenny_draw); !ok {
		fmt.eprintf("qol: camp menu function %08x not found\n", ZENNY_DRAW)
		return false
	}
	return true
}

// The main menu's tick (a0 the menu record), as the game's with the added
// rows.
@(private = "file")
camp_tick :: proc() {
	ko_loss_camp()
	menu := psx.cpu.r[4]
	psx.sh(menu + 8, 0)
	if psx.lbu(MENU_LOCK) == 0 {
		if psx.lhu(PAD_PRESSED) & psx.PAD_SELECT != 0 {
			psx.sb(SELECT_STATE, 0)
			game_routine(SHOW_MESSAGE, {SELECT_MESSAGE, 0, 0, 0, 0})
		} else if psx.lbu(COMMAND_WIN + WIN_WIDTH) == WIN_OPEN_W {
			party_swap()
			command_tick(menu)
		}
	}
	game_routine(TICK_END, {})
}

// With four or more members, Left or Right swaps the front and back rows.
@(private = "file")
party_swap :: proc() {
	if psx.lbu(PARTY_FOURTH) == 0xff {
		return
	}
	psx.sb(PARTY_WIN + 0xd, 1)
	if psx.lhu(PAD_PRESSED) & (psx.PAD_LEFT | psx.PAD_RIGHT) != 0 {
		game_routine(SOUND, {SOUND_MOVE, 0, 0, 0, 0})
		psx.sb(PARTY_WIN + 0xf, 0)
		psx.sb(PARTY_WIN + 0xe, 0)
		psx.sb(PARTY_WIN + 0xc, psx.lbu(PARTY_WIN + 0xc) ~ 1)
	}
}

@(private = "file")
command_tick :: proc(menu: u32) {
	repeat := psx.lhu(PAD_REPEAT)
	if repeat != 0 {
		game_routine(SOUND, {SOUND_MOVE, 0, 0, 0, 0})
	}
	cursor := i32(i8(psx.lbu(COMMAND_WIN + WIN_CURSOR)))
	if repeat & psx.PAD_DOWN != 0 {
		cursor += 1
	} else if repeat & psx.PAD_UP != 0 {
		cursor -= 1
	}
	rows, n := command_rows()
	cursor %%= i32(n)
	psx.sb(COMMAND_WIN + WIN_CURSOR, u32(cursor))
	command := rows[cursor]
	psx.sh(INFO_TEXT, command > .Save ? INFO_NONE : INFO_COMMAND + u32(command))
	pressed := psx.lhu(PAD_PRESSED)
	switch {
	case pressed & psx.lhu(CONFIRM_MASK) != 0:
		command_confirm(menu, command)
	case pressed & psx.lhu(CANCEL_MASK) != 0:
		game_routine(SOUND, {SOUND_CANCEL, 0, 0, 0, 0})
		psx.sb(menu, PAGE_LEAVE)
		game_routine(MENU_FADE, {2, 0, 0, 0, 0})
	case pressed & psx.PAD_CIRCLE != 0:
		game_routine(SOUND, {SOUND_MOVE, 0, 0, 0, 0})
		psx.sh(PARTY_WIN + 0x10, psx.lhu(PARTY_WIN + 0x10) ~ 1)
	}
}

// Open the command's screen; Save only where the party may save.
@(private = "file")
command_confirm :: proc(menu: u32, command: Command) {
	if command > .Save {
		game_routine(SOUND, {SOUND_CONFIRM, 0, 0, 0, 0})
		panel_open(command == .Masters ? PANEL_MASTERS : PANEL_JOURNAL)
		return
	}
	if command == .Save && !save_allowed() {
		game_routine(SOUND, {SOUND_REFUSE, 0, 0, 0, 0})
		return
	}
	psx.sb(SCREEN_STATE, 0)
	for i in 0 ..< u32(SCREEN_SLOT_COUNT) {
		psx.sb(SCREEN_SLOTS + i * SCREEN_SLOT_STRIDE, 0)
	}
	game_routine(SOUND, {SOUND_CONFIRM, 0, 0, 0, 0})
	psx.sb(menu, psx.lbu(menu) + 1)
	if command != .Save {
		psx.sb(menu + 6, 1)
	}
	psx.sh(menu + 8, u32(command))
	psx.sh(INFO_TEXT, INFO_NONE)
	psx.sb(COMMAND_WIN + 0xd, 0)
	if command == .Status {
		psx.sb(COMMAND_WIN + 0xe, 0xff)
	}
	if command == .Change {
		psx.sb(PARTY_WIN + 0xf, 1)
	}
}

// Save anywhere (save.odin) recognises the game's own calls by their return
// address, which this port's calls do not have, so it is applied here.
@(private = "file")
save_allowed :: proc() -> bool {
	return config.save_anywhere || game_routine(AREA_KIND, {psx.lhu(FIELD_MAP), 0, 0, 0, 0}) & 0xff == 1
}

// The Command window (a0 its record). Opening and closing run as the game's.
@(private = "file")
command_draw :: proc() {
	win := psx.cpu.r[4]
	if psx.lbu(win + WIN_OPEN) == 0 || psx.lbu(COMMAND_SCREEN) != 0 {
		camp.command_draw()
		return
	}
	rows, n := command_rows()
	frame := FRAME
	game_routine(WINDOW_DRAW, {frame.x, frame.y, frame.z + WIDEN, frame.w + u32(rows_added_dy()), 0})
	psx.sb(MENU_DRAWN, 1)
	save := save_allowed()
	for command, row in rows[:n] {
		x, y := row_at(row)
		switch {
		case command == .Masters:
			menu_text(x, y, MASTERS_LABEL)
		case command == .Journal:
			menu_text(x, y, JOURNAL_LABEL)
		case command == .Save && !save:
			label := game_routine(MESSAGE_TEXT, {LABEL_SAVE_OFF, 0, 0, 0, 0})
			game_routine(TEXT_DRAW, {u32(x), u32(y), MENU_GREY, 0xff, label})
		case:
			label := game_routine(MESSAGE_TEXT, {LABEL_FIRST + u32(command), 0, 0, 0, 0})
			game_routine(TEXT_DRAW, {u32(x), u32(y), MENU_WHITE, 0xff, label})
		}
	}
	title := TITLE_AT
	game_routine(TITLE_DRAW, {u32(title.x), u32(title.y), 0x100, 0, 0})
	for command, row in rows[:n] {
		command_icon(command, row)
	}
	cursor := clamp(int(i8(psx.lbu(win + WIN_CURSOR))), 0, n - 1)
	info := INFO_AT
	#partial switch rows[cursor] {
	case .Masters:
		menu_text(info.x, info.y, MASTERS_INFO)
	case .Journal:
		menu_text(info.x, info.y, JOURNAL_INFO)
	}
	x, y := row_at(cursor)
	game_routine(CURSOR_DRAW, {u32(x - 20), u32(y - 2), CURSOR_W, CURSOR_H, 0})
	if draws := psx.lhu(win + WIN_DRAWS); draws != 2 {
		psx.sh(win + WIN_DRAWS, draws + 1)
	}
}

// The commands listed, in order: the game's seven keep their rows, the
// added ones follow.
@(private = "file")
command_rows :: proc() -> (rows: [len(Command)]Command, n: int) {
	for command in Command {
		if command == .Masters && !config.masters_tracker {
			continue
		}
		rows[n] = command
		n += 1
	}
	return
}

// How much lower than the game's the rows past its eighth push what sits
// under the Command window.
@(private = "file")
rows_added_dy :: proc() -> int {
	_, n := command_rows()
	return (n - 8) * ROW_STEP
}

@(private = "file")
row_at :: proc(row: int) -> (x, y: int) {
	return ROW_X, ROW_Y + row * ROW_STEP
}

// The command's icon left of its label, on `row`.
@(private = "file")
command_icon :: proc(command: Command, row: int) {
	x, y := row_at(row)
	u, v := ICON_U + ICON_SIZE * int(command), ICON_V
	if command > .Save {
		icon := command == .Masters ? MASTERS_ICON : JOURNAL_ICON
		u, v = icon.u, icon.v
		if !icon_place(icon) {
			u, v = ICON_U + ICON_SIZE * int(icon.fallback), ICON_V
		}
	}
	prim := psx.lw(SPRITE_PACKETS)
	psx.sw(prim, ICON_PRIM_TAG)
	psx.sw(prim + 4, ICON_PRIM_RECT)
	psx.sw(prim + 8, u32(x - 15) & 0xffff | u32(y) << 16)
	psx.sw(prim + 12, ICON_PRIM_CLUT | u32(v) << 8 | u32(u))
	psx.sw(prim + 16, ICON_PRIM_SIZE)
	game_routine(PRIM_COMMIT, {1, ICON_PRIM_BYTES, 0, 0, 0})
}

// Put an added command's icon in the sheet, each draw (sheet uploads would
// erase it). Returns false, leaving VRAM alone, when the spot holds anything
// other than blank texels or the icon itself.
@(private = "file")
icon_place :: proc(icon: Added_Icon) -> bool {
	pixels := icon.pixels
	return texels_place(SHEET_X, icon.u, icon.v, pixels[:])
}

// The Time and Zenny windows, as the game's but rows_added_dy lower. They
// share a record (pointer at SIDE_RECORD): +3 nonzero once shut, +6 u8 the
// width, following the Command window's as it opens and shrinking as a
// command screen takes over, +0xe the Time colon shown, +0xf the frames to
// its next blink.
@(private = "file")
SIDE_RECORD :: 0x8011de24
@(private = "file")
TIME_Y :: 169
@(private = "file")
ZENNY_Y :: 192
// Formats of NUMBER_DRAW, in the overlay.
@(private = "file")
HOURS_FORMAT :: 0x801aa1dc
@(private = "file")
MINUTES_FORMAT :: 0x801aa1e0
@(private = "file")
ZENNY_FORMAT :: 0x801aa1e8
// The blinking colon between hours and minutes: a sprite from the sheet.
@(private = "file")
COLON_AT :: [2]int{58, 174}
@(private = "file")
COLON_PRIM_UV :: 0x3c00b87c
@(private = "file")
COLON_PRIM_SIZE :: 0x000c0003

@(private = "file")
time_draw :: proc() {
	dy := rows_added_dy()
	if dy == 0 {
		camp.time_draw()
		return
	}
	if !side_window(TIME_Y + dy) {
		return
	}
	rec := psx.lw(SIDE_RECORD)
	blink := (psx.lbu(rec + 0xf) - 1) & 0xff
	psx.sb(rec + 0xf, blink)
	if blink == 0 {
		psx.sb(rec + 0xe, psx.lbu(rec + 0xe) ~ 1)
		psx.sb(rec + 0xf, 15)
	}
	game_routine(SIDE_TITLE_DRAW, {20, u32(166 + dy), 9, 1, 0})
	game_routine(NUMBER_DRAW, {22, u32(174 + dy), 64, HOURS_FORMAT, psx.lw(PLAY_HOURS)})
	game_routine(NUMBER_DRAW, {62, u32(174 + dy), 64, MINUTES_FORMAT, psx.lbu(PLAY_MINUTES)})
	if psx.lbu(rec + 0xe) != 0 {
		colon := COLON_AT
		prim := psx.lw(SPRITE_PACKETS)
		psx.sw(prim, ICON_PRIM_TAG)
		psx.sw(prim + 4, ICON_PRIM_RECT)
		psx.sw(prim + 8, u32(colon.x) | u32(colon.y + dy) << 16)
		psx.sw(prim + 12, COLON_PRIM_UV)
		psx.sw(prim + 16, COLON_PRIM_SIZE)
		game_routine(PRIM_COMMIT, {1, ICON_PRIM_BYTES, 0, 0, 0})
	}
}

@(private = "file")
zenny_draw :: proc() {
	dy := rows_added_dy()
	if dy == 0 {
		camp.zenny_draw()
		return
	}
	if !side_window(ZENNY_Y + dy) {
		return
	}
	game_routine(SIDE_TITLE_DRAW, {20, u32(189 + dy), 10, 1, 0})
	game_routine(NUMBER_DRAW, {20, u32(197 + dy), 48, ZENNY_FORMAT, psx.lw(ZENNY)})
	game_routine(ZENNY_MARK_DRAW, {76, u32(197 + dy), 0x3c00, 5, 0})
}

// The part Time and Zenny share: the frame at y, opening with the Command
// window and shrinking shut. Returns whether it is open to draw in.
@(private = "file")
side_window :: proc(y: int) -> bool {
	rec := psx.lw(SIDE_RECORD)
	screen := psx.lbu(COMMAND_SCREEN) != 0
	if psx.lbu(rec + 3) != 0 {
		if !screen && psx.lbu(COMMAND_WIN + WIN_WIDTH) == 0 {
			psx.sb(rec + 3, 0)
		}
		return false
	}
	if !screen {
		psx.sb(rec + 6, psx.lbu(COMMAND_WIN + WIN_WIDTH))
	}
	w := psx.lbu(rec + 6)
	if w >= 16 {
		game_routine(SIDE_WINDOW_DRAW, {16, u32(y), w, 0, 0})
	}
	if screen {
		switch w {
		case WIN_OPEN_W:
			psx.sb(rec + 6, w - 12)
		case 0:
			psx.sb(rec + 3, psx.lbu(rec + 3) + 1)
		case:
			psx.sb(rec + 6, w - 16)
		}
		return false
	}
	return w == WIN_OPEN_W
}

// psx.pad_hook: on the field, Select toggles the minimap, Start is the camp
// menu button (the Menu action's, Square in the game's layouts), and the Menu
// button itself shows the quest objective.
@(private = "file")
start_as_square :: proc(held: u16) -> u16 {
	if psx.lw(SLOT_ENGINE) != FLD_MAIN_ID {
		return combo_menu_buttons(held)
	}
	menu := action_mask(.Menu)
	held := held
	if menu & psx.PAD_START == 0 {
		held = tracker_buttons(held, menu)
		if held & psx.PAD_START != 0 {
			held = held &~ psx.PAD_START | menu
		}
	}
	return minimap_buttons(held)
}
