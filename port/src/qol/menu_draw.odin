// Drawing in the game's own style: its menu window frame and its menu font,
// called from the port while the game builds a frame.
//
// The frame end (FRAME_END) links the six layer chains into the ordering
// table. Just before it runs, the hook lets port features commit prims with
// the game's routines; they land last in layer 1, the menus' layer, so they
// draw over the game's own windows (within a layer, later commits draw on
// top, as the camp menu's text over its frames shows). Each game call runs
// on the emulated stack below the caller's frame, and every register is
// restored afterwards, so the game sees nothing but the extra prims.
//
// Coordinates are the game's 320x240 screen space.
package qol

import "core:fmt"

import "../psx"

// a0 x, a1 y, a2 width, a3 height (8..255): frame and dark translucent body.
@(private)
WINDOW_DRAW :: 0x80150ccc
// a0 x, a1 y, a2 colour (CLUT 0..15), a3 most characters, [sp+16] text.
// Text bytes 0x20.. are glyphs (ASCII), 1 starts a new line 14 below.
@(private)
TEXT_DRAW :: 0x80140b2c
// Prims built in place: the next one goes at the address in SPRITE_PACKETS, then
// PRIM_COMMIT (a0 1, the layer; a1 the prim's bytes) links it in.
@(private)
PRIM_COMMIT :: 0x8013ae34
// u8 per character: low nibble = advance in pixels, high = y offset.
@(private)
FONT_WIDTHS :: 0x801743f8

// Room the game calls get below the caller's stack pointer; the text copy
// sits above their argument slots.
@(private = "file")
CALL_FRAME :: 0x200
@(private = "file")
TEXT_AT :: 0x20
@(private = "file")
TEXT_MAX :: 120

// Menu font colours (CLUT index), as the camp menu uses them.
MENU_WHITE :: 0
MENU_GREY :: 1
MENU_RED :: 2
MENU_GREEN :: 4
MENU_YELLOW :: 6
MENU_LINE_H :: 14

SPRITE_UNTINTED :: 0x808080

@(private = "file")
menu_draw: struct {
	frame_end: psx.Func_Proc,
	held:      u16, // pad buttons held at the last vblank, for the panel
}

// Pages of the port's panel (psx's OSD panel, F2 or a camp menu command),
// each drawn by its feature in the game's window and font.
PANEL_JOURNAL :: 0
PANEL_COMBOS :: 1
PANEL_MASTERS :: 2
// The panel's area, in the game's 320x240 screen space. The menu font is 8
// pixels a character (I, i, l narrower), so the panel holds about 37.
PANEL :: [4]int{4, 8, 312, 224} // x, y, width, height

// Pad buttons that hide the panel.
@(private = "file")
PANEL_CLOSE :: psx.PAD_CROSS | psx.PAD_CIRCLE | psx.PAD_TRIANGLE

@(private)
menu_draw_init :: proc() -> bool {
	original, ok := psx.hook(FRAME_END, frame_end)
	if !ok {
		fmt.eprintf("qol: frame end %08x not found\n", FRAME_END)
		return false
	}
	menu_draw.frame_end = original
	return true
}

@(private = "file")
frame_end :: proc() {
	ai_tick()
	timed_tick()
	if timed_draws() {
		timed_draw()
	}
	if masters_draws() {
		masters_draw()
	}
	if examine_draws() {
		examine_draw()
	}
	if moods_draws() {
		moods_draw()
	}
	if combo_menu_draws() {
		combo_menu_draw()
	}
	if tracker_draws() {
		tracker_draw()
	}
	if journal_draws() {
		journal_draw()
	}
	if combos_draws() {
		combos_draw()
	}
	menu_draw.frame_end()
}

// Show the panel on `page`. The buttons held now (the confirm that chose a
// camp menu command) count as seen, so they do not hide it.
@(private)
panel_open :: proc(page: int) {
	psx.osd_panel_page = page
	if !psx.osd_panel_shown {
		psx.osd_toggle_panel()
	}
	menu_draw.held = psx.pad_buttons()
}

