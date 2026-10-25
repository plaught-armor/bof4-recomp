// In-game map editor. F4 on the field (with the player in control) stops the
// party and puts a cursor on the leader's cell; the pad then edits the map
// under it, and Start writes the edits to `<maps>/<map>.edit` (map_mods.odin),
// which every later load of the map applies. F4 again leaves.
//
// Tools (L2/R2 cycle):
//   Cell     collision attribute of the cursor cell (palette, Cross paints)
//   Vertex   one corner height of the ground tiles round the nearest vertex
//   Tile     all four corner heights of the cursor's tile
//   Texture  the tile's texture: texel cell, corner turn, flip, slot, UV base
//   Exit     the fields of the section's exit under the cursor
//
// The d-pad moves the cursor relative to the camera; L1/R1 still turn it.
// Select picks the next floor of the section (the Texture tool: the next
// texture field). Edits change RAM at once; a room an instant door shows
// from its kept copy (interiors.odin) shows the copy until the map loads
// again. Autoplay's `edit` stands in for F4.
package qol

import "core:fmt"
import "core:math"
import "core:path/filepath"
import sdl "vendor:sdl2"
import cpu "ps:psx/cpu"
import gpu "ps:psx/gpu"
import gte "ps:psx/gte"
import host "ps:psx/host"

@(private = "file")
EDIT_BLOCK :: 0x80069800 // where a field map's data block loads (map_mods.odin)
@(private = "file")
BLOCK_GRIDS :: 0x4
@(private = "file")
OBJ_POS :: 0xc
@(private = "file")
OBJ_LAYER :: 0x18
@(private = "file")
LEADER_Y :: 0x80116fc0
@(private = "file")
EXIT_SIZE :: 12
@(private = "file")
EXIT_END :: 0xffff

@(private = "file")
REPEAT_DELAY :: 12 // vblanks a button is held before it repeats
@(private = "file")
REPEAT_EVERY :: 3
@(private = "file")
GLYPH_W :: 8 // the OSD font's glyph width
@(private = "file")
DOT_REACH :: 8 // cells round the cursor whose kinds are marked

@(private = "file")
PALETTE :: [?]u8{0x00, 0x10, 0x11, 0x20, 0x21, 0xa0, 0xa1, 0xa2, 0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7}

@(private = "file")
COL_HUD :: 0xc0000000
@(private = "file")
COL_TEXT :: 0xffe8e8e8
@(private = "file")
COL_DIM :: 0xff9098a0
@(private = "file")
COL_CURSOR :: 0xffffffff
@(private = "file")
COL_SELECT :: 0xff40e0ff
@(private = "file")
COL_WALL :: 0xffe04040
@(private = "file")
COL_EXIT :: 0xffe0d040
@(private = "file")
COL_STAIRS :: 0xff40d0e0
@(private = "file")
COL_LEVEL :: 0xff50d060
@(private = "file")
COL_OTHER :: 0xffd060d0

Edit_Tool :: enum u8 {
	Cell,
	Vertex,
	Tile,
	Texture,
	Exit,
}

// The texture fields Select steps through in the Texture tool.
@(private = "file")
Texture_Field :: enum u8 {
	Cell,
	Turn,
	Flip,
	Slot,
	Uv,
}

// An exit field: its byte offset, size and the step of one press.
@(private = "file")
Exit_Field :: struct {
	name:      string,
	at, size:  u32,
	step:      i32,
	signed:    bool,
}

@(private = "file")
EXIT_FIELDS :: [?]Exit_Field {
	{"map", 0, 2, 1, false},
	{"section", 2, 1, 1, false},
	{"flags", 3, 1, 1, false},
	{"x", 4, 1, 1, false},
	{"z", 5, 1, 1, false},
	{"arrive x", 6, 2, 64, true},
	{"arrive z", 8, 2, 64, true},
	{"count", 10, 1, 1, false},
	{"facing", 11, 1, 1, false},
}

