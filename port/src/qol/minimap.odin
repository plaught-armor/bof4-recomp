// Field minimap: a round map of the collision grid in the top-left corner,
// where the game's compass sat (camera.odin hides it). It takes over the
// compass's job: the map turns with the camera so screen-up is the way the
// camera faces, and an N on the rim marks north (-z, world direction 0).
// Select toggles it on the field and the choice is saved as [field] minimap.
//
// It is host drawing (psx OSD inset), not game graphics. Each vblank it
// samples the leader's layer of the grid (see free_move.odin and the exe's
// lookup 0x801537f0): floor, walls, exits and stairs, plus NPC dots and the
// leader's arrow. It shows when the game would show the compass (HUD_SHOWN
// set, HUD not slid away) and the objective box and OSD panel are down,
// fading in and out over FADE_VBLANKS, and dims with a screen fade
// (fade.odin) as the game's own graphics under it do.
package qol

import "core:math"

import "ps:psx"

@(private = "file")
BLOCK_GRIDS :: 0x4 // u32 offsets of the grid headers
@(private = "file")
BLOCK_ATTRS :: 0xa4 // u32 offsets of the attribute arrays
@(private = "file")
BLOCK_LAYERS :: 0xc4 // u32 offsets of the layer descriptors
@(private = "file")
ATTR_OUTSIDE :: 0x10 // what the game reads past the grid's edge

@(private = "file")
OBJ_STATE :: 0x4 // u8
@(private = "file")
OBJ_POS :: 0xc // s32 16.16 x, height, z, then the layer byte
@(private = "file")
OBJ_DIRECTION :: 0x4c // u8, world direction faced, 45 degrees each
@(private = "file")
STATE_CONTROL :: 1
@(private = "file")
STATE_IDLE :: 8

@(private = "file")
HUD_SHOWN :: 0x80116fac // u8, the compass may draw
@(private = "file")
HUD_FLAGS :: 0x8011a94a // u8, bit 0: compass slid off screen
@(private = "file")
GAME_MODE_TURN :: 6 // the field during an L1/R1 camera turn

@(private = "file")
SIZE :: psx.OSD_INSET
@(private = "file")
AT :: [2]int{16, 16} // canvas spot, where the compass was
@(private = "file")
PX_PER_CELL :: 3.0
@(private = "file")
RIM :: 2.0 // rim width in pixels

// ARGB colours.
@(private = "file")
COL_WALL :: 0xa0181c22
@(private = "file")
COL_FLOOR :: 0xc8687480
@(private = "file")
COL_STAIRS :: 0xc890a0b0
@(private = "file")
COL_EXIT :: 0xd8c09848
@(private = "file")
COL_RIM :: 0xe0d8d8d8
@(private = "file")
COL_NPC :: 0xffe06048
@(private = "file")
COL_LEADER :: 0xffffffff
@(private = "file")
COL_NORTH :: 0xffff5040

@(private)
Grid :: struct {
	w, h:  i32,
	attrs: u32,
}

// Vblanks the minimap takes to fade in or out.
@(private = "file")
FADE_VBLANKS :: 15

@(private = "file")
minimap: struct {
	select_held: bool,
	// How far shown, 0..1, before the screen fade.
	shown:       f32,
}

// psx.pad_hook's part, for Select on the field: a press while the player has
// control toggles the map, and the game does not see Select there.
@(private)
minimap_buttons :: proc(held: u16) -> u16 {
	pressed := held & psx.PAD_SELECT != 0
	down := pressed && !minimap.select_held
	minimap.select_held = pressed
	if !player_control() {
		return held
	}
	if down {
		config.field_minimap = !config.field_minimap
		config_write({{"field", "minimap", config.field_minimap ? "true" : "false"}})
	}
	return held &~ psx.PAD_SELECT
}

@(private)
minimap_vblank :: proc() {
	visible := minimap_visible()
	step: f32 = visible ? 1.0 / FADE_VBLANKS : -1.0 / FADE_VBLANKS
	minimap.shown = clamp(minimap.shown + step, 0, 1)
	t := minimap.shown
	psx.osd_inset_opacity = t * t * (3 - 2 * t) * (1 - screen_fade())
	psx.osd_inset_shown = minimap.shown > 0
	// Fading out keeps the last picture: the grid may be gone by then.
	if !visible {
		return
	}
	psx.osd_inset_at = AT
	paint()
	psx.osd_inset_changed()
}

