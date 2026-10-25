// Quest tracker: the field's Menu button pops up a box naming the current
// objective (Start opens the camp menu, so the button is otherwise unused).
//
// Story progress lives in the game's event flags, bit arrays in the saved
// game region. Map events are native code in the per-map overlays that set
// and test bits through three resident routines (set 0x801917d4, clear
// 0x801917fc, test 0x80191828, each taking the array and a bit index), so
// the tracker reads the same bits. Each area (story chapter) has a 32-bit
// progress word whose bits the story sets roughly in order; OBJECTIVES lists
// beats as the bit that marks them done. The objective shown is the one after
// the last beat done, so a beat whose bit is never set does not hold the
// tracker back. Past the table's end the box says no objective is noted.
//
// BOF4_FLAGLOG=1 prints every change to the flag region as it happens, with
// the map and the last message shown, so new story beats can be added to the
// table from a play session or a replay.
package qol

import "core:fmt"
import "core:os"
import "core:strings"

import cpu "ps:psx/cpu"
import host "ps:psx/host"

// The region holding the event flag arrays, the per-area flag words and the
// global flags (save offsets 0xdf4..0x10cc).
@(private = "file")
FLAGS_LO :: 0x8011b5c0
@(private = "file")
FLAGS_HI :: 0x8011b898
// Resume position inside it (area, section, map, tile x, z), not flags.
@(private = "file")
POSITION_LO :: 0x8011b7c0
@(private = "file")
POSITION_HI :: 0x8011b7c8
// Party membership bits.
@(private = "file")
PARTY_LO :: 0x8011ad84
@(private = "file")
PARTY_HI :: 0x8011ad8c
// The string pointer in the TEXT_BOX box, and the most bytes read from it.
@(private = "file")
MESSAGE_TEXT :: 12
@(private = "file")
MESSAGE_MAX :: 72

// Per-area progress words, u32 at AREA_WORDS + area * 4.
@(private = "file")
AREA_WORDS :: 0x8011b7d0

@(private = "file")
Objective :: struct {
	area, bit: u32, // the bit set once the beat is done
	text:      string,
}

// Story order. Found with BOF4_FLAGLOG and the map overlays' flag calls.
@(private = "file")
OBJECTIVES :: [?]Objective {
	{2, 1, "Head for the cliffs on the way to Sarai."},
	{2, 3, "Jump the gaps along the cliff road."},
	{2, 4, "Keep climbing while there is light."},
	{2, 5, "Find a place to camp for the night."},
	{2, 6, "Fou-Lu: Leave the tomb."},
	{2, 10, "Fou-Lu: Head for the capital."},
	{2, 11, "Fou-Lu: Escape the burning woods."},
	{4, 0, "Climb the cliffs to the town of Sarai."}, // set by the arrival talk
	{4, 12, "Ask around Sarai for sandflier parts. Try the tavern."},
	{4, 18, "Get a shovel and dog in Sandflier Valley, south of town."},
	{4, 19, "Dig for the part in Sandflier Valley."},
}

// The pop-up box: game window frame, menu font, near the screen's bottom
// where the game's dialogue sits.
@(private = "file")
BOX_X :: 16
@(private = "file")
BOX_W :: 288
@(private = "file")
BOX_BOTTOM :: 224
@(private = "file")
BOX_PAD :: 12
@(private = "file")
BOX_LINES :: 4
@(private = "file")
OBJ_STATE :: 0x4 // u8
@(private = "file")
STATE_PLAYER_CONTROL :: 1

@(private = "file")
tracker: struct {
	shown:   bool, // the objective box is up
	swallow: bool, // hide buttons from the game until all are released
	last:    u16, // the buttons held at the previous poll
}

@(private = "file")
flag_log: struct {
	on:      bool,
	primed:  bool,
	flags:   [FLAGS_HI - FLAGS_LO]u8,
	party:   [PARTY_HI - PARTY_LO]u8,
	message: [MESSAGE_MAX]u8,
	msg_len: int,
}

@(private)
tracker_init :: proc() -> bool {
	flag_log.on = os.get_env("BOF4_FLAGLOG", context.temp_allocator) != ""
	return true
}