// The brush the Texture tool paints: tile byte 0 bits 1-3, byte 2 bits 0-5,
// byte 3.
@(private = "file")
Texture_Brush :: struct {
	flags, page, cell: u8,
}

map_editor: struct {
	on:         bool,
	tool:       Edit_Tool,
	cursor:     [2]i32, // cell x, z
	layer:      u32, // floor, counted from the section's first
	map_id:     u32,
	section:    u32,
	pad:        u16, // buttons as the game last read them
	held_for:   [16]u32, // vblanks each button has been held
	palette:    int,
	height:     i8,
	texture:    Texture_Brush,
	field:      Texture_Field,
	exit:       u32, // the selected exit's address, 0 when none
	exit_field: int,
	exit_edit:  bool, // the d-pad edits the exit's fields
	dirty:      bool,
	toggle:     bool, // F4 went down (or autoplay's edit)
	message:    [96]u8,
	message_n:  int,
	next_pad:   proc(held: u16) -> u16,
}

map_editor_init :: proc() -> bool {
	map_editor.next_pad = host.pad_hook
	host.pad_hook = editor_pad
	host.key_hook = editor_key
	return true
}

// host.pad_hook: notes the buttons; while editing the game sees only L1/R1
// (the camera turn and zoom).
@(private = "file")
editor_pad :: proc(held: u16) -> u16 {
	map_editor.pad = held
	held := held
	if map_editor.on {
		held &= host.PAD_L1 | host.PAD_R1
	}
	return map_editor.next_pad != nil ? map_editor.next_pad(held) : held
}

// host.key_hook: F4 toggles the editor.
@(private = "file")
editor_key :: proc(k: sdl.KeyboardEvent) -> bool {
	if k.keysym.scancode != .F4 {
		return false
	}
	if k.type == .KEYDOWN && k.repeat == 0 {
		map_editor.toggle = true
	}
	return true
}

@(private = "file")
say :: proc(format: string, args: ..any) {
	map_editor.message_n = len(fmt.bprintf(map_editor.message[:], format, ..args))
}

// The field with the player in control and the map's block where edits
// can be saved.
@(private = "file")
can_edit :: proc() -> bool {
	_, ok := grid_of(0)
	return player_control() && cpu.lw(MAP_BLOCK) == EDIT_BLOCK && ok && !on_world_map()
}

@(private = "file")
editor_enter :: proc() {
	if !can_edit() {
		host.osd_toast("Map editor: only on a field map with control")
		return
	}
	leader := leader_obj()
	map_editor.on = true
	map_editor.map_id = cpu.lhu(MAP_ID)
	map_editor.section = cpu.lbu(MAP_SECTION)
	map_editor.layer = min(cpu.lbu(leader + OBJ_LAYER), section_layers(map_editor.section) - 1)
	map_editor.cursor = {
		i32((cpu.lw(leader + OBJ_POS) + 0x8000) >> 16),
		i32((cpu.lw(leader + OBJ_POS + 8) + 0x8000) >> 16),
	}
	map_editor.exit_edit = false
	map_editor.held_for = {}
	clamp_cursor()
	say("")
}

@(private = "file")
editor_leave :: proc(why: string) {
	map_editor.on = false
	map_editor.exit_edit = false
	host.sticks_left_blocked = false
	host.osd_overlay_shown = false
	if map_editor.dirty {
		host.osd_toast("Map editor: unsaved edits stay until the map reloads")
	} else if why != "" {
		host.osd_toast(why)
	}
}