@(private)
player_control :: proc() -> bool {
	if psx.lw(SLOT_ENGINE) != FLD_MAIN_ID || psx.lhu(GAME_MODE) != GAME_MODE_FIELD {
		return false
	}
	state := psx.lbu(leader_obj() + OBJ_STATE)
	return state == STATE_CONTROL || state == STATE_IDLE
}

@(private = "file")
minimap_visible :: proc() -> bool {
	if !config.field_minimap || psx.lw(SLOT_ENGINE) != FLD_MAIN_ID {
		return false
	}
	mode := psx.lhu(GAME_MODE)
	if mode != GAME_MODE_FIELD && mode != GAME_MODE_TURN {
		return false
	}
	if psx.lbu(HUD_SHOWN) == 0 || psx.lbu(HUD_FLAGS) & 1 != 0 {
		return false
	}
	// The world map is a field mode too, with a map of its own; its grid is
	// the map left. Its encounter scenes (area 0x08 too) are fields proper.
	if on_world_map() {
		return false
	}
	return !tracker_draws() && !psx.osd_panel_shown && !map_editor.on
}

// The leader's layer of the collision grid; ok false when the map block
// does not look loaded.
@(private)
grid_of :: proc(layer: u32) -> (g: Grid, ok: bool) {
	return map_grid(psx.lbu(MAP_SECTION) + layer)
}

// The grid of the map's layer `layer`, counted from the map's first, not the
// section's.
@(private)
map_grid :: proc(layer: u32) -> (g: Grid, ok: bool) {
	blk := psx.lw(MAP_BLOCK)
	if !in_ram(blk) || layer >= psx.lbu(blk + 3) {
		return {}, false
	}
	desc := blk + psx.lw(blk + BLOCK_LAYERS + 4 * layer)
	header := blk + psx.lw(blk + BLOCK_GRIDS + 4 * psx.lbu(desc))
	attrs := blk + psx.lw(blk + BLOCK_ATTRS + 4 * psx.lbu(desc + 1))
	if !in_ram(desc) || !in_ram(header) || !in_ram(attrs) {
		return {}, false
	}
	g = {i32(psx.lhu(header)) * 2, i32(psx.lhu(header + 2)) * 2, attrs}
	return g, in_ram(attrs + u32(g.w * g.h))
}

// How many layers section `section` has, from its first layer descriptor
// as the exe reads it on loading a section (0x80142e00): bits 1-3 of byte 3
// hold the count less one. Only the loaded section's count is kept in RAM
// (0x80138170).
@(private)
section_layers :: proc(section: u32) -> u32 {
	desc := layer_desc(section)
	if desc == 0 {
		return 1
	}
	return min((psx.lbu(desc + 3) & 0xe) >> 1 + 1, psx.lbu(psx.lw(MAP_BLOCK) + 3) - section)
}

// The map block's descriptor of `layer` (as 0x80149728 finds it), 0 when
// there is none.
@(private)
layer_desc :: proc(layer: u32) -> u32 {
	blk := psx.lw(MAP_BLOCK)
	if !in_ram(blk) || layer >= psx.lbu(blk + 3) {
		return 0
	}
	desc := blk + psx.lw(blk + BLOCK_LAYERS + 4 * layer)
	return in_ram(desc) ? desc : 0
}

@(private)
in_ram :: proc(at: u32) -> bool {
	return at >= 0x80000000 && at < 0x80200000
}

// As the exe's lookup: cells are u8 coordinates, outside reads as a wall.
@(private)
attr_at :: proc(g: Grid, x, z: i32) -> u8 {
	if x < 0 || z < 0 || x >= g.w || z >= g.h || x > 0xff || z > 0xff {
		return ATTR_OUTSIDE
	}
	return u8(psx.lbu(g.attrs + u32(z * g.w + x)))
}

@(private = "file")
attr_colour :: proc(attr: u8) -> u32 {
	switch attr >> 4 {
	case 0:
		return COL_FLOOR
	case 0x1:
		return COL_WALL
	case 0xa:
		return COL_EXIT
	case 0x7, 0xc:
		return COL_STAIRS
	}
	return COL_FLOOR
}

