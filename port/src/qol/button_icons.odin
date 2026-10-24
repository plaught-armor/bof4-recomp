// Button prompts that follow the device in use.
//
// The game's text draws a button as `{05}{0a}{15}{N}{06}`: icon N of the
// system font (0 Circle, 1 Cross, 2 Triangle, 3 Square) in colour 10. The
// numbers are fixed in the text, so the prompts are changed where they are
// drawn from: the four 12x12 icon cells in VRAM. Every vblank the cells are
// redrawn for the device last used (psx.input_device):
//
// - the Cross icon shows the Confirm action's button and the Triangle icon
//   the Cancel action's (the text uses them for those), so a custom layout
//   shows its own buttons; Circle and Square stay the physical buttons;
// - PlayStation pads get the game's own symbols, Xbox pads coloured letters,
//   Nintendo pads plain letters, and the keyboard and mouse a keycap with the
//   key bound to that button (or a mouse with the bound part lit).
//
// The cells' original contents are kept and put back whenever they are what
// the device wants. When the game reloads the font the cells stop matching
// what was written, and the reloaded originals are kept again; anything
// there that is not the original icons is left alone.
package qol

import "core:strings"
import "../psx"

// Icon cells: 12x12 4bpp texels of texture page (960, 0), icon N at texel
// (168 + 12*N, 184), so VRAM x 1002 + 3*N.
@(private = "file")
CELL :: 12
@(private = "file")
ICON_COUNT :: 4
@(private = "file")
ICON_VRAM_X :: 1002
@(private = "file")
ICON_VRAM_Y :: 184
@(private = "file")
HALFWORDS :: CELL / 4

@(private = "file")
Cell :: [CELL][CELL]u8

// Colour 10 entries the icons use.
@(private = "file")
BODY :: 1
@(private = "file")
RED :: 5
@(private = "file")
GREEN :: 7
@(private = "file")
BLUE :: 0xb
@(private = "file")
LIGHT :: 0xc
@(private = "file")
DARK :: 0xd
@(private = "file")
YELLOW :: 0xe

// Pad bit each icon stands for in the game's text.
@(private = "file")
ICON_BITS := [ICON_COUNT]u16{psx.PAD_CIRCLE, psx.PAD_CROSS, psx.PAD_TRIANGLE, psx.PAD_SQUARE}

// The game's icons are an 11x11 disc with the symbol on it. Its outline
// (the 0 rows and the first and last two of each row) is the same on all
// four, and is how the originals are recognised.
@(private = "file")
DISC := [CELL]string {
	"004211124000",
	"031111111300",
	"411111111140",
	"311111111130",
	"111111111110",
	"111111111110",
	"111111111110",
	"311111111130",
	"411111111140",
	"031111111300",
	"004211124000",
	"000000000000",
}

// A key: lit top and left edge, dark bottom for depth.
@(private = "file")
KEYCAP := [CELL]string {
	"034444444300",
	"411111111130",
	"411111111130",
	"411111111130",
	"411111111130",
	"411111111130",
	"411111111130",
	"411111111130",
	"3111111111d0",
	"0ddddddddd00",
	"000000000000",
	"000000000000",
}

// A mouse; L, R, W (wheel), P and Q (side buttons X1 and X2) mark the parts
// that light up for a binding and draw as the body otherwise.
@(private = "file")
MOUSE := [CELL]string {
	"000LLcRR0000",
	"00LLLWRRR000",
	"00LLLWRRR000",
	"00LLLcRRR000",
	"00ccccccc000",
	"00Q111111000",
	"00Q111111000",
	"00P111111000",
	"00P111111000",
	"000111110000",
	"000000000000",
	"000000000000",
}

// Symbol characters of the 5x5 font.
@(private)
SYM_UP :: "\x01"
@(private)
SYM_DOWN :: "\x02"
@(private)
SYM_LEFT :: "\x03"
@(private)
SYM_RIGHT :: "\x04"
@(private)
SYM_SPACE :: "\x05"
@(private)
SYM_SHIFT :: "\x06"
@(private)
SYM_TAB :: "\x07"
@(private)
SYM_ENTER :: "\x08"
@(private)
SYM_MENU :: "\x09"
@(private)
SYM_VIEW :: "\x0a"