@(private)
map_editor_vblank :: proc() {
	if map_editor.toggle {
		map_editor.toggle = false
		if map_editor.on {
			editor_leave("")
		} else {
			editor_enter()
		}
	}
	if !map_editor.on {
		return
	}
	if cpu.lhu(MAP_ID) != map_editor.map_id || cpu.lw(SLOT_ENGINE) != FLD_MAIN_ID || cpu.lw(MAP_BLOCK) != EDIT_BLOCK {
		map_editor.dirty = false
		editor_leave("Map editor: left the map")
		return
	}
	if cpu.lbu(MAP_SECTION) != map_editor.section {
		map_editor.section = cpu.lbu(MAP_SECTION)
		map_editor.layer = 0
	}
	host.sticks_left_blocked = true
	for &n, i in map_editor.held_for {
		n = map_editor.pad & (1 << u16(i)) != 0 ? n + 1 : 0
	}
	// Only the field proper takes edits (not a camera turn or an event).
	if cpu.lhu(GAME_MODE) == GAME_MODE_FIELD {
		editor_input()
	}
	draw_overlay()
}

// A press of `button` this vblank.
@(private = "file")
pressed :: proc(button: u16) -> bool {
	return map_editor.held_for[bit_index(button)] == 1
}

// A press, or a repeat while it stays held.
@(private = "file")
fired :: proc(button: u16) -> bool {
	n := map_editor.held_for[bit_index(button)]
	return n == 1 || (n > REPEAT_DELAY && (n - REPEAT_DELAY) % REPEAT_EVERY == 0)
}

@(private = "file")
held :: proc(button: u16) -> bool {
	return map_editor.held_for[bit_index(button)] > 0
}

@(private = "file")
bit_index :: proc(button: u16) -> int {
	for i in 0 ..< 16 {
		if button == 1 << u16(i) {
			return i
		}
	}
	return 0
}

@(private = "file")
editor_input :: proc() {
	e := &map_editor
	if pressed(host.PAD_START) {
		if path, ok := map_mods_save(); ok {
			e.dirty = false
			say("saved %s", filepath.base(path))
			host.osd_toast(fmt.tprintf("Map saved: %s", filepath.base(path)))
		} else {
			say("save failed (see the console)")
		}
		return
	}
	if pressed(host.PAD_L2) || pressed(host.PAD_R2) {
		n := len(Edit_Tool)
		e.tool = Edit_Tool((int(e.tool) + (pressed(host.PAD_R2) ? 1 : n - 1)) % n)
		e.exit_edit = false
		e.message_n = 0
		return
	}
	if e.exit_edit {
		exit_input()
		return
	}
	if pressed(host.PAD_SELECT) {
		if e.tool == .Texture {
			e.field = Texture_Field((int(e.field) + 1) % len(Texture_Field))
		} else {
			e.layer = (e.layer + 1) % section_layers(e.section)
			clamp_cursor()
		}
	}
	move_cursor()
	e.exit = exit_under(e.cursor)
	switch e.tool {
	case .Cell:
		cell_input()
	case .Vertex, .Tile:
		height_input()
	case .Texture:
		texture_input()
	case .Exit:
		if pressed(host.PAD_CROSS) && e.exit != 0 {
			e.exit_edit = true
		}
	}
}

// The d-pad, turned to the nearest quarter of the camera's facing.
@(private = "file")
move_cursor :: proc() {
	steps := [4][2]i32{{0, -1}, {1, 0}, {0, 1}, {-1, 0}}
	yaw := f64(cpu.lhu(CAMERA_YAW)) * 360 / 4096
	q := int(math.round(yaw / 90)) & 3
	for button, k in ([4]u16{host.PAD_UP, host.PAD_RIGHT, host.PAD_DOWN, host.PAD_LEFT}) {
		if fired(button) {
			map_editor.cursor += steps[(q + k) & 3]
		}
	}
	clamp_cursor()
}

@(private = "file")
clamp_cursor :: proc() {
	g, ok := grid_of(map_editor.layer)
	if !ok {
		return
	}
	map_editor.cursor = {clamp(map_editor.cursor.x, 0, g.w - 1), clamp(map_editor.cursor.y, 0, g.h - 1)}
}

@(private = "file")
edit :: proc(addr: u32, value: u8) {
	if u8(cpu.lbu(addr)) == value {
		return
	}
	if map_mods_edit(addr, value) {
		map_editor.dirty = true
	} else {
		say("%08x is outside the map's data", addr)
	}
}