@(private)
tracker_vblank :: proc() {
	if flag_log.on {
		flag_log_vblank()
	}
}

// host.pad_hook's part, for the field's Menu button (Start opens the camp
// menu instead). A press while the player has control opens the objective
// box; while it is up the game sees no buttons, and Confirm, Cancel or Menu
// closes it. The game sees nothing more until every button is released, so
// the closing press does not reach it too. Returns the buttons for the game.
@(private)
tracker_buttons :: proc(held, menu: u16) -> u16 {
	down := held &~ tracker.last
	tracker.last = held
	if tracker.swallow {
		tracker.swallow = held != 0
		return 0
	}
	in_field := cpu.lhu(GAME_MODE) == GAME_MODE_FIELD
	if tracker.shown {
		closing := menu | action_mask(.Confirm) | action_mask(.Cancel)
		if !in_field || down & closing != 0 {
			tracker.shown = false
			tracker.swallow = true
		}
		return 0
	}
	if !in_field {
		return held
	}
	if down & menu != 0 && cpu.lbu(leader_obj() + OBJ_STATE) == STATE_PLAYER_CONTROL {
		tracker.shown = true
	}
	return held &~ menu
}

@(private)
tracker_draws :: proc() -> bool {
	return tracker.shown && cpu.lhu(GAME_MODE) == GAME_MODE_FIELD
}

// The objective box, word-wrapped to the box's width.
@(private)
tracker_draw :: proc() {
	text := objective_now()
	if text == "" {
		text = "No objective noted here yet."
	}
	lines: [BOX_LINES]string
	n := text_wrap(text, BOX_W - 2 * BOX_PAD, lines[:])
	h := 2 * BOX_PAD + n * MENU_LINE_H
	y := BOX_BOTTOM - h
	menu_window(BOX_X, y, BOX_W, h)
	for line, i in lines[:n] {
		menu_text(BOX_X + BOX_PAD, y + BOX_PAD + i * MENU_LINE_H, line)
	}
}

// The objective after the last beat done; "" past the table.
@(private = "file")
objective_now :: proc() -> string {
	objectives := OBJECTIVES
	next := objective_next()
	return next < len(objectives) ? objectives[next].text : ""
}

// Index in OBJECTIVES of the beat after the last one done; the beats before
// it count as done. len(OBJECTIVES) past the table.
@(private = "file")
objective_next :: proc() -> (next: int) {
	for o, i in OBJECTIVES {
		if cpu.lw(AREA_WORDS + o.area * 4) & (1 << o.bit) != 0 {
			next = i + 1
		}
	}
	return
}

// Split text into lines fitting w pixels, breaking at spaces; returns the
// lines filled.
@(private)
text_wrap :: proc(text: string, w: int, lines: []string) -> (n: int) {
	rest := text
	for rest != "" && n < len(lines) {
		line := menu_text_fit(rest, w)
		if len(line) < len(rest) {
			if cut := strings.last_index_byte(line, ' '); cut > 0 {
				line = line[:cut]
			}
		}
		lines[n] = line
		n += 1
		rest = strings.trim_left(rest[len(line):], " ")
	}
	return
}

// The journal: the panel's PANEL_JOURNAL page (camp menu Journal, or F2).
// The current objective, then the beats done, newest first, scrolled a line
// at a time with Up and Down.
@(private = "file")
JOURNAL_PAD :: 12
@(private = "file")
JOURNAL_TEXT_W :: PANEL.z - 2 * JOURNAL_PAD - 8 // done beats are indented 8
@(private = "file")
JOURNAL_ROWS :: (PANEL.w - 2 * JOURNAL_PAD) / MENU_LINE_H - 1 // the last row is the footer
@(private = "file")
JOURNAL_LINES :: 4 * len(OBJECTIVES) + 10

@(private = "file")
Journal_Line :: struct {
	text:   string,
	colour: int,
	indent: int,
}

@(private = "file")
journal: struct {
	top: int, // first line shown
}

@(private)
journal_draws :: proc() -> bool {
	return host.osd_panel_shown && host.osd_panel_page == PANEL_JOURNAL
}