@(private)
Glyph_5 :: struct {
	c:    u8,
	rows: [5]string,
}

// One character to a cell, centred on it.
@(private)
FONT_5 := [?]Glyph_5 {
	{'A', {".###.", "#...#", "#####", "#...#", "#...#"}},
	{'B', {"####.", "#...#", "####.", "#...#", "####."}},
	{'C', {".####", "#....", "#....", "#....", ".####"}},
	{'D', {"####.", "#...#", "#...#", "#...#", "####."}},
	{'E', {"#####", "#....", "####.", "#....", "#####"}},
	{'F', {"#####", "#....", "####.", "#....", "#...."}},
	{'G', {".####", "#....", "#..##", "#...#", ".####"}},
	{'H', {"#...#", "#...#", "#####", "#...#", "#...#"}},
	{'I', {"#####", "..#..", "..#..", "..#..", "#####"}},
	{'J', {"..###", "...#.", "...#.", "#..#.", ".##.."}},
	{'K', {"#...#", "#..#.", "###..", "#..#.", "#...#"}},
	{'L', {"#....", "#....", "#....", "#....", "#####"}},
	{'M', {"#...#", "##.##", "#.#.#", "#...#", "#...#"}},
	{'N', {"#...#", "##..#", "#.#.#", "#..##", "#...#"}},
	{'O', {".###.", "#...#", "#...#", "#...#", ".###."}},
	{'P', {"####.", "#...#", "####.", "#....", "#...."}},
	{'Q', {".###.", "#...#", "#.#.#", "#..#.", ".##.#"}},
	{'R', {"####.", "#...#", "####.", "#..#.", "#...#"}},
	{'S', {".####", "#....", ".###.", "....#", "####."}},
	{'T', {"#####", "..#..", "..#..", "..#..", "..#.."}},
	{'U', {"#...#", "#...#", "#...#", "#...#", ".###."}},
	{'V', {"#...#", "#...#", "#...#", ".#.#.", "..#.."}},
	{'W', {"#...#", "#...#", "#.#.#", "##.##", "#...#"}},
	{'X', {"#...#", ".#.#.", "..#..", ".#.#.", "#...#"}},
	{'Y', {"#...#", ".#.#.", "..#..", "..#..", "..#.."}},
	{'Z', {"#####", "...#.", "..#..", ".#...", "#####"}},
	{'0', {".###.", "#..##", "#.#.#", "##..#", ".###."}},
	{'1', {"..#..", ".##..", "..#..", "..#..", ".###."}},
	{'2', {"####.", "....#", ".###.", "#....", "#####"}},
	{'3', {"####.", "....#", ".###.", "....#", "####."}},
	{'4', {"#..#.", "#..#.", "#####", "...#.", "...#."}},
	{'5', {"#####", "#....", "####.", "....#", "####."}},
	{'6', {".###.", "#....", "####.", "#...#", ".###."}},
	{'7', {"#####", "....#", "...#.", "..#..", "..#.."}},
	{'8', {".###.", "#...#", ".###.", "#...#", ".###."}},
	{'9', {".###.", "#...#", ".####", "....#", ".###."}},
	{',', {".....", ".....", ".....", "..#..", ".#..."}},
	{'.', {".....", ".....", ".....", ".....", "..#.."}},
	{'/', {"....#", "...#.", "..#..", ".#...", "#...."}},
	{'\\', {"#....", ".#...", "..#..", "...#.", "....#"}},
	{';', {".....", "..#..", ".....", "..#..", ".#..."}},
	{'\'', {"..#..", "..#..", ".....", ".....", "....."}},
	{'`', {".#...", "..#..", ".....", ".....", "....."}},
	{'-', {".....", ".....", "#####", ".....", "....."}},
	{'=', {".....", "#####", ".....", "#####", "....."}},
	{'+', {"..#..", "..#..", "#####", "..#..", "..#.."}},
	{'[', {".###.", ".#...", ".#...", ".#...", ".###."}},
	{']', {".###.", "...#.", "...#.", "...#.", ".###."}},
	{SYM_UP[0], {"..#..", ".###.", "#.#.#", "..#..", "..#.."}},
	{SYM_DOWN[0], {"..#..", "..#..", "#.#.#", ".###.", "..#.."}},
	{SYM_LEFT[0], {"..#..", ".#...", "#####", ".#...", "..#.."}},
	{SYM_RIGHT[0], {"..#..", "...#.", "#####", "...#.", "..#.."}},
	{SYM_SPACE[0], {".....", ".....", "#...#", "#####", "....."}},
	{SYM_SHIFT[0], {"..#..", ".#.#.", "##.##", ".#.#.", ".###."}},
	{SYM_TAB[0], {"..#.#", "...##", "#####", "...##", "..#.#"}},
	{SYM_ENTER[0], {"....#", "....#", ".#..#", "#####", ".#..."}},
	{SYM_MENU[0], {"#####", ".....", "#####", ".....", "#####"}},
	{SYM_VIEW[0], {"###..", "#.###", "###.#", "..#.#", "..###"}},
}