// Once per vblank: the buttons newly pressed while the panel is up, for its
// page. Cross, Circle or Triangle hide it; Left and Right turn its pages.
@(private)
panel_vblank :: proc() -> u16 {
	held := psx.pad_buttons()
	pressed := held &~ menu_draw.held
	menu_draw.held = held
	if !psx.osd_panel_shown {
		return 0
	}
	if pressed & PANEL_CLOSE != 0 {
		psx.osd_hide_panel()
		return 0
	}
	if pressed & psx.PAD_LEFT != 0 {
		psx.osd_panel_step(-1)
	}
	if pressed & psx.PAD_RIGHT != 0 {
		psx.osd_panel_step(1)
	}
	return pressed
}

// A game window: border and translucent body.
@(private)
menu_window :: proc(x, y, w, h: int) {
	assert(w >= 16 && w <= 0xffff && h >= 16 && h <= 0xff)
	game_routine(WINDOW_DRAW, {u32(x), u32(y), u32(w), u32(h), 0})
}

// One line of text in the menu font; returns the x after it.
@(private)
menu_text :: proc(x, y: int, text: string, colour := MENU_WHITE) -> int {
	if text == "" {
		return x
	}
	game_routine(TEXT_DRAW, {u32(x), u32(y), u32(colour), 0xff, 0}, text)
	return x + menu_text_width(text)
}

// Text ending at x.
@(private)
menu_text_right :: proc(x, y: int, text: string, colour := MENU_WHITE) {
	menu_text(x - menu_text_width(text), y, text, colour)
}

@(private)
menu_text_width :: proc(text: string) -> (w: int) {
	for i in 0 ..< min(len(text), TEXT_MAX) {
		w += int(psx.lbu(FONT_WIDTHS + u32(text[i])) & 0xf)
	}
	return w
}

// The longest start of text that fits in w pixels.
@(private)
menu_text_fit :: proc(text: string, w: int) -> string {
	used := 0
	for i in 0 ..< min(len(text), TEXT_MAX) {
		used += int(psx.lbu(FONT_WIDTHS + u32(text[i])) & 0xf)
		if used > w {
			return text[:i]
		}
	}
	return text
}

// A sprite of 4-bit texels at (u, v) of the texture page (a GP0 0xe1 page
// number) with the CLUT at VRAM (clut_x, clut_y), its top-left at (x, y).
// The texels are scaled by tint (0xBBGGRR, 0x80 = as is per channel). The
// page is set by a draw mode prim before it.
@(private)
menu_sprite :: proc(x, y, w, h, u, v: int, page: u32, clut_x, clut_y: int, tint: u32 = SPRITE_UNTINTED) {
	SPRITE_TAG :: 0x05000000
	DRAW_MODE :: 0xe1000000
	SPRITE :: 0x64000000
	SPRITE_BYTES :: 0x18
	assert(tint <= 0xffffff && u >= 0 && u + w <= 0x100 && v >= 0 && v + h <= 0x100 && clut_x % 16 == 0)
	prim := psx.lw(SPRITE_PACKETS)
	psx.sw(prim, SPRITE_TAG)
	psx.sw(prim + 4, DRAW_MODE | page)
	psx.sw(prim + 8, SPRITE | tint)
	psx.sw(prim + 12, u32(x) & 0xffff | u32(y) << 16)
	psx.sw(prim + 16, (u32(clut_y) << 6 | u32(clut_x) / 16) << 16 | u32(v) << 8 | u32(u))
	psx.sw(prim + 20, u32(h) << 16 | u32(w))
	game_routine(PRIM_COMMIT, {1, SPRITE_BYTES, 0, 0, 0})
}

