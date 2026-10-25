// The camp menu's Setting screen with a fifth command, Extras: the port's own
// options (options.odin), changed in game. The game's Screen command (a CRT
// picture shift) opens the port's Display page instead, and its Options
// screen is the port's (options_screen.odin), the game's rows among the
// port's.
//
// The Setting screen lists Options, Buttons, Screen and Reset in its Command
// window, with its two right-hand windows (the Setting tab) showing the
// game's options. Its tick and its Command window draw are hand-ported with
// the fifth row; with the cursor on Extras the right-hand windows show the
// option pages instead, and confirming opens them in place: the page list
// on the left, the page's options on the right, the option's help in the
// Info window. Up/Down choose, Confirm or Right enters a page, Left/Right
// change a value (Confirm flips a toggle), Cancel backs out. Leaving the
// pages writes what changed to the config file. Screen opens the Display
// page the same way, alone in one window with no page list.
//
// The title screen's Option menu is the same screen in the title's overlay
// (GAME.EMI's second part, in the camp menu's slot): the same code at other
// addresses and message ids. Its Command window draw takes the window from
// WIN_CURRENT and steps the window open and shut inline, its tick has no
// draws gate, and Cancel goes back to the title's menu. Every hook is set in
// both overlays and notes which one called it (setting_overlay).
package qol

import "core:fmt"

import "ps:psx"

// The game's Options (save block bytes): Text 0 Slow, 1 Norm, 2 Fast; Dash
// 1 Auto; Camera 1 Reverse.
@(private)
OPTION_TEXT_SPEED :: 0x8011ad74
@(private)
OPTION_DASH_AUTO :: 0x8011ad79
@(private)
OPTION_CAMERA_REVERSE :: 0x8011ad7c

@(private)
Setting_Overlay :: enum u8 {
	Camp,
	Title,
}
@(private)
TITLE_ID :: 0x16
@(private)
SETTING_IDS := [Setting_Overlay]u32 {
	.Camp  = CAMP_ID,
	.Title = TITLE_ID,
}
// The overlay of the hook running now.
@(private)
setting_overlay: Setting_Overlay

// a0 the menu record.
@(private = "file")
SETTING_TICK := [Setting_Overlay]u32{.Camp = 0x801b6a18, .Title = 0x801acd50}
// a0 the Command window record (the title's: none, the window in
// WIN_CURRENT).
@(private = "file")
SETTING_COMMAND_DRAW := [Setting_Overlay]u32{.Camp = 0x801abd8c, .Title = 0x801b1de4}
// a0 SETTING_WIN: the two right-hand windows and the Setting tab (the
// title's: none, SETTING_WIN in WIN_CURRENT).
@(private = "file")
SETTING_WINDOWS_DRAW := [Setting_Overlay]u32{.Camp = 0x801aeec0, .Title = 0x801b20ac}
@(private)
WIN_CURRENT :: 0x8011de24
// The title screen's mode (s16) and its step: Cancel sets the title's menu.
@(private = "file")
TITLE_MODE :: 0x801148d8
@(private = "file")
TITLE_MODE_STEP :: 0x801148da
@(private = "file")
TITLE_MODE_MENU :: 3
// Record of the right-hand windows: s16 x at +8, y at +0xa. The tick slides
// x in from the right.
@(private)
SETTING_WIN :: 0x8011dd1c
@(private)
SETTING_X :: 8
@(private)
SETTING_Y :: 0xa
@(private = "file")
SLIDE_FROM :: 0x61
@(private = "file")
SLIDE_STEP :: 0x50
// In the Command window record: the row under the cursor (u8), the screen a
// row opened (s8, 0xff: one replacing this one), nonzero greys every row but
// the cursor's (s16).
@(private = "file")
WIN_ROW :: 0xd
@(private = "file")
WIN_SCREEN :: 0xe
@(private)
WIN_GREY :: 0x10
// In the menu record: the menu's state (u8, 5 = the main menu), its step.
@(private)
MENU_STATE :: 2
@(private = "file")
MENU_STEP :: 3
@(private = "file")
MENU_SUB :: 6
@(private = "file")
STATE_MAIN :: 5
// In SETTING_WIN: the Options screen is open (u8), its step (u8).
@(private)
OPTIONS_OPEN :: 3
@(private)
OPTIONS_STEP :: 0xf