@(private)
Glyph_3 :: struct {
	c:    u8,
	rows: [5]string,
}

// Two characters to a cell.
@(private)
FONT_3 := [?]Glyph_3 {
	{'A', {".#.", "#.#", "###", "#.#", "#.#"}},
	{'B', {"##.", "#.#", "##.", "#.#", "##."}},
	{'C', {".##", "#..", "#..", "#..", ".##"}},
	{'D', {"##.", "#.#", "#.#", "#.#", "##."}},
	{'E', {"###", "#..", "##.", "#..", "###"}},
	{'F', {"###", "#..", "##.", "#..", "#.."}},
	{'G', {".##", "#..", "#.#", "#.#", ".##"}},
	{'H', {"#.#", "#.#", "###", "#.#", "#.#"}},
	{'I', {"###", ".#.", ".#.", ".#.", "###"}},
	{'J', {"..#", "..#", "..#", "#.#", ".#."}},
	{'K', {"#.#", "#.#", "##.", "#.#", "#.#"}},
	{'L', {"#..", "#..", "#..", "#..", "###"}},
	{'M', {"#.#", "###", "###", "#.#", "#.#"}},
	{'N', {"##.", "#.#", "#.#", "#.#", "#.#"}},
	{'O', {".#.", "#.#", "#.#", "#.#", ".#."}},
	{'P', {"##.", "#.#", "##.", "#..", "#.."}},
	{'Q', {".#.", "#.#", "#.#", "##.", ".##"}},
	{'R', {"##.", "#.#", "##.", "#.#", "#.#"}},
	{'S', {".##", "#..", ".#.", "..#", "##."}},
	{'T', {"###", ".#.", ".#.", ".#.", ".#."}},
	{'U', {"#.#", "#.#", "#.#", "#.#", "###"}},
	{'V', {"#.#", "#.#", "#.#", "#.#", ".#."}},
	{'W', {"#.#", "#.#", "###", "###", "#.#"}},
	{'X', {"#.#", "#.#", ".#.", "#.#", "#.#"}},
	{'Y', {"#.#", "#.#", ".#.", ".#.", ".#."}},
	{'Z', {"###", "..#", ".#.", "#..", "###"}},
	{'0', {"###", "#.#", "#.#", "#.#", "###"}},
	{'1', {".#.", "##.", ".#.", ".#.", "###"}},
	{'2', {"##.", "..#", ".#.", "#..", "###"}},
	{'3', {"##.", "..#", ".#.", "..#", "##."}},
	{'4', {"#.#", "#.#", "###", "..#", "..#"}},
	{'5', {"###", "#..", "##.", "..#", "##."}},
	{'6', {".##", "#..", "###", "#.#", "###"}},
	{'7', {"###", "..#", ".#.", ".#.", ".#."}},
	{'8', {"###", "#.#", "###", "#.#", "###"}},
	{'9', {"###", "#.#", "###", "..#", "##."}},
	{'+', {"...", ".#.", "###", ".#.", "..."}},
	{'-', {"...", "...", "###", "...", "..."}},
	{'*', {"...", "#.#", ".#.", "#.#", "..."}},
	{'/', {"..#", "..#", ".#.", "#..", "#.."}},
	{'.', {"...", "...", "...", "...", ".#."}},
	{SYM_UP[0], {".#.", "###", ".#.", ".#.", ".#."}},
	{SYM_DOWN[0], {".#.", ".#.", ".#.", "###", ".#."}},
	{SYM_LEFT[0], {"...", ".#.", "###", ".#.", "..."}},
	{SYM_RIGHT[0], {"...", ".#.", "###", ".#.", "..."}},
}