@(private = "file")
cell_input :: proc() {
	e := &map_editor
	palette := PALETTE
	if fired(host.PAD_TRIANGLE) {
		e.palette = (e.palette + 1) % len(palette)
	}
	if fired(host.PAD_SQUARE) {
		e.palette = (e.palette + len(palette) - 1) % len(palette)
	}
	g, ok := grid_of(e.layer)
	if !ok {
		return
	}
	at := g.attrs + u32(e.cursor.y * g.w + e.cursor.x)
	if pressed(host.PAD_CIRCLE) {
		attr := u8(cpu.lbu(at))
		for p, i in palette {
			if p == attr {
				e.palette = i
			}
		}
		say("picked %02x", attr)
	}
	if held(host.PAD_CROSS) {
		edit(at, palette[e.palette])
	}
}

// The corners the Vertex or Tile tool works on: tile address and corner
// index, up to four.
@(private = "file")
Corner :: struct {
	tile:   u32,
	corner: u32,
}

@(private = "file")
cursor_corners :: proc(out: ^[4]Corner) -> int {
	c := map_editor.cursor
	n := 0
	if map_editor.tool == .Tile {
		if t := tile_at(map_editor.layer, c.x >> 1, c.y >> 1); t != 0 && cpu.lbu(t) & TILE_GROUND != 0 {
			for k in 0 ..< u32(4) {
				out[n] = {t, k}
				n += 1
			}
		}
		return n
	}
	v := cursor_vertex()
	for tz in v.y - 1 ..= v.y {
		for tx in v.x - 1 ..= v.x {
			if t := tile_at(map_editor.layer, tx, tz); t != 0 && cpu.lbu(t) & TILE_GROUND != 0 {
				out[n] = {t, u32(v.x - tx) + 2 * u32(v.y - tz)}
				n += 1
			}
		}
	}
	return n
}

// The tile corner nearest the cursor cell's middle.
@(private = "file")
cursor_vertex :: proc() -> [2]i32 {
	return {(map_editor.cursor.x + 1) >> 1, (map_editor.cursor.y + 1) >> 1}
}

@(private = "file")
height_input :: proc() {
	e := &map_editor
	corners: [4]Corner
	n := cursor_corners(&corners)
	if n == 0 {
		return
	}
	// Heights are positive up.
	delta: i32
	if fired(host.PAD_TRIANGLE) {
		delta += 1
	}
	if fired(host.PAD_SQUARE) {
		delta -= 1
	}
	if fired(host.PAD_CROSS) {
		for c in corners[:n] {
			edit(c.tile + 4 + c.corner, u8(e.height))
		}
	}
	if pressed(host.PAD_CIRCLE) {
		e.height = i8(cpu.lbu(corners[0].tile + 4 + corners[0].corner))
		say("picked height %d", e.height)
	}
	if delta != 0 {
		for c in corners[:n] {
			h := i32(i8(cpu.lbu(c.tile + 4 + c.corner)))
			edit(c.tile + 4 + c.corner, u8(i8(clamp(h + delta, -128, 127))))
		}
	}
}

@(private = "file")
texture_input :: proc() {
	e := &map_editor
	b := &e.texture
	step: i32
	if fired(host.PAD_TRIANGLE) {
		step += 1
	}
	if fired(host.PAD_SQUARE) {
		step -= 1
	}
	if step != 0 {
		switch e.field {
		case .Cell:
			b.cell = u8(i32(b.cell) + step)
		case .Turn:
			b.flags = b.flags &~ TILE_UV_TURN | u8((i32(b.flags >> 2) + step) & 3) << 2
		case .Flip:
			b.flags ~= TILE_FLIP
		case .Slot:
			b.page = b.page &~ 0x0f | u8((i32(b.page) + step) & 0x0f)
		case .Uv:
			b.page = b.page &~ 0x30 | u8((i32(b.page >> 4) + step) & 3) << 4
		}
	}
	t := tile_at(e.layer, e.cursor.x >> 1, e.cursor.y >> 1)
	if t == 0 || cpu.lbu(t) & TILE_GROUND == 0 {
		return
	}
	if pressed(host.PAD_CIRCLE) {
		b^ = {u8(cpu.lbu(t)) & (TILE_FLIP | TILE_UV_TURN), u8(cpu.lbu(t + 2)) & 0x3f, u8(cpu.lbu(t + 3))}
		say("picked texture")
	}
	if held(host.PAD_CROSS) {
		edit(t, u8(cpu.lbu(t)) &~ (TILE_FLIP | TILE_UV_TURN) | b.flags)
		edit(t + 2, u8(cpu.lbu(t + 2)) & 0xc0 | b.page)
		edit(t + 3, b.cell)
	}
}