@(private = "file")
Setting_Row :: enum u8 {
	Options,
	Buttons,
	Screen,
	Reset,
	Extras,
}
@(private = "file")
GAME_LABEL := [Setting_Overlay]u32{.Camp = 0x8039, .Title = 0x8090} // + row: the game's labels
@(private = "file")
GAME_INFO := [Setting_Overlay]u32{.Camp = 0x8053, .Title = 0x80ab} // + row: the game's Info messages
@(private = "file")
SELECT_MESSAGE := [Setting_Overlay]u32{.Camp = 0x909c, .Title = 0x90b9}
// a0 0, a1 the u8 at BUTTONS_ARG + 1: as the game calls it each tick while
// the cursor is on Buttons.
@(private = "file")
BUTTONS_PREVIEW :: 0x80141400
@(private = "file")
BUTTONS_ARG :: 0x8011ad78
// The camp's: a0 the window, a1 0: steps the Command window open; and shut.
@(private = "file")
COMMAND_OPEN_STEP :: 0x801ac208
@(private = "file")
COMMAND_SHUT_STEP :: 0x801ac1c4
// The title's open step: the window's width grows by OPEN_STEP_W from
// OPEN_FIRST_W (OPEN_SOUND in OPEN_SOUND_AT) until FRAME_OPEN_W. Shut: a
// window that opened a replacing screen hands its state on (WIN_NEXT) and
// takes WIN_REPLACED.
@(private = "file")
OPEN_FIRST_W :: 8
@(private = "file")
OPEN_STEP_W :: 16
@(private = "file")
OPEN_SOUND_AT :: 0x8011dc99
@(private = "file")
OPEN_SOUND :: 0x11
@(private = "file")
WIN_STATE :: 2
@(private = "file")
WIN_NEXT :: 0xf
@(private = "file")
WIN_REPLACED :: 12

// The Command window, one row taller than the game's (0x48) for Extras.
@(private = "file")
FRAME :: [4]u32{0x10, 0x3c, 0, 0x58}
@(private = "file")
FRAME_OPEN_W :: 0x48
@(private = "file")
ROW_X :: 22
@(private = "file")
ROW_Y :: 66
@(private = "file")
ROW_STEP :: 16
@(private = "file")
CURSOR_W :: 0x44
@(private = "file")
CURSOR_H :: 0x10
@(private = "file")
TITLE_AT :: [2]int{16, 56}
@(private = "file")
TITLE_SETTING :: 0x200 // the Command window's "Setting" tab
@(private)
TITLE_TAB :: 0x16 // the right-hand windows' "Setting" tab
@(private = "file")
EXTRAS_LABEL :: "Extras"
@(private = "file")
EXTRAS_INFO :: "Options of this port"
@(private = "file")
SCREEN_INFO :: "Window, scale and frame rate"
@(private = "file")
RESTART_INFO :: "Restart to apply."

// The option pages: page list and options windows, as wide as the game's.
@(private = "file")
PAGES_W :: 72
@(private = "file")
OPTIONS_W :: 136
@(private = "file")
PANEL_H :: 152
@(private = "file")
LIST_TOP :: 6
@(private = "file")
LIST_X :: 6
@(private = "file")
VALUE_GAP :: 6 // least room between an option's label and its value
@(private)
INFO_W :: 280
@(private = "file")
CURSOR_STYLE_IDLE :: 1 // the cursor of a list not in use

@(private = "file")
setting: struct {
	// The option pages are open; options focused rather than pages.
	open:         bool,
	on_options:   bool,
	// Screen's Display page is open, alone.
	single:       bool,
	// The Extras page, kept while Display is open alone.
	page:         Options_Page,
	row:          int,
	changed:      [len(options)]bool,
}