// How a controller control is drawn: one character in the 5x5 font, or two
// in the small one, in `color` (LIGHT when 0).
@(private = "file")
Glyph :: struct {
	text:  string,
	color: u8,
}

@(private = "file")
PAD_GLYPHS := [psx.Input_Device][psx.Pad_Control]Glyph {
	.Keyboard = {},
	// The face buttons use the game's own icons (PS_FACE_ICON).
	.PlayStation = {
		.A = {}, .B = {}, .X = {}, .Y = {},
		.Back = {"SL", 0}, .Guide = {"PS", 0}, .Start = {"ST", 0},
		.Left_Stick = {"L3", 0}, .Right_Stick = {"R3", 0},
		.Left_Shoulder = {"L1", 0}, .Right_Shoulder = {"R1", 0},
		.Up = {SYM_UP, 0}, .Down = {SYM_DOWN, 0}, .Left = {SYM_LEFT, 0}, .Right = {SYM_RIGHT, 0},
		.Left_Trigger = {"L2", 0}, .Right_Trigger = {"R2", 0},
	},
	.Xbox = {
		.A = {"A", GREEN}, .B = {"B", RED}, .X = {"X", BLUE}, .Y = {"Y", YELLOW},
		.Back = {SYM_VIEW, 0}, .Guide = {"XB", 0}, .Start = {SYM_MENU, 0},
		.Left_Stick = {"LS", 0}, .Right_Stick = {"RS", 0},
		.Left_Shoulder = {"LB", 0}, .Right_Shoulder = {"RB", 0},
		.Up = {SYM_UP, 0}, .Down = {SYM_DOWN, 0}, .Left = {SYM_LEFT, 0}, .Right = {SYM_RIGHT, 0},
		.Left_Trigger = {"LT", 0}, .Right_Trigger = {"RT", 0},
	},
	.Nintendo = {
		.A = {"A", 0}, .B = {"B", 0}, .X = {"X", 0}, .Y = {"Y", 0},
		.Back = {"-", 0}, .Guide = {"HM", 0}, .Start = {"+", 0},
		.Left_Stick = {"LS", 0}, .Right_Stick = {"RS", 0},
		.Left_Shoulder = {"L", 0}, .Right_Shoulder = {"R", 0},
		.Up = {SYM_UP, 0}, .Down = {SYM_DOWN, 0}, .Left = {SYM_LEFT, 0}, .Right = {SYM_RIGHT, 0},
		.Left_Trigger = {"ZL", 0}, .Right_Trigger = {"ZR", 0},
	},
}

// Icon of each PlayStation face button, A to Y (Cross, Circle, Square,
// Triangle).
@(private = "file")
PS_FACE_ICON := [4]int{1, 0, 3, 2}

// What controller controls are called, for menus, in Pad_Control order.
PAD_CONTROL_NAMES := [psx.Input_Device][len(psx.Pad_Control)]string {
	.Keyboard = {},
	.PlayStation = {
		"Cross", "Circle", "Square", "Triangle", "Select", "PS", "Start", "L3", "R3",
		"L1", "R1", "Up", "Down", "Left", "Right", "L2", "R2",
	},
	.Xbox = {
		"A", "B", "X", "Y", "View", "Guide", "Menu", "LS", "RS",
		"LB", "RB", "Up", "Down", "Left", "Right", "LT", "RT",
	},
	.Nintendo = {
		"A", "B", "X", "Y", "Minus", "Home", "Plus", "LS", "RS",
		"L", "R", "Up", "Down", "Left", "Right", "ZL", "ZR",
	},
}