@(private = "file")
exit_input :: proc() {
	e := &map_editor
	fields := EXIT_FIELDS
	if pressed(host.PAD_CIRCLE) || pressed(host.PAD_CROSS) || e.exit == 0 {
		e.exit_edit = false
		return
	}
	if fired(host.PAD_UP) {
		e.exit_field = (e.exit_field + len(fields) - 1) % len(fields)
	}
	if fired(host.PAD_DOWN) {
		e.exit_field = (e.exit_field + 1) % len(fields)
	}
	f := fields[e.exit_field]
	step: i32
	if fired(host.PAD_RIGHT) {
		step += f.step
	}
	if fired(host.PAD_LEFT) {
		step -= f.step
	}
	if fired(host.PAD_TRIANGLE) {
		step += 16 * f.step
	}
	if fired(host.PAD_SQUARE) {
		step -= 16 * f.step
	}
	if step == 0 {
		return
	}
	v := exit_value(e.exit, f) + step
	edit(e.exit + f.at, u8(v))
	if f.size == 2 {
		edit(e.exit + f.at + 1, u8(v >> 8))
	}
}

@(private = "file")
exit_value :: proc(exit: u32, f: Exit_Field) -> i32 {
	if f.size == 1 {
		return i32(cpu.lbu(exit + f.at))
	}
	v := cpu.lbu(exit + f.at) | cpu.lbu(exit + f.at + 1) << 8
	return f.signed ? i32(i16(u16(v))) : i32(v)
}

// The cells an exit covers: from its x, z, `count` along x (or z).
@(private = "file")
exit_covers :: proc(exit: u32, c: [2]i32) -> bool {
	at := [2]i32{i32(cpu.lbu(exit + 4)), i32(cpu.lbu(exit + 5))}
	along := cpu.lbu(exit + 3) & 1 != 0 ? 1 : 0
	n := max(i32(cpu.lbu(exit + 10)), 1)
	return c[1 - along] == at[1 - along] && c[along] >= at[along] && c[along] < at[along] + n
}

@(private = "file")
exit_under :: proc(c: [2]i32) -> u32 {
	for p := exit_list(map_editor.section); p != 0 && cpu.lhu(p) != EXIT_END; p += EXIT_SIZE {
		if exit_covers(p, c) {
			return p
		}
	}
	return 0
}

// Tile (tx, tz) of floor `layer` of the section, 0 when the row has none.
@(private = "file")
tile_at :: proc(layer: u32, tx, tz: i32) -> u32 {
	desc := layer_desc(map_editor.section + layer)
	if desc == 0 || tx < 0 || tz < 0 {
		return 0
	}
	blk := cpu.lw(MAP_BLOCK)
	header := blk + cpu.lw(blk + BLOCK_GRIDS + 4 * cpu.lbu(desc))
	if !in_ram(header) || tx >= i32(cpu.lhu(header)) || tz >= i32(cpu.lhu(header + 2)) {
		return 0
	}
	row := header + cpu.lw(header + 4) + 4 * u32(tz)
	first := i32(cpu.lbu(row))
	if tx < first || tx >= first + i32(cpu.lbu(row + 1)) {
		return 0
	}
	return header + cpu.lw(header + 8) + 16 * (u32(cpu.lhu(row + 2)) + u32(tx - first))
}

