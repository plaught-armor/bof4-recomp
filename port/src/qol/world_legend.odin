// World map button legends that follow the device in use.
//
// The world map's legends ("△ ··Camp", "SELECT ··Map", "L1/R1 ··Search" and
// so on) are sprites from one texture: 8bpp texture page 0x8a (VRAM x 640,
// y 0) with the CLUT at (0, 248). Each legend's button part is a slot of that
// page. Every vblank the slots are redrawn for the device last used, in the
// legend's own style: the button's name in light (or, on a greyed legend,
// dim) letters with a dark outline. PlayStation pads keep the game's symbols.
//
// The "□ ··Menu" legend shows the port's menu button, Start (see
// camp_menu.odin), on every device.
//
// A slot is drawn over only while it holds the game's legend (recognised by
// a hash of its texels) or what was last written there, so the page's other
// uses are left alone.
package qol

import "core:strings"
import "../psx"

@(private = "file")
LEGEND_PAGE_X :: 640

// CLUT entries of the legends.
@(private = "file")
LEGEND_BG :: 24
@(private = "file")
LEGEND_OUTLINE :: 14
@(private = "file")
LEGEND_LIT :: 8
@(private = "file")
LEGEND_DIM :: 12

@(private = "file")
SLOT_MAX_W :: 22
@(private = "file")
SLOT_MAX_H :: 11

@(private = "file")
Slot_Pixels :: [SLOT_MAX_H][SLOT_MAX_W]u8

// What a slot shows.
@(private = "file")
Slot_Button :: enum u8 {
	Triangle,
	Circle,
	Square,
	Select,
	Confirm, // the Confirm action's button
	Menu, // the port's menu button, Start
	Shoulders, // L1 and R1
}

@(private = "file")
Slot :: struct {
	u, v, w, h: int,
	button:     Slot_Button,
	dim:        bool,
	// FNV-1a of the game's texels, row by row.
	hash:       u32,
}

@(private = "file")
SLOTS := [?]Slot {
	// The node legend, dim and lit rows.
	{0, 102, 22, 10, .Triangle, true, 0x8b1f278c}, // Camp
	{0, 118, 22, 10, .Triangle, false, 0x3a9a9353},
	{0, 131, 22, 11, .Confirm, true, 0xa1ccc226}, // Enter
	{0, 147, 22, 11, .Confirm, false, 0x7c99b76c},
	// The panel under it.
	{64, 128, 22, 8, .Select, false, 0xb30c1691}, // Map
	{64, 136, 22, 9, .Menu, false, 0x8c74b4c0}, // Menu
	// The map view.
	{8, 171, 22, 9, .Triangle, false, 0xe0ec4e0b}, // Cursor
	{8, 180, 22, 10, .Select, false, 0xf107de51}, // Back
	{8, 192, 22, 8, .Square, true, 0xb5e29e15}, // List
	{8, 200, 22, 8, .Select, false, 0xb30c1691}, // Back
	// The two place list panels.
	{120, 206, 21, 8, .Shoulders, false, 0xa9735803}, // Search
	{120, 214, 21, 9, .Triangle, false, 0x23d19de5}, // Speed+
	{120, 223, 21, 9, .Square, false, 0x11d903cd}, // List
	{120, 232, 21, 8, .Select, false, 0x123654b1}, // Back
	{192, 206, 21, 8, .Shoulders, false, 0xa9735803},
	{192, 214, 21, 9, .Circle, false, 0x36d81b72},
	{192, 223, 21, 9, .Square, false, 0x11d903cd},
	{192, 232, 21, 8, .Select, false, 0x123654b1},
}

@(private = "file")
legend: struct {
	// The game's texels, and what was last written over them.
	saved:   [len(SLOTS)]Slot_Pixels,
	written: [len(SLOTS)]Slot_Pixels,
	// What each slot held last vblank, and whether that was the game's
	// legend (its hash matched): unchanged texels need no hashing again.
	seen:    [len(SLOTS)]Slot_Pixels,
	game:    [len(SLOTS)]bool,
	// written[i] has been put in VRAM.
	active:  [len(SLOTS)]bool,
}