// Console buttons with no controller or key bound draw as on the console.
@(private = "file")
CONSOLE_GLYPHS := [?]struct {
	bit:   u16,
	glyph: Glyph,
} {
	{psx.PAD_L1, {"L1", 0}},
	{psx.PAD_R1, {"R1", 0}},
	{psx.PAD_L2, {"L2", 0}},
	{psx.PAD_R2, {"R2", 0}},
	{psx.PAD_START, {"ST", 0}},
	{psx.PAD_SELECT, {"SL", 0}},
	{psx.PAD_UP, {SYM_UP, 0}},
	{psx.PAD_DOWN, {SYM_DOWN, 0}},
	{psx.PAD_LEFT, {SYM_LEFT, 0}},
	{psx.PAD_RIGHT, {SYM_RIGHT, 0}},
}

// Key names drawn as a symbol or two letters rather than their start.
@(private = "file")
KEY_GLYPHS := [?]struct {
	name: string,
	text: string,
} {
	{"Space", SYM_SPACE},
	{"Left Shift", SYM_SHIFT},
	{"Right Shift", SYM_SHIFT},
	{"Tab", SYM_TAB},
	{"Return", SYM_ENTER},
	{"Keypad Enter", SYM_ENTER},
	{"Up", SYM_UP},
	{"Down", SYM_DOWN},
	{"Left", SYM_LEFT},
	{"Right", SYM_RIGHT},
	{"Escape", "ES"},
	{"Backspace", "BS"},
	{"Left Ctrl", "CT"},
	{"Right Ctrl", "CT"},
	{"Left Alt", "AL"},
	{"Right Alt", "AL"},
	{"Delete", "DL"},
	{"PageUp", "PU"},
	{"PageDown", "PD"},
}

@(private = "file")
icons: struct {
	// The game's cells, and what was last written over them.
	saved:   [ICON_COUNT]Cell,
	written: [ICON_COUNT]Cell,
	// saved holds the game's cells.
	have:    bool,
	// The cells to draw, for the bindings that hashed to sig and the
	// Confirm and Cancel masks in masks; fresh once worked out from saved.
	want:    [ICON_COUNT]Cell,
	sig:     u64,
	masks:   [2]u16,
	fresh:   bool,
}

// Redraw the icon cells for the device in use.
@(private)
button_icons_vblank :: proc() {
	sig := psx.binds_hash()
	tags_vblank(sig)
	world_legend_vblank()
	now: [ICON_COUNT]Cell
	for i in 0 ..< ICON_COUNT {
		now[i] = cell_read(i)
	}
	if !icons.have || now != icons.written {
		for c in now {
			if !is_original(c) {
				icons.have = false
				return
			}
		}
		icons.saved = now
		icons.have = true
		icons.fresh = false
	}
	masks := [2]u16{action_mask(.Confirm), action_mask(.Cancel)}
	if !icons.fresh || sig != icons.sig || masks != icons.masks {
		for i in 0 ..< ICON_COUNT {
			icons.want[i] = icon_for(i)
		}
		icons.sig = sig
		icons.masks = masks
		icons.fresh = true
	}
	want := icons.want
	for i in 0 ..< ICON_COUNT {
		if want[i] != now[i] {
			cell_write(i, want[i])
		}
	}
	icons.written = want
}

// The console button icon `i` shows: the Cross icon is the text's Confirm
// button and the Triangle icon its Cancel button.
@(private = "file")
shown_bit :: proc(i: int) -> u16 {
	mask: u16
	switch i {
	case 1:
		mask = action_mask(.Confirm)
	case 2:
		mask = action_mask(.Cancel)
	}
	if mask == 0 {
		return ICON_BITS[i]
	}
	return mask & (~mask + 1)
}

@(private = "file")
icon_for :: proc(i: int) -> Cell {
	bit := shown_bit(i)
	device := psx.input_device()
	if device == .Keyboard {
		names: [1]string
		if psx.key_sources(bit, names[:]) > 0 {
			return key_icon(names[0])
		}
		return console_icon(bit)
	}
	c, ok := psx.pad_source(bit)
	if !ok {
		return console_icon(bit)
	}
	if device == .PlayStation && c <= .Y {
		return icons.saved[PS_FACE_ICON[int(c)]]
	}
	return disc_with(PAD_GLYPHS[device][c])
}