// Paint the inset: the grid turned so the camera's facing is up, the rim,
// NPCs, the leader and north.
@(private = "file")
paint :: proc() {
	pix := psx.osd_inset_pixels[:]
	pos := u32(leader_obj() + OBJ_POS)
	g, ok := grid_of(psx.lbu(pos + 12))
	yaw := f64(psx.lhu(CAMERA_YAW)) * (2 * math.PI / 4096)
	cos, sin := math.cos(yaw), math.sin(yaw)
	lx := f64(i32(psx.lw(pos))) / 0x10000
	lz := f64(i32(psx.lw(pos + 8))) / 0x10000
	r := f64(SIZE) / 2

	for v in 0 ..< SIZE {
		for u in 0 ..< SIZE {
			du, dv := f64(u) + 0.5 - r, f64(v) + 0.5 - r
			d := math.sqrt(du * du + dv * dv)
			colour: u32
			switch {
			case d > r:
				colour = 0
			case d > r - RIM:
				colour = COL_RIM
			case !ok:
				colour = COL_WALL
			case:
				// Screen right is world angle yaw + 90, screen up is yaw,
				// with angle a pointing at (sin a, -cos a) in (x, z).
				wx := lx + (du * cos - dv * sin) / PX_PER_CELL
				wz := lz + (du * sin + dv * cos) / PX_PER_CELL
				colour = attr_colour(attr_at(g, i32(math.floor(wx + 0.5)), i32(math.floor(wz + 0.5))))
			}
			pix[v * SIZE + u] = colour
		}
	}

	for i in u32(0) ..< NPC_COUNT {
		npc := NPCS + i * NPC_SIZE
		if psx.lbu(npc) == 0 {
			continue
		}
		nx := f64(i32(psx.lw(npc + OBJ_POS))) / 0x10000 - lx
		nz := f64(i32(psx.lw(npc + OBJ_POS + 8))) / 0x10000 - lz
		// The inverse of the turn above.
		su := (nx * cos + nz * sin) * PX_PER_CELL
		sv := (-nx * sin + nz * cos) * PX_PER_CELL
		if su * su + sv * sv < (r - RIM - 3) * (r - RIM - 3) {
			dot(pix, r + su, r + sv, 2, COL_NPC)
		}
	}

	facing := f64(psx.lbu(leader_obj() + OBJ_DIRECTION) & 7) * (math.PI / 4) - yaw
	arrow(pix, r, r, facing, COL_LEADER)

	north := -yaw
	nr := r - RIM - 6
	psx.osd_put_glyph(pix, SIZE, 'N', int(r + math.sin(north) * nr) - 4, int(r - math.cos(north) * nr) - 4, COL_NORTH)
}

@(private = "file")
dot :: proc(pix: []u32, x, y, radius: f64, colour: u32) {
	for py in int(y - radius) ..= int(y + radius) {
		for px in int(x - radius) ..= int(x + radius) {
			if px >= 0 && py >= 0 && px < SIZE && py < SIZE {
				pix[py * SIZE + px] = colour
			}
		}
	}
}

// A filled triangle at (x, y) pointing at screen angle `angle` (clockwise
// from up).
@(private = "file")
arrow :: proc(pix: []u32, x, y, angle: f64, colour: u32) {
	LEN :: 7.0
	HALF :: 4.5
	fx, fy := math.sin(angle), -math.cos(angle)
	tip := [2]f64{x + fx * LEN, y + fy * LEN}
	left := [2]f64{x - fx * LEN * 0.6 - fy * HALF, y - fy * LEN * 0.6 + fx * HALF}
	right := [2]f64{x - fx * LEN * 0.6 + fy * HALF, y - fy * LEN * 0.6 - fx * HALF}
	for py in int(y - LEN) ..= int(y + LEN) {
		for px in int(x - LEN) ..= int(x + LEN) {
			p := [2]f64{f64(px) + 0.5, f64(py) + 0.5}
			if px >= 0 && py >= 0 && px < SIZE && py < SIZE && inside(p, tip, left, right) {
				pix[py * SIZE + px] = colour
			}
		}
	}
}

@(private = "file")
inside :: proc(p, a, b, c: [2]f64) -> bool {
	side :: proc(p, a, b: [2]f64) -> f64 {
		return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
	}
	s1, s2, s3 := side(p, a, b), side(p, b, c), side(p, c, a)
	return (s1 >= 0 && s2 >= 0 && s3 >= 0) || (s1 <= 0 && s2 <= 0 && s3 <= 0)
}