// Redraw the legend slots for the device in use.
@(private)
world_legend_vblank :: proc() {
	for s, i in SLOTS {
		now := slot_read(s)
		if now != legend.seen[i] {
			legend.seen[i] = now
			legend.game[i] = slot_hash(s, now) == s.hash
		}
		if legend.game[i] {
			legend.saved[i] = now
		} else if !(legend.active[i] && now == legend.written[i]) {
			legend.active[i] = false
			continue
		}
		want := legend.saved[i]
		if text := slot_text(s.button); text != "" {
			want = slot_draw(s, text)
		}
		if want != now {
			slot_write(s, want)
		}
		legend.written[i] = want
		legend.active[i] = true
	}
}

// The label for a slot's button, or "" to keep the game's.
@(private = "file")
slot_text :: proc(b: Slot_Button) -> string {
	switch b {
	case .Triangle:
		return button_label(psx.PAD_TRIANGLE)
	case .Circle:
		return button_label(psx.PAD_CIRCLE)
	case .Square:
		return button_label(psx.PAD_SQUARE)
	case .Select:
		return button_label(psx.PAD_SELECT)
	case .Confirm:
		mask := action_mask(.Confirm)
		if mask == 0 {
			return ""
		}
		return button_label(mask & (~mask + 1))
	case .Menu:
		if psx.input_device() == .PlayStation {
			return "START"
		}
		return button_label(psx.PAD_START)
	case .Shoulders:
		l1, r1 := button_label(psx.PAD_L1), button_label(psx.PAD_R1)
		if l1 == "" || r1 == "" {
			return ""
		}
		text := strings.concatenate({l1, "/", r1}, context.temp_allocator)
		if len(text) > 5 {
			l1, r1 = button_label(psx.PAD_L1, true), button_label(psx.PAD_R1, true)
			text = strings.concatenate({l1, "/", r1}, context.temp_allocator)
		}
		return text
	}
	return ""
}

// The name of what is bound to console button `bit` in at most five
// characters (two when `short`), or "" for none or a PlayStation pad.
@(private = "file")
button_label :: proc(bit: u16, short := false) -> string {
	name: string
	switch device := psx.input_device(); device {
	case .PlayStation:
		return ""
	case .Keyboard:
		names: [1]string
		if psx.key_sources(bit, names[:]) == 0 {
			return ""
		}
		if short {
			return tag_key_text(names[0])
		}
		name = key_label(names[0])
	case .Xbox, .Nintendo:
		c, ok := psx.pad_source(bit)
		if !ok {
			return ""
		}
		if short {
			return PAD_GLYPHS_SHORT[device][c]
		}
		name = strings.to_upper(PAD_CONTROL_NAMES[device][c], context.temp_allocator)
	}
	if len(name) > 5 || !small_font_has(name) {
		return ""
	}
	return name
}

// Two-character names of the shoulder buttons for the "L1/R1" legend.
@(private = "file")
PAD_GLYPHS_SHORT := [psx.Input_Device][psx.Pad_Control]string {
	.Keyboard    = {},
	.PlayStation = {},
	.Xbox        = #partial {.Left_Shoulder = "LB", .Right_Shoulder = "RB"},
	.Nintendo    = #partial {.Left_Shoulder = "L", .Right_Shoulder = "R"},
}