// ---------------------------------------------------------------- drawing

// The ground's height at view (x, z) of the cursor's floor, as the game
// splits a tile's quad; the leader's height off the ground.
@(private = "file")
ground_y :: proc(x, z: f64) -> f64 {
	tx, tz := i32(math.floor((x + 64) / 256)), i32(math.floor((z + 64) / 256))
	t := tile_at(map_editor.layer, tx, tz)
	if t == 0 || cpu.lbu(t) & TILE_GROUND == 0 {
		return f64(i32(cpu.lw(LEADER_Y)) >> 9)
	}
	h: [4]f64
	for &v, k in h {
		v = f64(i8(cpu.lbu(t + 4 + u32(k)))) * 16
	}
	dx, dz := (x + 64 - f64(tx) * 256) / 256, (z + 64 - f64(tz) * 256) / 256
	if dx + dz < 1 {
		return h[0] + (h[1] - h[0]) * dx + (h[2] - h[0]) * dz
	}
	return h[3] + (h[2] - h[3]) * (1 - dx) + (h[1] - h[3]) * (1 - dz)
}

// View point p (the cursor floor's frame) on the canvas; ok false behind
// the camera.
@(private = "file")
project :: proc(p: [3]f64) -> (s: [2]f64, ok: bool) {
	shift := origin(map_editor.section + map_editor.layer) - origin(map_editor.section)
	p := p + {f64(shift.x), f64(shift.y), f64(shift.z)}
	v: [3]f64
	for r in 0 ..< u32(3) {
		sum := f64(i32(cpu.lw(CAM_TR + 4 * r))) * 4096
		for i in 0 ..< u32(3) {
			sum += f64(i16(cpu.lhu(CAM_MATRIX + 6 * r + 2 * i))) * p[i]
		}
		v[r] = sum / 4096
	}
	if v.z <= 16 {
		return {}, false
	}
	h := f64(i32(cpu.lw(EDIT_CAM_H)))
	screen := gte.gte_offset() + v.xy * h / v.z
	return screen * {640 / f64(max(gpu.display.w, 1)), 480 / f64(max(gpu.display.h, 1))}, true
}

@(private = "file")
EDIT_CAM_H :: 0x80138184 // s32, projection distance

@(private = "file")
cell_point :: proc(x, z: f64) -> [3]f64 {
	return {x, ground_y(x, z), z}
}

@(private = "file")
line3 :: proc(pix: []u32, a, b: [3]f64, colour: u32) {
	sa, oka := project(a)
	sb, okb := project(b)
	if oka && okb {
		line(pix, sa, sb, colour)
	}
}

@(private = "file")
line :: proc(pix: []u32, a, b: [2]f64, colour: u32) {
	LIMIT :: 4096
	if abs(a.x) > LIMIT || abs(a.y) > LIMIT || abs(b.x) > LIMIT || abs(b.y) > LIMIT {
		return
	}
	x0, y0 := int(math.round(a.x)), int(math.round(a.y))
	x1, y1 := int(math.round(b.x)), int(math.round(b.y))
	dx, dy := abs(x1 - x0), -abs(y1 - y0)
	sx, sy := x0 < x1 ? 1 : -1, y0 < y1 ? 1 : -1
	err := dx + dy
	for {
		plot(pix, x0, y0, colour)
		if x0 == x1 && y0 == y1 {
			return
		}
		e2 := 2 * err
		if e2 >= dy {
			err += dy
			x0 += sx
		}
		if e2 <= dx {
			err += dx
			y0 += sy
		}
	}
}

@(private = "file")
plot :: proc(pix: []u32, x, y: int, colour: u32) {
	if x >= 0 && y >= 0 && x < host.WINDOW_W && y < host.WINDOW_H {
		pix[y * host.WINDOW_W + x] = colour
	}
}