// A console button as the console labels it.
@(private = "file")
console_icon :: proc(bit: u16) -> Cell {
	for i in 0 ..< ICON_COUNT {
		if ICON_BITS[i] == bit {
			return icons.saved[i]
		}
	}
	for g in CONSOLE_GLYPHS {
		if g.bit == bit {
			return disc_with(g.glyph)
		}
	}
	return disc_with({})
}

@(private = "file")
disc_with :: proc(g: Glyph) -> Cell {
	c := cell_from(DISC)
	draw_text(&c, g.text, g.color == 0 ? LIGHT : g.color, 3)
	return c
}

// A source from the keyboard or mouse (named as by psx.key_sources).
@(private = "file")
key_icon :: proc(name: string) -> Cell {
	if strings.has_prefix(name, "Mouse ") || strings.has_prefix(name, "Wheel ") {
		return mouse_icon(name)
	}
	c := cell_from(KEYCAP)
	text := name
	switch {
	case len(name) == 1:
	case strings.has_prefix(name, "Keypad ") && len(name) == len("Keypad ") + 1:
		text = name[len(name) - 1:]
	case len(name) == 3 && name[0] == 'F' && name[1] == '1':
		// F10 and up by their number.
		text = name[len(name) - 2:]
	case:
		text = name[:2]
		for k in KEY_GLYPHS {
			if strings.equal_fold(k.name, name) {
				text = k.text
				break
			}
		}
	}
	draw_text(&c, strings.to_upper(text, context.temp_allocator), LIGHT, 2)
	return c
}

// The mouse with the bound part lit; a wheel binding also shows which way.
@(private = "file")
mouse_icon :: proc(name: string) -> Cell {
	lit: u8
	switch name {
	case "Mouse Left":
		lit = 'L'
	case "Mouse Right":
		lit = 'R'
	case "Mouse Middle", "Wheel Up", "Wheel Down":
		lit = 'W'
	case "Mouse X1":
		lit = 'P'
	case "Mouse X2":
		lit = 'Q'
	}
	c: Cell
	for row, y in MOUSE {
		for x in 0 ..< CELL {
			ch := row[x]
			switch ch {
			case 'L', 'R', 'W', 'P', 'Q':
				c[y][x] = ch == lit ? YELLOW : BODY
			case '0' ..= '9':
				c[y][x] = ch - '0'
			case 'c':
				c[y][x] = LIGHT
			}
		}
	}
	switch name {
	case "Wheel Up":
		draw_rows(&c, {".#.", "###", ".#.", ".#."}, YELLOW, 4, 5)
	case "Wheel Down":
		draw_rows(&c, {".#.", ".#.", "###", ".#."}, YELLOW, 4, 5)
	}
	return c
}

// Draw `text` centred across the cell from row `y`: one character in the
// 5x5 font, two in the small one. Characters with no glyph stay blank.
@(private = "file")
draw_text :: proc(c: ^Cell, text: string, color: u8, y: int) {
	switch len(text) {
	case 1:
		for g, i in FONT_5 {
			if g.c == text[0] {
				draw_rows(c, FONT_5[i].rows[:], color, 3, y)
				return
			}
		}
	case 2:
		for k in 0 ..< 2 {
			for g, i in FONT_3 {
				if g.c == text[k] {
					draw_rows(c, FONT_3[i].rows[:], color, 2 + 4 * k, y)
					break
				}
			}
		}
	}
}

@(private = "file")
draw_rows :: proc(c: ^Cell, rows: []string, color: u8, x0, y0: int) {
	for row, y in rows {
		for x in 0 ..< len(row) {
			if row[x] == '#' {
				c[y0 + y][x0 + x] = color
			}
		}
	}
}

// A cell from hex digit rows.
@(private = "file")
cell_from :: proc(rows: [CELL]string) -> (c: Cell) {
	for row, y in rows {
		assert(len(row) == CELL, "icon row is not 12 texels")
		for x in 0 ..< CELL {
			ch := row[x]
			c[y][x] = ch <= '9' ? ch - '0' : ch - 'a' + 10
		}
	}
	return c
}