// Call a game routine with five arguments (a0..a3, then [sp+16]) on the
// stack below the caller's frame; every register is restored afterwards.
// When text is given, a NUL-terminated copy of it replaces the fifth
// argument. Returns v0.
@(private)
game_routine :: proc(target: u32, args: [5]u32, text := "") -> u32 {
	c := &psx.cpu
	regs, hi, lo := c.r, c.hi, c.lo
	sp := (c.r[29] - CALL_FRAME) &~ 7
	fifth := args[4]
	if text != "" {
		n := min(len(text), TEXT_MAX)
		for i in 0 ..< n {
			psx.sb(sp + TEXT_AT + u32(i), u32(text[i]))
		}
		psx.sb(sp + TEXT_AT + u32(n), 0)
		fifth = sp + TEXT_AT
	}
	psx.sw(sp + 16, fifth)
	c.r[29] = sp
	c.r[4], c.r[5], c.r[6], c.r[7] = args[0], args[1], args[2], args[3]
	c.r[31] = FRAME_END_RET
	// The port's own text already names the device's buttons.
	button_text.raw = target == TEXT_DRAW
	psx.call(target)
	button_text.raw = false
	v0 := c.r[2]
	c.r, c.hi, c.lo = regs, hi, lo
	return v0
}

// Write 4-bit texels (one hex digit each, a row per string, all rows as
// wide, a multiple of 4) at (u, v) of the texture page at VRAM x sheet_x.
// Returns false, leaving VRAM alone, when the spot holds anything other than
// blank texels or these same ones.
@(private)
texels_place :: proc(sheet_x, u, v: int, pixels: []string) -> bool {
	w := len(pixels[0])
	assert(u % 4 == 0 && w % 4 == 0 && w <= 4 * PLACE_HALFWORDS_MAX && len(pixels) <= PLACE_ROWS_MAX, "texels off a halfword or too big")
	rows: [PLACE_ROWS_MAX][PLACE_HALFWORDS_MAX]u16
	for row, y in pixels {
		assert(len(row) == w, "texel rows differ in width")
		for x in 0 ..< w {
			c := row[x]
			nibble := c <= '9' ? u16(c - '0') : u16(c - 'a' + 10)
			rows[y][x / 4] |= nibble << (4 * uint(x % 4))
		}
	}
	return halfwords_place(i32(sheet_x + u / 4), i32(v), &rows, w / 4, len(pixels))
}

// Write a 16-colour CLUT (0xRRGGBB each, 0 transparent) at VRAM
// (x, y), on the same terms as texels_place.
@(private)
clut_place :: proc(x, y: int, colours: [16]u32) -> bool {
	assert(x % 16 == 0 && colours[0] == 0, "CLUT off a 16-halfword step or index 0 not transparent")
	rows: [PLACE_ROWS_MAX][PLACE_HALFWORDS_MAX]u16
	for c, i in colours {
		r, g, b := u16(c >> 19) & 31, u16(c >> 11) & 31, u16(c >> 3) & 31
		rows[0][i] = b << 10 | g << 5 | r
		assert(c == 0 || rows[0][i] != 0, "CLUT colour too dark, it would be transparent")
	}
	return halfwords_place(i32(x), i32(y), &rows, len(colours), 1)
}

@(private = "file")
PLACE_ROWS_MAX :: 16
@(private = "file")
PLACE_HALFWORDS_MAX :: 16

@(private = "file")
halfwords_place :: proc(x0, y0: i32, rows: ^[PLACE_ROWS_MAX][PLACE_HALFWORDS_MAX]u16, w, h: int) -> bool {
	for y in 0 ..< h {
		for x in 0 ..< w {
			now := psx.vram_at(x0 + i32(x), y0 + i32(y))^
			if now != 0 && now != rows[y][x] {
				return false
			}
		}
	}
	for y in 0 ..< h {
		for x in 0 ..< w {
			psx.vram_at(x0 + i32(x), y0 + i32(y))^ = rows[y][x]
		}
	}
	return true
}