// Up and Down scroll the journal a line.
@(private)
journal_select :: proc(pressed: u16) {
	if !journal_draws() {
		return
	}
	if pressed & host.PAD_UP != 0 {
		journal.top = max(journal.top - 1, 0)
	}
	if pressed & host.PAD_DOWN != 0 {
		journal.top += 1 // journal_draw clamps it to the last screenful
	}
}

@(private)
journal_draw :: proc() {
	lines: [JOURNAL_LINES]Journal_Line
	n := 0
	add := proc(lines: []Journal_Line, n: ^int, text: string, colour, indent: int) {
		wrapped: [4]string
		for line in wrapped[:text_wrap(text, JOURNAL_TEXT_W, wrapped[:])] {
			if n^ < len(lines) {
				lines[n^] = {line, colour, indent}
				n^ += 1
			}
		}
	}
	objectives := OBJECTIVES
	next := objective_next()
	add(lines[:], &n, "Now", MENU_YELLOW, 0)
	if next < len(objectives) {
		add(lines[:], &n, objectives[next].text, MENU_WHITE, 8)
	} else {
		add(lines[:], &n, "No objective noted here yet.", MENU_GREY, 8)
	}
	if config.field_teacher {
		n += 1
		add(lines[:], &n, "Combo dog", MENU_YELLOW, 0)
		add(lines[:], &n, teacher_journal(), MENU_WHITE, 8)
	}
	if next > 0 {
		n += 1 // a blank line between the parts
		add(lines[:], &n, "Done", MENU_YELLOW, 0)
		for i := next - 1; i >= 0; i -= 1 {
			add(lines[:], &n, objectives[i].text, MENU_WHITE, 8)
		}
	}
	journal.top = clamp(journal.top, 0, max(n - JOURNAL_ROWS, 0))
	menu_window(PANEL.x, PANEL.y, PANEL.z, PANEL.w)
	x := PANEL.x + JOURNAL_PAD
	y := PANEL.y + JOURNAL_PAD
	for line, row in lines[journal.top:min(n, journal.top + JOURNAL_ROWS)] {
		menu_text(x + line.indent, y + row * MENU_LINE_H, line.text, line.colour)
	}
	menu_text(x, y + JOURNAL_ROWS * MENU_LINE_H, "Up/Down  Left/Right: Combos", MENU_GREY)
}

@(private = "file")
flag_log_vblank :: proc() {
	message_follow()
	first := !flag_log.primed
	flag_log.primed = true
	for &old, i in flag_log.flags {
		at := u32(FLAGS_LO + i)
		if at >= POSITION_LO && at < POSITION_HI {
			continue
		}
		flag_log_byte(at, &old, first)
	}
	for &old, i in flag_log.party {
		flag_log_byte(u32(PARTY_LO + i), &old, first)
	}
}

@(private = "file")
flag_log_byte :: proc(at: u32, old: ^u8, first: bool) {
	now := u8(cpu.lbu(at))
	if now == old^ {
		return
	}
	if !first {
		fmt.printfln(
			"flag %d map %04x.%d area %d %08x %02x->%02x \"%s\"",
			cpu.vblanks(),
			cpu.lhu(FIELD_MAP),
			cpu.lbu(MAP_SECTION),
			cpu.lbu(POSITION_LO),
			at,
			old^,
			now,
			string(flag_log.message[:flag_log.msg_len]),
		)
	}
	old^ = now
}

// Keep the start of the latest message shown, printable characters only.
@(private = "file")
message_follow :: proc() {
	box := cpu.lw(TEXT_BOX)
	if box < 0x80000000 || box >= 0x80200000 {
		return
	}
	src := cpu.lw(box + MESSAGE_TEXT)
	if src < 0x80000000 || src >= 0x80200000 {
		return
	}
	buf: [MESSAGE_MAX]u8
	n := 0
	for i in u32(0) ..< 400 {
		ch := u8(cpu.lbu(src + i))
		if ch == 0 || n == MESSAGE_MAX {
			break
		}
		if ch == 1 && n > 0 && buf[n - 1] != ' ' {
			buf[n] = ' '
			n += 1
		} else if ch >= 0x20 && ch < 0x7f && ch != '"' {
			buf[n] = ch
			n += 1
		}
	}
	if n > 4 {
		flag_log.message = buf
		flag_log.msg_len = n
	}
}