// A ground outline of the box lo..hi (view x, z), each side in `steps`
// pieces so it follows the ground.
@(private = "file")
outline :: proc(pix: []u32, lo, hi: [2]f64, colour: u32, steps := 2) {
	corners := [4][2]f64{lo, {hi.x, lo.y}, hi, {lo.x, hi.y}}
	for k in 0 ..< 4 {
		a, b := corners[k], corners[(k + 1) & 3]
		for s in 0 ..< steps {
			p := a + (b - a) * f64(s) / f64(steps)
			q := a + (b - a) * f64(s + 1) / f64(steps)
			line3(pix, cell_point(p.x, p.y), cell_point(q.x, q.y), colour)
		}
	}
}

@(private = "file")
cell_box :: proc(c: [2]i32) -> (lo, hi: [2]f64) {
	lo = {f64(c.x) * 128 - 64, f64(c.y) * 128 - 64}
	return lo, lo + 128
}

@(private = "file")
kind_colour :: proc(attr: u8) -> u32 {
	switch attr >> 4 {
	case 0:
		return 0
	case 0x1:
		return COL_WALL
	case 0x2:
		return COL_LEVEL
	case 0xa:
		return COL_EXIT
	case 0x7, 0xc:
		return COL_STAIRS
	}
	return COL_OTHER
}

@(private = "file")
draw_overlay :: proc() {
	e := &map_editor
	pix := host.osd_overlay_pixels[:]
	for &p in pix {
		p = 0
	}
	if g, ok := grid_of(e.layer); ok {
		for z in max(e.cursor.y - DOT_REACH, 0) ..= min(e.cursor.y + DOT_REACH, g.h - 1) {
			for x in max(e.cursor.x - DOT_REACH, 0) ..= min(e.cursor.x + DOT_REACH, g.w - 1) {
				colour := kind_colour(attr_at(g, x, z))
				if colour == 0 {
					continue
				}
				if s, ok := project(cell_point(f64(x) * 128, f64(z) * 128)); ok {
					for dy in -1 ..= 1 {
						for dx in -1 ..= 1 {
							plot(pix, int(s.x) + dx, int(s.y) + dy, colour)
						}
					}
				}
			}
		}
	}
	for p := exit_list(e.section); p != 0 && cpu.lhu(p) != EXIT_END; p += EXIT_SIZE {
		at := [2]i32{i32(cpu.lbu(p + 4)), i32(cpu.lbu(p + 5))}
		along := cpu.lbu(p + 3) & 1 != 0 ? 1 : 0
		end := at
		end[along] += max(i32(cpu.lbu(p + 10)), 1) - 1
		lo, _ := cell_box(at)
		_, hi := cell_box(end)
		outline(pix, lo, hi, p == e.exit ? COL_SELECT : COL_EXIT, 4)
	}
	switch e.tool {
	case .Cell, .Exit:
		lo, hi := cell_box(e.cursor)
		outline(pix, lo, hi, COL_CURSOR)
	case .Tile, .Texture:
		lo := [2]f64{f64(e.cursor.x >> 1) * 256 - 64, f64(e.cursor.y >> 1) * 256 - 64}
		outline(pix, lo, lo + 256, COL_CURSOR, 4)
	case .Vertex:
		v := cursor_vertex()
		at := [2]f64{f64(v.x) * 256 - 64, f64(v.y) * 256 - 64}
		y := vertex_y(v, at)
		line3(pix, {at.x - 48, y, at.y}, {at.x + 48, y, at.y}, COL_CURSOR)
		line3(pix, {at.x, y, at.y - 48}, {at.x, y, at.y + 48}, COL_CURSOR)
		line3(pix, {at.x, y, at.y}, {at.x, y + 64, at.y}, COL_CURSOR)
	}
	draw_hud(pix)
	host.osd_overlay_shown = true
	host.osd_overlay_changed()
}