// The game's icons share DISC's outline.
@(private = "file")
is_original :: proc(c: Cell) -> bool {
	disc := cell_from(DISC)
	for y in 0 ..< CELL {
		for x in 0 ..< CELL {
			edge := y == 0 || y >= CELL - 2 || x < 2 || x >= CELL - 3
			if edge && c[y][x] != disc[y][x] {
				return false
			}
		}
	}
	return true
}

@(private = "file")
cell_read :: proc(i: int) -> (c: Cell) {
	for y in 0 ..< CELL {
		for h in 0 ..< HALFWORDS {
			w := psx.vram_at(i32(ICON_VRAM_X + HALFWORDS * i + h), i32(ICON_VRAM_Y + y))^
			for k in 0 ..< 4 {
				c[y][4 * h + k] = u8(w >> (4 * uint(k))) & 0xf
			}
		}
	}
	return c
}

@(private = "file")
cell_write :: proc(i: int, c: Cell) {
	for y in 0 ..< CELL {
		for h in 0 ..< HALFWORDS {
			w: u16
			for k in 0 ..< 4 {
				w |= u16(c[y][4 * h + k]) << (4 * uint(k))
			}
			psx.vram_at(i32(ICON_VRAM_X + HALFWORDS * i + h), i32(ICON_VRAM_Y + y))^ = w
		}
	}
}

// The shoulder button tags beside scrolling lists ("L1" at the top, "R1" at
// the bottom, and L2/R2 in some lists): 8x5 texels of the same page, colour
// TAG_BG with the letters in TAG_FG. They are redrawn like the icons, two
// characters of the small font, and are only touched while they hold either
// the game's tag or what was last written.
@(private = "file")
TAG_W :: 8
@(private = "file")
TAG_H :: 5
@(private = "file")
TAG_COUNT :: 4
@(private = "file")
TAG_BG :: 1
@(private = "file")
TAG_FG :: 5

@(private = "file")
Tag :: [TAG_H][TAG_W]u8

// Texel position of each tag in page (960, 0); x is a multiple of 4.
@(private = "file")
TAG_AT := [TAG_COUNT][2]int{{208, 217}, {216, 217}, {240, 210}, {240, 217}}
@(private = "file")
TAG_BITS := [TAG_COUNT]u16{psx.PAD_L1, psx.PAD_L2, psx.PAD_R1, psx.PAD_R2}
// The game's tags.
@(private = "file")
TAG_ORIGINAL := [TAG_COUNT][TAG_H]string {
	{"51111151", "51111551", "51111151", "51111151", "55551151"},
	{"51111656", "51111515", "51111156", "51111561", "55551555"},
	{"55561151", "51151551", "55561151", "51651151", "51151151"},
	{"55561656", "51151515", "55561156", "51651561", "51151555"},
}
@(private = "file")
TAG_PAGE_X :: 960

@(private = "file")
tags: struct {
	// The game's tags and the ones to draw, for the bindings that hashed
	// to sig (psx.binds_hash); fresh once they have been worked out.
	original: [TAG_COUNT]Tag,
	want:     [TAG_COUNT]Tag,
	sig:      u64,
	fresh:    bool,
	written: [TAG_COUNT]Tag,
	// written[i] has been put in VRAM.
	active:  [TAG_COUNT]bool,
}

@(private = "file")
tags_vblank :: proc(sig: u64) {
	if !tags.fresh || sig != tags.sig {
		for i in 0 ..< TAG_COUNT {
			tags.original[i] = tag_from(TAG_ORIGINAL[i])
			tags.want[i] = tag_for(i, tags.original[i])
		}
		tags.sig = sig
		tags.fresh = true
	}
	for i in 0 ..< TAG_COUNT {
		now := tag_read(i)
		original := tags.original[i]
		if now != original && !(tags.active[i] && now == tags.written[i]) {
			tags.active[i] = false
			continue
		}
		want := tags.want[i]
		if want != now {
			tag_write(i, want)
		}
		tags.written[i] = want
		tags.active[i] = true
	}
}