@(private)
setting_menu_init :: proc() -> bool {
	#assert(EXTRAS_COUNT * MENU_LINE_H + LIST_TOP <= PANEL_H)
	#assert(OPTIONS_PAGE_MAX * MENU_LINE_H + LIST_TOP <= PANEL_H)
	options_init()
	for page in Options_Page(0) ..= EXTRAS_LAST {
		options_on(page)
	}
	options_on(.Display)
	ok: bool
	if _, ok = setting_hook(SETTING_TICK, {.Camp = proc() {setting_overlay = .Camp; setting_tick()}, .Title = proc() {setting_overlay = .Title; setting_tick()}}, "setting"); !ok {
		return false
	}
	if _, ok = setting_hook(SETTING_COMMAND_DRAW, {.Camp = proc() {setting_overlay = .Camp; command_draw()}, .Title = proc() {setting_overlay = .Title; command_draw()}}, "setting"); !ok {
		return false
	}
	if _, ok = setting_hook(SETTING_WINDOWS_DRAW, {.Camp = proc() {setting_overlay = .Camp; windows_draw()}, .Title = proc() {setting_overlay = .Title; windows_draw()}}, "setting"); !ok {
		return false
	}
	return options_screen_init() && controls_init()
}

// Hook a function in both overlays (fns note the overlay, then run the
// port's), returning the game's.
@(private)
setting_hook :: proc(addrs: [Setting_Overlay]u32, fns: [Setting_Overlay]psx.Func_Proc, what: string) -> (originals: [Setting_Overlay]psx.Func_Proc, ok: bool) {
	for o in Setting_Overlay {
		if originals[o], ok = psx.hook_overlay(addrs[o], SLOT_MENU, SETTING_IDS[o], fns[o]); !ok {
			fmt.eprintf("qol: %s function %08x not found\n", what, addrs[o])
			return
		}
	}
	return
}

// The window a draw is for: a0 in the camp, WIN_CURRENT in the title.
@(private)
setting_draw_record :: proc() -> u32 {
	return setting_overlay == .Title ? psx.lw(WIN_CURRENT) : psx.cpu.r[4]
}

// The Setting screen's tick (a0 the menu record), as the game's with the
// Extras row.
@(private = "file")
setting_tick :: proc() {
	menu := psx.cpu.r[4]
	if x := i16(psx.lhu(SETTING_WIN + SETTING_X)); x >= SLIDE_FROM {
		psx.sh(SETTING_WIN + SETTING_X, u32(x - SLIDE_STEP))
	}
	if setting_overlay == .Camp && psx.lhu(COMMAND_WIN + WIN_DRAWS) == 0 {
		return
	}
	if setting.open {
		pages_tick()
		return
	}
	if psx.lhu(PAD_PRESSED) & psx.PAD_SELECT != 0 {
		psx.sb(SELECT_STATE, 0)
		game_routine(SHOW_MESSAGE, {SELECT_MESSAGE[setting_overlay], 0, 0, 0, 0})
		return
	}
	repeat := psx.lhu(PAD_REPEAT)
	row := int(psx.lbu(COMMAND_WIN + WIN_ROW))
	if repeat & (psx.PAD_UP | psx.PAD_DOWN) != 0 {
		game_routine(SOUND, {SOUND_MOVE, 0, 0, 0, 0})
		row = (row + (repeat & psx.PAD_DOWN != 0 ? 1 : -1)) %% len(Setting_Row)
		psx.sb(COMMAND_WIN + WIN_ROW, u32(row))
	}
	ours := Setting_Row(row) == .Extras || Setting_Row(row) == .Screen
	psx.sh(INFO_TEXT, ours ? INFO_NONE : GAME_INFO[setting_overlay] + u32(row))
	if Setting_Row(row) == .Buttons {
		game_routine(BUTTONS_PREVIEW, {0, psx.lbu(BUTTONS_ARG) + 1, 0, 0, 0})
	}
	pressed := psx.lhu(PAD_PRESSED)
	if pressed & psx.lhu(CONFIRM_MASK) != 0 {
		row_confirm(menu, Setting_Row(row))
	} else if pressed & psx.lhu(CANCEL_MASK) != 0 && setting_overlay == .Title {
		game_routine(SOUND, {SOUND_CANCEL, 0, 0, 0, 0})
		psx.sh(TITLE_MODE, TITLE_MODE_MENU)
		psx.sh(TITLE_MODE_STEP, 0)
	} else if pressed & psx.lhu(CANCEL_MASK) != 0 {
		game_routine(SOUND, {SOUND_CANCEL, 0, 0, 0, 0})
		psx.sh(INFO_TEXT, INFO_NONE)
		psx.sb(menu + MENU_STEP, 0)
		psx.sb(menu + MENU_SUB, 0)
		psx.sb(menu + MENU_STATE, STATE_MAIN)
	}
}