// A key's name as a legend shows it.
@(private = "file")
key_label :: proc(name: string) -> string {
	switch name {
	case "Return", "Keypad Enter":
		return "ENTER"
	case "Escape":
		return "ESC"
	case "Left Shift", "Right Shift":
		return "SHIFT"
	case "Left Ctrl", "Right Ctrl":
		return "CTRL"
	case "Left Alt", "Right Alt":
		return "ALT"
	case "Backspace":
		return "BKSP"
	case "Delete":
		return "DEL"
	case "PageUp":
		return "PGUP"
	case "PageDown":
		return "PGDN"
	case "Up":
		return SYM_UP
	case "Down":
		return SYM_DOWN
	case "Left":
		return SYM_LEFT
	case "Right":
		return SYM_RIGHT
	}
	if strings.has_prefix(name, "Keypad ") && len(name) == len("Keypad ") + 1 {
		return strings.concatenate({"KP", name[len(name) - 1:]}, context.temp_allocator)
	}
	upper := strings.to_upper(name, context.temp_allocator)
	if len(upper) <= 5 && small_font_has(upper) {
		return upper
	}
	return tag_key_text(name)
}

// The slot with `text` centred on it: one character in the 5x5 font, more
// in the small one, outlined.
@(private = "file")
slot_draw :: proc(s: Slot, text: string) -> (p: Slot_Pixels) {
	ink: Slot_Pixels
	width := len(text) == 1 ? 5 : 4 * len(text) - 1
	x0 := (s.w - width) / 2
	y0 := (s.h - 5) / 2
	if len(text) == 1 {
		for &g in FONT_5 {
			if g.c == text[0] {
				slot_ink(&ink, g.rows[:], x0, y0)
				break
			}
		}
	} else {
		for k in 0 ..< len(text) {
			for &g in FONT_3 {
				if g.c == text[k] {
					slot_ink(&ink, g.rows[:], x0 + 4 * k, y0)
					break
				}
			}
		}
	}
	fill: u8 = s.dim ? LEGEND_DIM : LEGEND_LIT
	for y in 0 ..< s.h {
		for x in 0 ..< s.w {
			switch {
			case ink[y][x] != 0:
				p[y][x] = fill
			case slot_inked_near(ink, s, x, y):
				p[y][x] = LEGEND_OUTLINE
			case:
				p[y][x] = LEGEND_BG
			}
		}
	}
	return p
}

@(private = "file")
slot_ink :: proc(ink: ^Slot_Pixels, rows: []string, x0, y0: int) {
	for row, y in rows {
		for x in 0 ..< len(row) {
			if row[x] == '#' && x0 + x >= 0 && x0 + x < SLOT_MAX_W {
				ink[y0 + y][x0 + x] = 1
			}
		}
	}
}

@(private = "file")
slot_inked_near :: proc(ink: Slot_Pixels, s: Slot, x, y: int) -> bool {
	for dy in -1 ..= 1 {
		for dx in -1 ..= 1 {
			nx, ny := x + dx, y + dy
			if nx >= 0 && nx < s.w && ny >= 0 && ny < s.h && ink[ny][nx] != 0 {
				return true
			}
		}
	}
	return false
}

@(private = "file")
slot_hash :: proc(s: Slot, p: Slot_Pixels) -> u32 {
	h: u32 = 0x811c9dc5
	for y in 0 ..< s.h {
		for x in 0 ..< s.w {
			h = (h ~ u32(p[y][x])) * 0x01000193
		}
	}
	return h
}

@(private = "file")
slot_read :: proc(s: Slot) -> (p: Slot_Pixels) {
	// 8bpp texels are the bytes of the page's halfwords, low byte first.
	for y in 0 ..< s.h {
		row := ([^]u8)(psx.vram_at(LEGEND_PAGE_X, i32(s.v + y)))
		copy(p[y][:s.w], row[s.u:][:s.w])
	}
	return p
}

@(private = "file")
slot_write :: proc(s: Slot, p: Slot_Pixels) {
	for y in 0 ..< s.h {
		for x in 0 ..< s.w {
			u := s.u + x
			w := psx.vram_at(i32(LEGEND_PAGE_X + u / 2), i32(s.v + y))
			shift := 8 * uint(u & 1)
			w^ = w^ &~ (0xff << shift) | u16(p[y][x]) << shift
		}
	}
}