// The tag for the source bound to button `i`'s bit; the game's tag when it
// has none or the pad is a PlayStation one.
@(private = "file")
tag_for :: proc(i: int, original: Tag) -> Tag {
	bit := TAG_BITS[i]
	text, name: string
	switch device := psx.input_device(); device {
	case .PlayStation:
		return original
	case .Keyboard:
		names: [1]string
		if psx.key_sources(bit, names[:]) == 0 {
			return original
		}
		name = names[0]
		text = tag_key_text(name)
	case .Xbox, .Nintendo:
		c, ok := psx.pad_source(bit)
		if !ok {
			return original
		}
		name = PAD_CONTROL_NAMES[device][c]
		text = PAD_GLYPHS[device][c].text
	}
	if len(text) == 0 || len(text) > 2 || !small_font_has(text) {
		// Symbols with no small glyph go by the name's first letters.
		text = strings.to_upper(name[:min(2, len(name))], context.temp_allocator)
	}
	t: Tag
	for &row in t {
		row = TAG_BG
	}
	x := len(text) == 1 ? 2 : 0
	for k in 0 ..< len(text) {
		for g in FONT_3 {
			if g.c == text[k] {
				for row, y in g.rows {
					for dx in 0 ..< len(row) {
						if row[dx] == '#' {
							t[y][x + 4 * k + dx] = TAG_FG
						}
					}
				}
				break
			}
		}
	}
	return t
}

// A keyboard or mouse source in at most two characters.
@(private)
tag_key_text :: proc(name: string) -> string {
	switch name {
	case "Wheel Up":
		return "W" + SYM_UP
	case "Wheel Down":
		return "W" + SYM_DOWN
	case "Mouse Left":
		return "ML"
	case "Mouse Right":
		return "MR"
	case "Mouse Middle":
		return "MM"
	case "Mouse X1":
		return "M4"
	case "Mouse X2":
		return "M5"
	case "Up":
		return SYM_UP
	case "Down":
		return SYM_DOWN
	case "Left":
		return SYM_LEFT
	case "Right":
		return SYM_RIGHT
	}
	switch {
	case len(name) == 1:
		return strings.to_upper(name, context.temp_allocator)
	case strings.has_prefix(name, "Keypad ") && len(name) == len("Keypad ") + 1:
		return name[len(name) - 1:]
	case len(name) == 3 && name[0] == 'F' && name[1] == '1':
		return name[1:]
	}
	for k in KEY_GLYPHS {
		if strings.equal_fold(k.name, name) && len(k.text) == 2 {
			return k.text
		}
	}
	return strings.to_upper(name[:2], context.temp_allocator)
}

@(private)
small_font_has :: proc(text: string) -> bool {
	outer: for i in 0 ..< len(text) {
		for g in FONT_3 {
			if g.c == text[i] {
				continue outer
			}
		}
		return false
	}
	return true
}

@(private = "file")
tag_from :: proc(rows: [TAG_H]string) -> (t: Tag) {
	for row, y in rows {
		for x in 0 ..< TAG_W {
			t[y][x] = row[x] - '0'
		}
	}
	return t
}

@(private = "file")
tag_read :: proc(i: int) -> (t: Tag) {
	for y in 0 ..< TAG_H {
		for h in 0 ..< TAG_W / 4 {
			w := psx.vram_at(i32(TAG_PAGE_X + TAG_AT[i].x / 4 + h), i32(TAG_AT[i].y + y))^
			for k in 0 ..< 4 {
				t[y][4 * h + k] = u8(w >> (4 * uint(k))) & 0xf
			}
		}
	}
	return t
}

@(private = "file")
tag_write :: proc(i: int, t: Tag) {
	for y in 0 ..< TAG_H {
		for h in 0 ..< TAG_W / 4 {
			w: u16
			for k in 0 ..< 4 {
				w |= u16(t[y][4 * h + k]) << (4 * uint(k))
			}
			psx.vram_at(i32(TAG_PAGE_X + TAG_AT[i].x / 4 + h), i32(TAG_AT[i].y + y))^ = w
		}
	}
}