@(private = "file")
row_confirm :: proc(menu: u32, row: Setting_Row) {
	game_routine(SOUND, {SOUND_CONFIRM, 0, 0, 0, 0})
	#partial switch row {
	case .Extras:
		pages_open(false)
		return
	case .Screen:
		pages_open(true)
		return
	}
	psx.sb(menu + MENU_STEP, 0)
	psx.sb(menu + MENU_STATE, u32(row) + 1)
	#partial switch row {
	case .Options:
		psx.sh(COMMAND_WIN + WIN_GREY, 1)
		psx.sb(SETTING_WIN + OPTIONS_OPEN, 1)
		psx.sb(SETTING_WIN + OPTIONS_STEP, 0)
		options_screen_open()
	case .Reset:
		psx.sh(COMMAND_WIN + WIN_GREY, 1)
	case:
		psx.sb(COMMAND_WIN + WIN_SCREEN, 0xff)
		psx.sh(INFO_TEXT, INFO_NONE)
	}
}

@(private = "file")
pages_open :: proc(single: bool) {
	setting.open = true
	setting.single = single
	setting.on_options = single
	setting.row = 0
	psx.sh(COMMAND_WIN + WIN_GREY, 1)
	// F11 may have changed it since start.
	config.window.fullscreen = psx.window_options().fullscreen
}

@(private = "file")
pages_close :: proc() {
	setting.open = false
	psx.sh(COMMAND_WIN + WIN_GREY, 0)
	game_routine(SOUND, {SOUND_CANCEL, 0, 0, 0, 0})
	dirty := false
	for c in setting.changed {
		dirty ||= c
	}
	if dirty && !options_save(setting.changed[:]) {
		psx.osd_toast("Settings not saved")
		return
	}
	setting.changed = {}
}

@(private = "file")
pages_tick :: proc() {
	pressed := psx.lhu(PAD_PRESSED)
	repeat := psx.lhu(PAD_REPEAT)
	confirm := pressed & psx.lhu(CONFIRM_MASK) != 0
	cancel := pressed & psx.lhu(CANCEL_MASK) != 0
	if setting.on_options {
		options_tick(repeat, confirm, cancel)
		return
	}
	switch {
	case cancel:
		pages_close()
	case confirm || repeat & psx.PAD_RIGHT != 0:
		game_routine(SOUND, {SOUND_CONFIRM, 0, 0, 0, 0})
		setting.on_options = true
		setting.row = 0
	case repeat & (psx.PAD_UP | psx.PAD_DOWN) != 0:
		game_routine(SOUND, {SOUND_MOVE, 0, 0, 0, 0})
		step := repeat & psx.PAD_DOWN != 0 ? 1 : -1
		setting.page = Options_Page((int(setting.page) + step) %% EXTRAS_COUNT)
	}
}