// The vertex's height from a ground tile that has it, else the ground's.
@(private = "file")
vertex_y :: proc(v: [2]i32, at: [2]f64) -> f64 {
	for tz in v.y - 1 ..= v.y {
		for tx in v.x - 1 ..= v.x {
			if t := tile_at(map_editor.layer, tx, tz); t != 0 && cpu.lbu(t) & TILE_GROUND != 0 {
				return f64(i8(cpu.lbu(t + 4 + u32(v.x - tx) + 2 * u32(v.y - tz)))) * 16
			}
		}
	}
	return ground_y(at.x, at.y)
}

@(private = "file")
draw_hud :: proc(pix: []u32) {
	e := &map_editor
	lines: [4]string
	lines[0] = fmt.tprintf("MAP %04x  SECTION %d  FLOOR %d/%d  CELL %d,%d  %v", e.map_id, e.section, e.layer + 1, section_layers(e.section), e.cursor.x, e.cursor.y, e.tool)
	switch e.tool {
	case .Cell:
		attr: u8 = 0
		if g, ok := grid_of(e.layer); ok {
			attr = attr_at(g, e.cursor.x, e.cursor.y)
		}
		palette := PALETTE
		lines[1] = fmt.tprintf("cell %02x  brush %02x", attr, palette[e.palette])
		lines[2] = "X paint  O pick  /\\ [] brush  SEL floor"
	case .Vertex, .Tile:
		corners: [4]Corner
		n := cursor_corners(&corners)
		if n == 0 {
			lines[1] = fmt.tprintf("no ground tile  brush %d", e.height)
		} else {
			lines[1] = fmt.tprintf("height %d  brush %d  (%d corners)", i8(cpu.lbu(corners[0].tile + 4 + corners[0].corner)), e.height, n)
		}
		lines[2] = "/\\ raise  [] lower  X set brush  O pick  SEL floor"
	case .Texture:
		b := e.texture
		lines[1] = fmt.tprintf("brush cell %02x turn %d flip %d slot %d uv %d  [%v]", b.cell, b.flags >> 2 & 3, b.flags >> 1 & 1, b.page & 0xf, b.page >> 4 & 3, e.field)
		if t := tile_at(e.layer, e.cursor.x >> 1, e.cursor.y >> 1); t != 0 && cpu.lbu(t) & TILE_GROUND != 0 {
			lines[1] = fmt.tprintf("%s  tile %02x %02x %02x", lines[1], cpu.lbu(t), cpu.lbu(t + 2), cpu.lbu(t + 3))
		}
		lines[2] = "X paint  O pick  /\\ [] change  SEL field"
	case .Exit:
		if e.exit == 0 {
			lines[1] = "no exit here"
			lines[2] = "move onto an exit (yellow)"
		} else {
			fields := EXIT_FIELDS
			f := fields[e.exit_field]
			lines[1] = fmt.tprintf("to %04x:%d  at %d,%d  arrive %d,%d  %s = %d", cpu.lhu(e.exit), cpu.lbu(e.exit + 2), cpu.lbu(e.exit + 4), cpu.lbu(e.exit + 5), exit_value(e.exit, fields[5]), exit_value(e.exit, fields[6]), f.name, exit_value(e.exit, f))
			lines[2] = e.exit_edit ? "UP/DN field  LT/RT +-1  /\\ [] +-16  O done" : "X edit fields"
		}
	}
	msg := string(e.message[:e.message_n])
	lines[3] = fmt.tprintf("%s%s  L2/R2 tool  START save  F4 leave", e.dirty ? "* unsaved  " : "", msg)
	width := 0
	for l in lines {
		width = max(width, len(l))
	}
	x0, y0 := 8, 8
	for y in y0 ..< y0 + 4 * 11 + 6 {
		for x in x0 ..< min(x0 + width * GLYPH_W + 8, host.WINDOW_W) {
			pix[y * host.WINDOW_W + x] = COL_HUD
		}
	}
	for l, row in lines {
		colour := u32(row == 2 ? COL_DIM : COL_TEXT)
		for k in 0 ..< len(l) {
			host.osd_put_glyph(pix, host.WINDOW_W, l[k], x0 + 4 + k * GLYPH_W, y0 + 4 + row * 11, colour)
		}
	}
}