@(private = "file")
options_tick :: proc(repeat: u32, confirm, cancel: bool) {
	first, count := options_on(setting.single ? .Display : setting.page)
	i := first + setting.row
	switch {
	case cancel && setting.single:
		pages_close()
	case cancel:
		game_routine(SOUND, {SOUND_CANCEL, 0, 0, 0, 0})
		setting.on_options = false
	case repeat & (psx.PAD_UP | psx.PAD_DOWN) != 0:
		game_routine(SOUND, {SOUND_MOVE, 0, 0, 0, 0})
		setting.row = (setting.row + (repeat & psx.PAD_DOWN != 0 ? 1 : -1)) %% count
	case repeat & (psx.PAD_LEFT | psx.PAD_RIGHT) != 0 || confirm && option_toggles(options[i]):
		if option_step(options[i], repeat & psx.PAD_LEFT != 0 ? -1 : 1) {
			game_routine(SOUND, {SOUND_MOVE, 0, 0, 0, 0})
			setting.changed[i] = true
		} else {
			game_routine(SOUND, {SOUND_REFUSE, 0, 0, 0, 0})
		}
	}
}

// The Setting screen's Command window (a0 its record), as the game's with
// the Extras row.
@(private = "file")
command_draw :: proc() {
	win := setting_draw_record()
	frame := FRAME
	if w := psx.lbu(win + WIN_WIDTH); w >= 0x10 {
		game_routine(WINDOW_DRAW, {frame.x, frame.y, w, frame.w, 0})
	}
	command_open_step(win)
	if psx.lbu(win + WIN_OPEN) == 0 {
		return
	}
	camp_shut := setting_overlay == .Camp && psx.lbu(COMMAND_SCREEN) == 0
	if camp_shut || i8(psx.lbu(win + WIN_SCREEN)) != 0 {
		// Shutting: narrow, then the game's shut step.
		if w := psx.lbu(win + WIN_WIDTH); w != 0 {
			psx.sb(win + WIN_WIDTH, w == FRAME_OPEN_W ? w - 8 : w - 16)
		}
		command_shut_step(win)
		return
	}
	cursor := Setting_Row(psx.lbu(win + WIN_ROW))
	grey := psx.lhu(win + WIN_GREY) != 0
	for row in Setting_Row {
		colour: u32 = grey && row != cursor ? MENU_GREY : MENU_WHITE
		y := ROW_Y + int(row) * ROW_STEP
		if row == .Extras {
			menu_text(ROW_X, y, EXTRAS_LABEL, int(colour))
			continue
		}
		label := game_routine(MESSAGE_TEXT, {GAME_LABEL[setting_overlay] + u32(row), 0, 0, 0, 0})
		game_routine(TEXT_DRAW, {ROW_X, u32(y), colour, 0xff, label})
	}
	cy := ROW_Y + int(cursor) * ROW_STEP - 2
	game_routine(CURSOR_DRAW, {ROW_X - 4, u32(cy), CURSOR_W, CURSOR_H, psx.lbu(win + WIN_GREY)})
	title := TITLE_AT
	game_routine(TITLE_DRAW, {u32(title.x), u32(title.y), TITLE_SETTING, 0, 0})
	if draws := psx.lhu(win + WIN_DRAWS); setting_overlay == .Camp && draws != 2 {
		psx.sh(win + WIN_DRAWS, draws + 1)
	}
}

@(private = "file")
command_open_step :: proc(win: u32) {
	if setting_overlay == .Camp {
		game_routine(COMMAND_OPEN_STEP, {win, 0, 0, 0, 0})
		return
	}
	if psx.lbu(win + WIN_OPEN) != 0 {
		return
	}
	switch w := psx.lbu(win + WIN_WIDTH); w {
	case 0:
		psx.sb(OPEN_SOUND_AT, OPEN_SOUND)
		psx.sb(win + WIN_WIDTH, OPEN_FIRST_W)
	case FRAME_OPEN_W:
		psx.sb(win + WIN_OPEN, 1)
	case:
		psx.sb(win + WIN_WIDTH, w + OPEN_STEP_W)
	}
}

// Once the window has narrowed to nothing.
@(private = "file")
command_shut_step :: proc(win: u32) {
	if setting_overlay == .Camp {
		game_routine(COMMAND_SHUT_STEP, {win, 0, 0, 0, 0})
		return
	}
	if psx.lbu(win + WIN_WIDTH) != 0 {
		return
	}
	if i8(psx.lbu(win + WIN_SCREEN)) == -1 {
		psx.sb(win + WIN_NEXT, psx.lbu(win + WIN_STATE))
		psx.sb(win + WIN_STATE, WIN_REPLACED)
	}
	psx.sb(win + WIN_OPEN, 0)
	psx.sh(win + WIN_DRAWS, 0)
}

// The right-hand windows (a0 SETTING_WIN): the option pages while Extras or
// Screen is open or under the cursor, else the Options screen.
@(private = "file")
windows_draw :: proc() {
	rec := setting_draw_record()
	row := Setting_Row(psx.lbu(COMMAND_WIN + WIN_ROW))
	if !setting.open && row != .Extras && row != .Screen {
		options_screen_draw(rec)
		return
	}
	single := setting.open ? setting.single : row == .Screen
	page := single ? Options_Page.Display : setting.page
	x := int(i16(psx.lhu(rec + SETTING_X)))
	y := int(i16(psx.lhu(rec + SETTING_Y)))
	ox, ow := x + PAGES_W - 1, OPTIONS_W
	if single {
		ox, ow = x, PAGES_W - 1 + OPTIONS_W
		menu_window(ox, y, ow, PANEL_H)
	} else {
		menu_window(x, y, PAGES_W, PANEL_H)
		menu_window(ox, y, ow, PANEL_H)
	}
	game_routine(TITLE_DRAW, {u32(x + 4), u32(y - 4), TITLE_TAB, 0, 0})
	if !single {
		for p in Options_Page(0) ..= EXTRAS_LAST {
			grey := setting.open && setting.on_options && p != page
			menu_text(x + LIST_X, row_y(y, int(p)), OPTIONS_PAGE_NAMES[p], grey ? MENU_GREY : MENU_WHITE)
		}
	}
	options_draw(page, ox, ow, y)
	info := INFO_AT
	if !setting.open || !setting.on_options {
		menu_text(info.x, info.y, single ? SCREEN_INFO : EXTRAS_INFO)
	}
	if !setting.open {
		return
	}
	if !single {
		style: u32 = setting.on_options ? CURSOR_STYLE_IDLE : 0
		game_routine(CURSOR_DRAW, {u32(x + 4), u32(row_y(y, int(page)) - 2), PAGES_W - 8, CURSOR_H, style})
	}
	if setting.on_options {
		first, _ := options_on(page)
		o := options[first + setting.row]
		help := o.restart != nil && o.restart() ? RESTART_INFO : o.help
		menu_text(info.x, info.y, menu_text_fit(help, INFO_W))
		game_routine(CURSOR_DRAW, {u32(ox + 4), u32(row_y(y, setting.row) - 2), u32(ow - 8), CURSOR_H, 0})
	}
}

// The page's options in a window w wide at x: label left, value right
// (yellow while it waits for a restart).
@(private = "file")
options_draw :: proc(page: Options_Page, x, w, y: int) {
	first, count := options_on(page)
	for i in 0 ..< count {
		o := options[first + i]
		ry := row_y(y, i)
		value := option_text(o)
		room := w - 2 * LIST_X - VALUE_GAP - menu_text_width(value)
		menu_text(x + LIST_X, ry, menu_text_fit(o.label, room))
		pending := o.restart != nil && o.restart()
		menu_text_right(x + w - LIST_X, ry, value, pending ? MENU_YELLOW : MENU_WHITE)
	}
}

@(private = "file")
row_y :: proc(top, row: int) -> int {
	return top + LIST_TOP + row * MENU_LINE_H
}
