// Native ground heights: the game's GROUND core (GROUND_CORE) and its
// helpers rewritten, giving the same heights, scratch words and emulated time.
//
// The GROUND wrappers (sections.odin GROUND, interiors.odin GROUND_HEIGHT and
// one more) load a position into scratch and a layer descriptor, then call
// GROUND_CORE, which looks first through the layer's walkable placed models
// (a box test, then the model's polygons) and then the tile under the
// position: its polygons if it has any, else its heightfield quad. Each path
// charges the instructions the game runs on it, named by their addresses, and
// due interrupts run where the game checks for them, at function entries and
// backward branches, as in map_geometry.odin.
package qol

import cpu "ps:psx/cpu"
import gte "ps:psx/gte"
import io "ps:psx/io"

GROUND_CORE :: 0x8014a9cc // scratch position and layer descriptor: v0 = s16 ground y (units of 1/256), 0 off the grid
GROUND_LIGHT :: 0x801381e9 // u8 brightness of the ground last found, 128 on unlit layers
GRID_LOOKUP :: 0x80149764 // map block +4 table: the layer's tile grid (Layer_Header)
DESC_LOOKUP :: 0x80149728 // map block +0xc4 table: layer descriptors
ATTRS_LOOKUP :: 0x801497a0 // map block +0xa4 table: attribute grids
ATTR_LOOKUP :: 0x801537f0 // (x, z, layer) -> u8 attribute of the cell, 16 (wall) off the grid
ATTR_WRITE :: 0x801538c4 // (x, z, layer, value): store a cell's attribute, unchecked
ATTR_LAYER_BASE :: 0x8011c946 // u8 added to the layer argument: the floor the party is on
ATTR_OFF_GRID :: 16
PASSABLE :: 0x801d60f8 // FLD overlay: (from pos, to pos, flags) -> 1 when the step is allowed
NEXT_POS :: 0x80153a3c // (pos, out, direction, keep height) -> neighbour pos
@(private = "file")
FLD_ID :: 0x0f
@(private = "file")
FIELD_FLAGS :: 0x801172aa // u16: bit 7 walk anywhere, bit 9 0xa4 cells are walls
@(private = "file")
STEP_ANY :: 0x80
@(private = "file")
STEP_A4_WALL :: 0x200
@(private = "file")
PASS_NO_HEIGHT :: 2 // PASSABLE flag: skip the height test
@(private = "file")
STAIR :: 0xc0 // high nibble of a cell that changes layer; low two bits its direction

PLACED_WALK :: 0x08 // a placed model that is ground

// GROUND_CORE's scratch words.
SCG_VERTS :: 0x00 // four 4-byte vertices of the polygon being tested (s8 x, y, z, flags)
SCG_RISE_B :: 0x12 // s16 (b.y - a.y) * 32 of the last triangle
SCG_RISE_C :: 0x1a // s16 (c.y - a.y) * 32
SCG_POS :: 0x28 // s16 x, y, z; x and z moved by 128 to the cell grid
SCG_HEIGHT :: 0x2a // s16 the height found
SCG_LOCAL :: 0x30 // s16 x, y, z: the grid cell, or the position in a model's frame
SCG_FRAC :: 0x38 // s16 x within the cell or model, 0..511
SCG_TRI_Y :: 0x3a // s16 height on the last triangle hit
SCG_FRAC_Z :: 0x3c
SCG_ORIGIN :: 0x40 // s16 x, y, z of the placed model, x and z * 32, y * 16
SCG_COLOURS :: 0x54 // three u32 corner colours, then the lighting results
SCG_LIT :: 0x60 // u16 the layer is lit (descriptor byte 3 bit 0)
SCG_HIT :: 0x64 // u16 the last triangle test hit
SCG_DESC :: 0x68 // u32 layer descriptor: u8 grid, u8, u8 placed model count, u8 flags, then the models
SCG_TILE :: 0x6c // u32 tile under the position, 0 for none
SCG_SLOPE :: 0x70 // s16 heightfield rise along x and z * 32
SCG_REF :: 0x74 // u32 the ground tile's Poly_Ref
SCG_GRID :: 0x78 // u32 Layer_Header
SCG_REF_INDEX :: 0x7c // u16
SCG_ROW :: 0x80 // u32 Map_Row
SCG_PLACED :: 0x84 // u32 next placed model
SCG_MODEL :: 0x88 // the placed model being tested (12 bytes)
SCG_GROUP :: 0x94 // u32 its model group
SCG_BOX :: 0x98 // s16 x0, z0, x1, z1 * 256: the group's bounding box
SCG_PARTS :: 0xa0 // s16 blue, green, red * 8 of the three colours
SCG_XZ :: 0xb4 // s16 x, z of the triangle's three corners
SCG_POINT :: 0xc0 // s16 x, z of the position / 32
SCG_AREAS :: 0xc4 // i32 NCLIP of (p, b, c), (p, c, a), (p, a, b), then (a, b, c)

collision: struct {
	core:       cpu.Func_Proc, // the game's GROUND_CORE
	attr:       cpu.Func_Proc, // ATTR_LOOKUP
	attr_write: cpu.Func_Proc, // ATTR_WRITE
	passable:   cpu.Func_Proc, // PASSABLE
}

collision_init :: proc() -> bool {
	ok: bool
	collision.core = cpu.hook(GROUND_CORE, ground_core) or_return
	collision.attr = cpu.hook(ATTR_LOOKUP, attr_lookup) or_return
	collision.attr_write = cpu.hook(ATTR_WRITE, attr_write) or_return
	collision.passable, ok = cpu.hook_overlay(PASSABLE, SLOT_ENGINE, FLD_ID, passable)
	return ok
}

// The attribute grid holds one byte per half tile: a layer of w x h tiles
// has (w * 2) x (h * 2) cells, row by row.
@(private = "file")
attr_lookup :: proc() {
	if !map_geometry.check {
		cpu.state.r[2] = attr_lookup_native(cpu.state.r[4], cpu.state.r[5], cpu.state.r[6])
		return
	}
	// The game's pass changes the argument registers; the native one reads them
	// as they came in.
	@(static) args: [3]u32
	args = {cpu.state.r[4], cpu.state.r[5], cpu.state.r[6]}
	map_check_draw(collision.attr, proc() {
		cpu.state.r[2] = attr_lookup_native(args[0], args[1], args[2])
	}, nil, "attr", result = true)
}

@(private = "file")
attr_lookup_native :: proc(x, z, layer: u32) -> u32 {
	events()
	spend(0x801537f0, 0x80153824)
	desc := block_entry(DESC_LOOKUP, 3, 0xc4, (u32(cpu.r8(ATTR_LAYER_BASE)) + layer) & 255)
	spend(0x80153828, 0x80153834)
	grid := block_entry(GRID_LOOKUP, 0, 4, u32(cpu.r8(desc)))
	spend(0x80153838, 0x80153850)
	across := u32(cpu.r16(grid)) * 2
	if x & 255 >= across {
		spend(0x801538a0, 0x801538c0)
		return ATTR_OFF_GRID
	}
	spend(0x80153854, 0x80153868)
	if z & 255 >= u32(cpu.r16(grid + 2)) * 2 {
		spend(0x801538a4, 0x801538c0)
		return ATTR_OFF_GRID
	}
	spend(0x8015386c, 0x80153874)
	attrs := block_entry(ATTRS_LOOKUP, 2, 0xa4, u32(cpu.r8(desc + 1)))
	spend(0x80153878, 0x8015389c)
	spend(0x801538a4, 0x801538c0)
	return u32(cpu.r8(attrs + (z & 255) * across + (x & 255)))
}

@(private = "file")
attr_write :: proc() {
	if !map_geometry.check {
		attr_write_native(cpu.state.r[4], cpu.state.r[5], cpu.state.r[6], cpu.state.r[7])
		return
	}
	@(static) args: [4]u32
	args = {cpu.state.r[4], cpu.state.r[5], cpu.state.r[6], cpu.state.r[7]}
	map_check_draw(collision.attr_write, proc() {
		attr_write_native(args[0], args[1], args[2], args[3])
	}, nil, "attr write")
}

@(private = "file")
attr_write_native :: proc(x, z, layer, value: u32) {
	events()
	spend(0x801538c4, 0x801538f8)
	desc := block_entry(DESC_LOOKUP, 3, 0xc4, (u32(cpu.r8(ATTR_LAYER_BASE)) + layer) & 255)
	spend(0x801538fc, 0x80153908)
	grid := block_entry(GRID_LOOKUP, 0, 4, u32(cpu.r8(desc)))
	spend(0x8015390c, 0x80153914)
	attrs := block_entry(ATTRS_LOOKUP, 2, 0xa4, u32(cpu.r8(desc + 1)))
	spend(0x80153918, 0x80153954)
	cpu.w8(attrs + (z & 255) * u32(cpu.r16(grid)) * 2 + (x & 255), u8(value))
}

@(private = "file")
ground_core :: proc() {
	if !map_geometry.check {
		cpu.state.r[2] = u32(ground_core_native())
		return
	}
	@(static) everything: [cpu.SCRATCH_SIZE]u32
	if everything[1] == 0 {
		for &o, i in everything {
			o = u32(i)
		}
	}
	map_check_draw(collision.core, proc() {cpu.state.r[2] = u32(ground_core_native())}, everything[:], "ground", result = true)
}

// The ground under cell (x, z) of section `desc` (a layer descriptor), as
// GROUND finds it for an object standing there, in its s16 units (a cell is
// 256), 0 off the grid. Leaves no trace: scratch, GTE, the light byte, the
// emulated clock and the pending interrupts are as they were.
@(private)
ground_probe :: proc(desc: u32, x, z: i32) -> i32 {
	@(static) scratch: [cpu.SCRATCH_SIZE]u8
	scratch = cpu.scratch
	saved_gte := gte.gte_save()
	light := cpu.r8(GROUND_LIGHT)
	cycles, next := cpu.state.cycles, cpu.next_event
	cpu.next_event = io.EVENT_OFF
	sc_w16(SCG_POS, u16(i16(x << 8)))
	sc_w16(SCG_POS + 2, 0)
	sc_w16(SCG_POS + 4, u16(i16(z << 8)))
	cpu.w32(cpu.SCRATCH_BASE + SCG_DESC, desc)
	y := ground_core_native()
	cpu.scratch = scratch
	gte.gte_load(saved_gte)
	cpu.w8(GROUND_LIGHT, light)
	cpu.state.cycles, cpu.next_event = cycles, next
	return y
}

@(private = "file")
sc_s16 :: #force_inline proc(o: u32) -> i32 {return i32(i16(sc_u16(o)))}

@(private = "file")
ram_s8 :: #force_inline proc(addr: u32) -> i32 {return i32(i8(cpu.r8(addr)))}

@(private = "file")
ground_core_native :: proc() -> i32 {
	sc := &cpu.scratch
	events()
	desc := sc_u32(SCG_DESC)
	sc_w16(SCG_LIT, u16(cpu.r8(desc + 3) & 1))
	spend(0x8014a9cc, 0x8014aa04)
	grid := block_entry(GRID_LOOKUP, 0, 4, u32(cpu.r8(desc)))
	spend(0x8014aa08, 0x8014aa3c)
	sc_w32(SCG_GRID, grid)
	sc_w16(SCG_POS, sc_u16(SCG_POS) + 128)
	sc_w16(SCG_POS + 4, sc_u16(SCG_POS + 4) + 128)
	sc_w32(SCG_PLACED, desc + 4)
	if cpu.r8(desc + 2) != 0 {
		i: u32 = 0
		for {
			spend(0x8014aa40, 0x8014aa58)
			at := sc_u32(SCG_PLACED)
			if cpu.r8(at + 2) & PLACED_WALK != 0 && ground_model(at) {
				spend(0x8014b074, 0x8014b098)
				return sc_s16(SCG_HEIGHT)
			}
			spend(0x8014aef0, 0x8014af14)
			i += 1
			sc_w32(SCG_PLACED, at + 12)
			if i & 255 >= u32(cpu.r8(sc_u32(SCG_DESC) + 2)) {
				break
			}
			events()
		}
	}
	spend(0x8014af18, 0x8014af20)
	spend(0x8014af24, 0x8014af74)
	col := u16(i16(sc_u16(SCG_POS)) >> 9)
	row := u16(i16(sc_u16(SCG_POS + 4)) >> 9)
	sc_w16(SCG_LOCAL, col)
	sc_w16(SCG_LOCAL + 4, row)
	sc_w16(SCG_FRAC, sc_u16(SCG_POS) & 511)
	sc_w16(SCG_FRAC_Z, sc_u16(SCG_POS + 4) & 511)
	if col >= cpu.r16(grid) {
		spend(0x8014b084, 0x8014b098)
		return 0
	}
	spend(0x8014af78, 0x8014af8c)
	if row >= cpu.r16(grid + 2) {
		spend(0x8014b06c, 0x8014b070)
		spend(0x8014b084, 0x8014b098)
		return 0
	}
	spend(0x8014af90, 0x8014afbc)
	row_at := grid + cpu.r32(grid + 4) + u32(i32(i16(row)) << 2)
	sc_w32(SCG_ROW, row_at)
	first := i32(cpu.r8(row_at))
	x := i32(i16(col))
	tile: u32
	if x < first {
		spend(0x8014b008, 0x8014b018)
	} else {
		spend(0x8014afc0, 0x8014afd4)
		if x < first + i32(cpu.r8(row_at + 1)) {
			spend(0x8014afd8, 0x8014b004)
			spend(0x8014b00c, 0x8014b018)
			tile = grid + cpu.r32(grid + 8) + u32(cpu.r16(row_at + 2)) << 4 + u32(x) << 4 - u32(first) << 4
		} else {
			spend(0x8014b008, 0x8014b018)
		}
	}
	sc_w32(SCG_TILE, tile)
	if tile == 0 {
		spend(0x8014b060, 0x8014b070)
		spend(0x8014b084, 0x8014b098)
		return 0
	}
	spend(0x8014b01c, 0x8014b028)
	hit := tile_polys()
	spend(0x8014b02c, 0x8014b038)
	if hit {
		spend(0x8014b074, 0x8014b098)
		return sc_s16(SCG_HEIGHT)
	}
	spend(0x8014b03c, 0x8014b054)
	if cpu.r8(sc_u32(SCG_TILE)) & TILE_GROUND == 0 {
		spend(0x8014b064, 0x8014b070)
		spend(0x8014b084, 0x8014b098)
		return 0
	}
	spend(0x8014b058, 0x8014b05c)
	heightfield()
	spend(0x8014b060, 0x8014b068)
	spend(0x8014b074, 0x8014b098)
	return sc_s16(SCG_HEIGHT)
}

// One walkable placed model: its box, then its polygons. The game tests the
// turn cases one after another, so a model whose box test fails still pays
// for the later cases' turn compares.
@(private = "file")
ground_model :: proc(at: u32) -> bool {
	sc := &cpu.scratch
	spend(0x8014aa5c, 0x8014aa94)
	for i in u32(0) ..< 12 {
		sc[SCG_MODEL + i] = cpu.r8(at + i)
	}
	group := block_entry(0x801497dc, 1, 0x24, u32(sc[SCG_MODEL]))
	spend(0x8014aa98, 0x8014ab10)
	sc_w32(SCG_GROUP, group)
	for i in u32(0) ..< 4 {
		sc_w16(SCG_BOX + 2 * i, u16(i16(i8(cpu.r8(group + 4 + i)))) << 8)
	}
	sc_w16(SCG_ORIGIN, sc_u16(SCG_MODEL + 4) << 5)
	sc_w16(SCG_ORIGIN + 2, sc_u16(SCG_MODEL + 6) << 4)
	sc_w16(SCG_ORIGIN + 4, sc_u16(SCG_MODEL + 8) << 5)
	turn := sc[SCG_MODEL + 2] & PLACED_TURN
	x, z := sc_s16(SCG_POS), sc_s16(SCG_POS + 4)
	ox, oz := sc_s16(SCG_ORIGIN), sc_s16(SCG_ORIGIN + 4)
	b0, b1 := sc_s16(SCG_BOX), sc_s16(SCG_BOX + 2)
	b2, b3 := sc_s16(SCG_BOX + 4), sc_s16(SCG_BOX + 6)
	px, py, pz := sc_u16(SCG_POS), sc_u16(SCG_POS + 2), sc_u16(SCG_POS + 4)
	ux, uz := sc_u16(SCG_ORIGIN), sc_u16(SCG_ORIGIN + 4)
	inside: bool
	if turn == 0 {
		spend(0x8014ab14, 0x8014ab44)
		if x >= ox + b0 {
			spend(0x8014ab48, 0x8014ab64)
			if x < ox + b2 {
				spend(0x8014ab68, 0x8014ab94)
				if z >= oz + b1 {
					spend(0x8014ab98, 0x8014abb4)
					inside = z < oz + b3
				}
			}
		}
		if inside {
			spend(0x8014abb8, 0x8014abe0)
			for i in u32(0) ..< 8 {
				sc[SCG_LOCAL + i] = sc[SCG_POS + i]
			}
			hit := model_polys(cpu.SCRATCH_BASE + SCG_MODEL, group)
			spend(0x8014abe4, 0x8014abf0)
			if hit {
				return true
			}
		}
	}
	spend(0x8014abf4, 0x8014ac04)
	if turn == 1 {
		spend(0x8014ac08, 0x8014ac38)
		if x >= ox + b1 {
			spend(0x8014ac3c, 0x8014ac58)
			if x < ox + b3 {
				spend(0x8014ac5c, 0x8014ac8c)
				if z >= oz - b2 {
					spend(0x8014ac90, 0x8014acac)
					inside = z < oz - b0
				}
			}
		}
		if inside {
			spend(0x8014acb0, 0x8014ace0)
			sc_w16(SCG_LOCAL, ux + uz - pz)
			sc_w16(SCG_LOCAL + 2, py)
			sc_w16(SCG_LOCAL + 4, uz + px - ux)
			hit := model_polys(cpu.SCRATCH_BASE + SCG_MODEL, group)
			spend(0x8014ace4, 0x8014acf0)
			if hit {
				return true
			}
		}
	}
	spend(0x8014acf4, 0x8014ad04)
	if turn == 2 {
		spend(0x8014ad08, 0x8014ad38)
		if x >= ox - b2 {
			spend(0x8014ad3c, 0x8014ad58)
			if x < ox - b0 {
				spend(0x8014ad5c, 0x8014ad8c)
				if z >= oz - b3 {
					spend(0x8014ad90, 0x8014adac)
					inside = z < oz - b1
				}
			}
		}
		if inside {
			spend(0x8014adb0, 0x8014addc)
			sc_w16(SCG_LOCAL, ux + ux - px)
			sc_w16(SCG_LOCAL + 2, py)
			sc_w16(SCG_LOCAL + 4, uz + uz - pz)
			hit := model_polys(cpu.SCRATCH_BASE + SCG_MODEL, group)
			spend(0x8014ade0, 0x8014adec)
			if hit {
				return true
			}
		}
	}
	spend(0x8014adf0, 0x8014ae00)
	if turn == 3 {
		spend(0x8014ae04, 0x8014ae34)
		if x >= ox - b3 {
			spend(0x8014ae38, 0x8014ae54)
			if x < ox - b1 {
				spend(0x8014ae58, 0x8014ae88)
				if z >= oz + b0 {
					spend(0x8014ae8c, 0x8014aea8)
					inside = z < oz + b2
				}
			}
		}
		if inside {
			spend(0x8014aeac, 0x8014aedc)
			sc_w16(SCG_LOCAL, ux + pz - uz)
			sc_w16(SCG_LOCAL + 2, py)
			sc_w16(SCG_LOCAL + 4, uz + ux - px)
			hit := model_polys(cpu.SCRATCH_BASE + SCG_MODEL, group)
			spend(0x8014aee0, 0x8014aeec)
			if hit {
				return true
			}
		}
	}
	return false
}

// 0x8014b6a8: the placed model's polygons (24 bytes each from group + 8, the
// count at group + 2) under SCG_LOCAL; a hit sets SCG_HEIGHT.
@(private = "file")
model_polys :: proc(placed, group: u32) -> bool {
	sc := &cpu.scratch
	events()
	spend(0x8014b6a8, 0x8014b710)
	sc_w16(SCG_FRAC, sc_u16(SCG_LOCAL) - cpu.r16(placed + 4) << 5)
	sc_w16(SCG_FRAC_Z, sc_u16(SCG_LOCAL + 4) - cpu.r16(placed + 8) << 5)
	if cpu.r16(group + 2) == 0 {
		spend(0x8014b7e8, 0x8014b810)
		return false
	}
	spend(0x8014b714, 0x8014b718)
	GREY :: 0x4210
	poly := group + 8
	i: u16 = 0
	for {
		spend(0x8014b71c, 0x8014b738)
		sc_w32(SCG_VERTS + 4, cpu.r32(poly + 4))
		sc_w32(SCG_COLOURS + 4, GREY)
		hit := false
		if sc[SCG_VERTS + 7] & 1 == 0 {
			spend(0x8014b73c, 0x8014b760)
			sc_w32(SCG_COLOURS, GREY)
			sc_w32(SCG_VERTS, cpu.r32(poly))
			sc_w32(SCG_COLOURS + 8, GREY)
			sc_w32(SCG_VERTS + 8, cpu.r32(poly + 8))
			triangle(SCG_VERTS, SCG_VERTS + 4, SCG_VERTS + 8)
			spend(0x8014b764, 0x8014b770)
			hit = sc_u16(SCG_HIT) != 0
		}
		if !hit {
			spend(0x8014b774, 0x8014b784)
			if sc[SCG_VERTS + 7] & 2 == 0 {
				spend(0x8014b788, 0x8014b7a4)
				sc_w32(SCG_COLOURS, GREY)
				sc_w32(SCG_COLOURS + 4, GREY)
				sc_w32(SCG_COLOURS + 8, GREY)
				sc_w32(SCG_VERTS + 12, cpu.r32(poly + 12))
				triangle(SCG_VERTS + 12, SCG_VERTS + 8, SCG_VERTS + 4)
				spend(0x8014b7a8, 0x8014b7b4)
				hit = sc_u16(SCG_HIT) != 0
			}
		}
		if hit {
			spend(0x8014b7b8, 0x8014b7cc)
			sc_w16(SCG_HEIGHT, sc_u16(SCG_TRI_Y) + cpu.r16(placed + 6) << 5)
			spend(0x8014b7ec, 0x8014b810)
			return true
		}
		spend(0x8014b7d0, 0x8014b7e4)
		i += 1
		poly += 24
		if i >= cpu.r16(group + 2) {
			break
		}
		events()
	}
	spend(0x8014b7e8, 0x8014b810)
	return false
}

// 0x8014b09c: the tile's polygons. Ground tiles name theirs through a
// Poly_Ref; other tiles carry the count and first polygon. The first
// triangle above the running SCG_HEIGHT (from -32768) ends the search.
@(private = "file")
tile_polys :: proc() -> bool {
	sc := &cpu.scratch
	events()
	sc_w16(SCG_HIT, 0)
	sc_w16(SCG_HEIGHT, 0x8000)
	spend(0x8014b09c, 0x8014b0d4)
	grid := block_entry(GRID_LOOKUP, 0, 4, u32(cpu.r8(sc_u32(SCG_DESC))))
	spend(0x8014b0d8, 0x8014b0f4)
	sc_w32(SCG_GRID, grid)
	tile := sc_u32(SCG_TILE)
	count: u32
	poly: u32
	if cpu.r8(tile) & TILE_GROUND != 0 {
		spend(0x8014b0f8, 0x8014b114)
		index := u16(cpu.r8(tile + 1)) + u16(cpu.r8(tile + 2) & 0xc0) << 2
		sc_w16(SCG_REF_INDEX, index)
		if index == REF_NONE {
			spend(0x8014b14c, 0x8014b158)
			poly = grid + cpu.r32(grid + 16)
		} else {
			spend(0x8014b118, 0x8014b148)
			ref := grid + cpu.r32(grid + 12) + u32(index) * 4
			sc_w32(SCG_REF, ref)
			count = u32(cpu.r16(ref))
			poly = grid + cpu.r32(grid + 16) + u32(cpu.r16(ref + 2)) << 5
		}
	} else {
		spend(0x8014b170, 0x8014b188)
		poly = grid + cpu.r32(grid + 16) + u32(cpu.r16(tile + 2)) << 5
		count = u32(cpu.r16(tile)) >> 1
	}
	spend(0x8014b18c, 0x8014b190)
	if count != 0 {
		spend(0x8014b194, 0x8014b194)
		i: u32 = 0
		for {
			spend(0x8014b198, 0x8014b1b4)
			sc_w32(SCG_VERTS + 4, cpu.r32(poly + 4))
			flags := sc[SCG_VERTS + 7]
			if flags & 4 == 0 {
				spend(0x8014b1b8, 0x8014b1bc)
				if flags & 1 == 0 && tile_poly(poly) {
					events()
					spend(0x8014b15c, 0x8014b16c)
					sc_w16(SCG_HIT, 1)
					sc_w16(SCG_HEIGHT, sc_u16(SCG_TRI_Y))
					break
				}
			}
			spend(0x8014b2a0, 0x8014b2b0)
			i += 1
			poly += 32
			if i >= count {
				break
			}
			events()
		}
	}
	spend(0x8014b2b4, 0x8014b2dc)
	return sc_u16(SCG_HIT) != 0
}

// Both triangles of one tile polygon; true when one is above SCG_HEIGHT.
@(private = "file")
tile_poly :: proc(poly: u32) -> bool {
	sc := &cpu.scratch
	spend(0x8014b1c0, 0x8014b1fc)
	sc_w32(SCG_COLOURS, u32(cpu.r16(poly + 0x18)))
	sc_w32(SCG_COLOURS + 4, u32(cpu.r16(poly + 0x1a)))
	sc_w32(SCG_COLOURS + 8, u32(cpu.r16(poly + 0x1c)))
	sc_w32(SCG_VERTS, cpu.r32(poly))
	sc_w32(SCG_VERTS + 8, cpu.r32(poly + 8))
	triangle(SCG_VERTS, SCG_VERTS + 4, SCG_VERTS + 8)
	spend(0x8014b200, 0x8014b20c)
	if sc_u16(SCG_HIT) != 0 {
		spend(0x8014b210, 0x8014b228)
		if sc_s16(SCG_HEIGHT) < sc_s16(SCG_TRI_Y) {
			return true
		}
	}
	spend(0x8014b22c, 0x8014b23c)
	if sc[SCG_VERTS + 7] & 2 != 0 {
		return false
	}
	spend(0x8014b240, 0x8014b270)
	sc_w32(SCG_COLOURS, u32(cpu.r16(poly + 0x1e)))
	sc_w32(SCG_COLOURS + 4, u32(cpu.r16(poly + 0x1a)))
	sc_w32(SCG_COLOURS + 8, u32(cpu.r16(poly + 0x1c)))
	sc_w32(SCG_VERTS + 12, cpu.r32(poly + 12))
	triangle(SCG_VERTS + 12, SCG_VERTS + 8, SCG_VERTS + 4)
	spend(0x8014b274, 0x8014b280)
	if sc_u16(SCG_HIT) != 0 {
		spend(0x8014b284, 0x8014b29c)
		return sc_s16(SCG_HEIGHT) < sc_s16(SCG_TRI_Y)
	}
	return false
}

// 0x8014b2e0: is the point SCG_FRAC / 32 inside the triangle of the scratch
// vertices a, b, c seen from above (GTE NCLIP signs, the corners clockwise),
// and at what height; on lit layers also the light there, from the colours
// at SCG_COLOURS. Sets SCG_HIT.
@(private = "file")
triangle :: proc(a, b, c: u32) {
	sc := &cpu.scratch
	events()
	sc_w16(SCG_XZ, u16(i16(i8(sc[a]))))
	sc_w16(SCG_XZ + 2, u16(i16(i8(sc[a + 2]))))
	sc_w16(SCG_XZ + 4, u16(i16(i8(sc[b]))))
	sc_w16(SCG_XZ + 6, u16(i16(i8(sc[b + 2]))))
	sc_w16(SCG_XZ + 8, u16(i16(i8(sc[c]))))
	sc_w16(SCG_XZ + 10, u16(i16(i8(sc[c + 2]))))
	pa, pb, pc := sc_u32(SCG_XZ), sc_u32(SCG_XZ + 4), sc_u32(SCG_XZ + 8)
	area := proc(s0, s1, s2: u32) -> i32 {
		gte.data_write(12, s0)
		gte.data_write(14, s2)
		gte.data_write(13, s1)
		gte.cmd_nclip()
		return i32(gte.data_read(24))
	}
	whole := area(pa, pb, pc)
	sc_w32(SCG_AREAS + 12, u32(whole))
	if whole <= 0 {
		spend(0x8014b2e0, 0x8014b398)
		sc_w16(SCG_HIT, 0)
		return
	}
	spend(0x8014b2e0, 0x8014b390)
	spend(0x8014b39c, 0x8014b3fc)
	sc_w16(SCG_POINT, u16(i16(sc_u16(SCG_FRAC)) >> 5))
	sc_w16(SCG_POINT + 2, u16(i16(sc_u16(SCG_FRAC_Z)) >> 5))
	p := sc_u32(SCG_POINT)
	miss :: proc() {
		events()
		spend(0x8014b394, 0x8014b398)
		sc_w16(SCG_HIT, 0)
	}
	wa := area(p, pb, pc)
	sc_w32(SCG_AREAS, u32(wa))
	if wa < 0 {
		miss()
		return
	}
	spend(0x8014b400, 0x8014b43c)
	wb := area(p, pc, pa)
	sc_w32(SCG_AREAS + 4, u32(wb))
	if wb < 0 {
		miss()
		return
	}
	spend(0x8014b440, 0x8014b47c)
	wc := area(p, pa, pb)
	sc_w32(SCG_AREAS + 8, u32(wc))
	if wc < 0 {
		miss()
		return
	}
	spend(0x8014b480, 0x8014b4f4)
	spend(0x8014b4fc, 0x8014b504)
	spend(0x8014b514, 0x8014b538)
	ay := i32(i8(sc[a + 1]))
	rise_b := i32(i8(sc[b + 1])) - ay
	rise_c := i32(i8(sc[c + 1])) - ay
	sc_w16(SCG_RISE_B, u16(rise_b << 5))
	sc_w16(SCG_RISE_C, u16(rise_c << 5))
	y := (wb * i32(i16(rise_b << 5)) + wc * i32(i16(rise_c << 5))) / whole + ay << 5
	sc_w16(SCG_TRI_Y, u16(y))
	if sc_u16(SCG_LIT) == 0 {
		spend(0x8014b690, 0x8014b6a4)
		cpu.w8(GROUND_LIGHT, 128)
	} else {
		spend(0x8014b53c, 0x8014b640)
		spend(0x8014b648, 0x8014b650)
		spend(0x8014b660, 0x8014b68c)
		spend(0x8014b69c, 0x8014b6a4)
		l := colour_levels()
		light := l[0] + (wb * (l[1] - l[0]) + wc * (l[2] - l[0])) / whole
		ground_light(l, light)
	}
	sc_w16(SCG_HIT, 1)
}

// The three SCG_COLOURS split into SCG_PARTS and their levels,
// (blue + 2 green + red) / 4 at 8 bits each.
@(private = "file")
colour_levels :: proc() -> (l: [3]i32) {
	for i in u32(0) ..< 3 {
		c := sc_u32(SCG_COLOURS + 4 * i)
		blue, green, red := u16((c & 0x7c00) >> 7), u16((c & 0x3e0) >> 2), u16((c & 31) << 3)
		sc_w16(SCG_PARTS + 6 * i, blue)
		sc_w16(SCG_PARTS + 6 * i + 2, green)
		sc_w16(SCG_PARTS + 6 * i + 4, red)
		l[i] = (i32(blue) + 2 * i32(green) + i32(red)) >> 2
	}
	return
}

// The lighting words the game leaves and the light byte.
@(private = "file")
ground_light :: proc(l: [3]i32, light: i32) {
	sc_w32(SCG_COLOURS, u32(light))
	sc_w32(SCG_COLOURS + 4, u32(l[1] - l[0]))
	sc_w32(SCG_COLOURS + 8, u32(l[2] - l[0]))
	cpu.w8(GROUND_LIGHT, u8(light))
}

// 0x8014b89c: the ground tile's heightfield quad, split along the diagonal
// from (x+1, z) to (x, z+1): heights from its nearer three corners.
@(private = "file")
heightfield :: proc() {
	events()
	dx, dz := sc_s16(SCG_FRAC), sc_s16(SCG_FRAC_Z)
	tile := sc_u32(SCG_TILE)
	h := [4]i32{ram_s8(tile + 4), ram_s8(tile + 5), ram_s8(tile + 6), ram_s8(tile + 7)}
	near := dx + dz < 512
	base, wx, wz := h[0], dx, dz
	colours := [3]u32{8, 10, 12}
	if !near {
		base, wx, wz = h[3], 512 - dz, 512 - dx
		colours[0] = 14
	}
	rise_x, rise_z := h[1] - base, h[2] - base
	sc_w16(SCG_SLOPE, u16(rise_x << 5))
	sc_w16(SCG_SLOPE + 2, u16(rise_z << 5))
	y := (i32(i16(rise_x << 5)) * wx + i32(i16(rise_z << 5)) * wz) >> 9 + base << 5
	sc_w16(SCG_HEIGHT, u16(y))
	lit := sc_u16(SCG_LIT) != 0
	if near {
		spend(0x8014b89c, lit ? 0x8014ba90 : 0x8014b958)
	} else {
		spend(0x8014b89c, 0x8014b8c4)
		spend(0x8014ba94, lit ? 0x8014bc28 : 0x8014bb28)
		if lit {
			events()
			spend(0x8014ba58, 0x8014ba90)
		}
	}
	if !lit {
		spend(0x8014bc2c, 0x8014bc38)
		cpu.w8(GROUND_LIGHT, 128)
		return
	}
	for i in u32(0) ..< 3 {
		sc_w32(SCG_COLOURS + 4 * i, u32(cpu.r16(tile + colours[i])))
	}
	l := colour_levels()
	ground_light(l, ((l[1] - l[0]) * wx + (l[2] - l[0]) * wz) >> 9 + l[0])
}

// ---------------------------------------------------------------- steps

// PASSABLE: whether an object may step from one cell to a neighbour. The
// destination's attribute must not block (edge_open); a diagonal step must
// also clear the two cells it cuts across (corner_open), each tested against
// the layer it is on, which for a stair cell depends on the stair's
// direction. Unless the flags say otherwise, the ground on both ends of each
// leg may differ by at most one unit (heights_meet).
@(private = "file")
passable :: proc() {
	c := &cpu.state
	@(static) args: [5]u32 // from, to, flags and the caller's $sp and $ra
	args = {c.r[4], c.r[5], c.r[6], c.r[29], c.r[31]}
	// The GROUND and NEXT_POS calls inside leave $sp and $ra at their frames.
	run :: proc() {
		c := &cpu.state
		c.r[29] = args[3]
		c.r[2] = passable_native(args[0], args[1], args[2]) ? 1 : 0
		c.r[29], c.r[31] = args[3], args[4]
	}
	if !map_geometry.check {
		run()
		return
	}
	map_check_draw(collision.passable, run, nil, "passable", result = true, stack = 0x400)
}

@(private = "file")
passable_native :: proc(from, to, flags: u32) -> bool {
	events()
	c := &cpu.state
	sp := c.r[29]
	cpu.w32(sp, from) // the game keeps a0 in its argument slot
	frame := sp - 104
	allow :: proc() -> bool {
		spend(0x801d64c8, 0x801d64f8)
		return true
	}
	refuse :: proc() -> bool {
		spend(0x801d61b8, 0x801d61bc)
		spend(0x801d64cc, 0x801d64f8)
		return false
	}
	leave :: proc(ok: bool) -> bool {
		spend(0x801d64cc, 0x801d64f8)
		return ok
	}
	spend(0x801d60f8, 0x801d6140)
	if cpu.r16(FIELD_FLAGS) & STEP_ANY != 0 {
		return allow()
	}
	fx, fz := i32(i16(cpu.r16(from + 2))), i32(i16(cpu.r16(from + 10)))
	tx, tz := i32(i16(cpu.r16(to + 2))), i32(i16(cpu.r16(to + 10)))
	from_layer, to_layer := u32(cpu.r8(from + 12)), u32(cpu.r8(to + 12))
	spend(0x801d6144, 0x801d617c)
	a := attr_lookup_native(u32(fx), u32(fz), from_layer)
	spend(0x801d6180, 0x801d6198)
	b := attr_lookup_native(u32(tx), u32(tz), to_layer)
	spend(0x801d619c, 0x801d61ac)
	if b == 0x11 {
		return refuse()
	}
	spend(0x801d61b0, 0x801d61b4)
	if b == 0xf0 {
		return refuse()
	}
	spend(0x801d61c0, 0x801d61c4)
	if b == 0xf1 {
		return refuse()
	}
	spend(0x801d61c8, 0x801d61cc)
	if b == 0xf2 {
		return refuse()
	}
	spend(0x801d61d0, 0x801d61d4)
	open := edge_open(a, b)
	spend(0x801d61d8, 0x801d61e0)
	if !open {
		return leave(false)
	}
	spend(0x801d61e4, 0x801d61f4)
	if flags & PASS_NO_HEIGHT == 0 {
		spend(0x801d61f8, 0x801d6218)
		meet := heights_meet(frame, fx, fz, from_layer, tx, tz, to_layer)
		spend(0x801d621c, 0x801d6224)
		if !meet {
			return refuse()
		}
	}
	spend(0x801d6228, 0x801d6238)
	if fx == tx {
		return allow()
	}
	spend(0x801d623c, 0x801d6250)
	if fz == tz {
		return allow()
	}
	spend(0x801d6254, 0x801d625c)

	// A diagonal: first the cell at (fx, tz), then (tx, fz).
	if a & 0xf0 != STAIR {
		spend(0x801d6260, 0x801d6268)
		side := attr_lookup_native(u32(fx), u32(tz), to_layer)
		spend(0x801d626c, 0x801d627c)
		open = corner_open(a, b, side)
		spend(0x801d6280, 0x801d6288)
		if !open {
			return refuse()
		}
		spend(0x801d628c, 0x801d6290)
		if flags & PASS_NO_HEIGHT == 0 {
			spend(0x801d6294, 0x801d62b4)
			meet := heights_meet(frame, fx, fz, from_layer, fx, tz, to_layer)
			spend(0x801d62b8, 0x801d62c0)
			if !meet {
				return leave(false)
			}
		}
		spend(0x801d62c4, 0x801d62d0)
		side = attr_lookup_native(u32(tx), u32(fz), to_layer)
		spend(0x801d62d4, 0x801d62e4)
		open = corner_open(a, b, side)
		spend(0x801d62e8, 0x801d62f0)
		if !open {
			return refuse()
		}
		spend(0x801d62f4, 0x801d62f8)
		if flags & PASS_NO_HEIGHT != 0 {
			return leave(true)
		}
		spend(0x801d62fc, 0x801d632c)
		meet := heights_meet(frame, fx, fz, from_layer, tx, fz, to_layer)
		spend(0x801d6330, 0x801d6338)
		if meet {
			return leave(true)
		}
		spend(0x801d633c, 0x801d6340)
		return leave(false)
	}

	// Leaving a stair: a side cell is on the destination's layer when it is
	// the cell the stair leads to, else on the stair's own.
	spend(0x801d6344, 0x801d6358)
	out := frame + 24
	c.r[29] = frame
	c.r[4], c.r[5], c.r[6], c.r[7] = from, out, (a & 3) * 2, 0
	game_call(NEXT_POS, 0x801d635c)
	c.r[29] = sp
	spend(0x801d635c, 0x801d6370)
	layer := from_layer
	if cpu.r32(out) == cpu.r32(from) {
		spend(0x801d6374, 0x801d6384)
		if cpu.r32(to + 8) == cpu.r32(out + 8) {
			spend(0x801d6388, 0x801d6390)
			layer = to_layer
		} else {
			spend(0x801d6394, 0x801d639c)
		}
	} else {
		spend(0x801d6394, 0x801d639c)
	}
	spend(0x801d63a0, 0x801d63a8)
	side := attr_lookup_native(u32(fx), u32(tz), layer)
	spend(0x801d63ac, 0x801d63bc)
	open = corner_open(a, b, side)
	spend(0x801d63c0, 0x801d63c8)
	if !open {
		return refuse()
	}
	spend(0x801d63cc, 0x801d63d0)
	if flags & PASS_NO_HEIGHT == 0 {
		spend(0x801d63d4, 0x801d63fc)
		meet := heights_meet(frame, fx, fz, from_layer, fx, tz, layer)
		spend(0x801d6400, 0x801d6408)
		if !meet {
			return leave(false)
		}
	}
	spend(0x801d640c, 0x801d641c)
	layer = from_layer
	if cpu.r32(to) != cpu.r32(out) {
		spend(0x801d6448, 0x801d6458)
	} else {
		spend(0x801d6420, 0x801d6438)
		if cpu.r32(from + 8) != cpu.r32(out + 8) {
			spend(0x801d644c, 0x801d6458)
		} else {
			spend(0x801d643c, 0x801d6444)
			layer = to_layer
		}
	}
	spend(0x801d645c, 0x801d6464)
	side = attr_lookup_native(u32(tx), u32(fz), layer)
	spend(0x801d6468, 0x801d6478)
	open = corner_open(a, b, side)
	spend(0x801d647c, 0x801d6484)
	if !open {
		return refuse()
	}
	spend(0x801d6488, 0x801d648c)
	if flags & PASS_NO_HEIGHT != 0 {
		return allow()
	}
	spend(0x801d6490, 0x801d64b8)
	meet := heights_meet(frame, fx, fz, from_layer, tx, fz, layer)
	spend(0x801d64bc, 0x801d64c4)
	if !meet {
		return leave(false)
	}
	return allow()
}

// A pair of attributes that may not meet across a step: the first cell's
// (masked) against the second's. The one-way ramp edges (0x2b..0x2f against
// their 0x?0 cells, 0xa3 against 0x7?) appear in both orders.
@(private = "file")
Edge_Rule :: struct {
	a_mask, a, b_mask, b: u32,
	test, hit, next:      u32, // addresses of the rule's test, its match block and the next rule
}

// 0x801d5c74: whether a step from attribute a onto attribute b is open.
@(private = "file")
edge_open :: proc(a, b: u32) -> bool {
	@(static, rodata) rules := [?]Edge_Rule {
		{0xff, 0x2f, 0xf0, 0xa0, 0x801d5ce8, 0x801d5cf4, 0x801d5d08},
		{0xff, 0x2e, 0xf0, 0xb0, 0x801d5d08, 0x801d5d10, 0x801d5d20},
		{0xff, 0x2d, 0xf0, 0x70, 0x801d5d20, 0x801d5d2c, 0x801d5d3c},
		{0xff, 0x2c, 0xf0, 0xe0, 0x801d5d3c, 0x801d5d48, 0x801d5d58},
		{0xff, 0x2b, 0xf0, 0xc0, 0x801d5d58, 0x801d5d64, 0x801d5d74},
		{0xff, 0xa3, 0xf0, 0x70, 0x801d5d74, 0x801d5d80, 0x801d5d90},
		{0xf0, 0xa0, 0xff, 0x2f, 0x801d5d90, 0x801d5d9c, 0x801d5dac},
		{0xf0, 0xb0, 0xff, 0x2e, 0x801d5dac, 0x801d5db8, 0x801d5dc8},
		{0xf0, 0xe0, 0xff, 0x2c, 0x801d5dc8, 0x801d5dd4, 0x801d5de4},
		{0xf0, 0xc0, 0xff, 0x2b, 0x801d5de4, 0x801d5df0, 0x801d5e00},
	}
	shut :: proc() -> bool {
		spend(0x801d5e44, 0x801d5e48)
		return false
	}
	events()
	// Cells nothing steps onto.
	spend(0x801d5c74, 0x801d5c84)
	if b == 0x10 {
		return shut()
	}
	spend(0x801d5c88, 0x801d5c8c)
	if b == 0x12 {
		return shut()
	}
	spend(0x801d5c90, 0x801d5c94)
	if b == 0x13 {
		return shut()
	}
	spend(0x801d5c98, 0x801d5c9c)
	if b == 0x30 {
		return shut()
	}
	spend(0x801d5ca0, 0x801d5ca4)
	if b & 0xf0 == 0x40 {
		return shut()
	}
	spend(0x801d5ca8, 0x801d5cac)
	if b == 0x50 {
		return shut()
	}
	spend(0x801d5cb0, 0x801d5cb4)
	if b == 0xa3 {
		return shut()
	}
	spend(0x801d5cb8, 0x801d5ccc)
	if cpu.r16(FIELD_FLAGS) & STEP_A4_WALL != 0 {
		spend(0x801d5cd0, 0x801d5cd4)
		if b == 0xa4 {
			return shut()
		}
	}
	spend(0x801d5cd8, 0x801d5ce4)
	if b == 0xff {
		return shut()
	}
	for r in rules {
		spend(r.test, r.hit - 4)
		if a & r.a_mask != r.a {
			continue
		}
		spend(r.hit, r.hit + 12)
		if b & r.b_mask == r.b {
			return shut()
		}
		if r.next > r.hit + 16 {
			spend(r.hit + 16, r.next - 4)
		}
	}
	// Level cells of kind 2 meet only on the same level (bit 0).
	spend(0x801d5e00, 0x801d5e08)
	if a & 0xf0 == 0x20 {
		spend(0x801d5e0c, 0x801d5e10)
		if b & 0xf0 == 0x20 {
			spend(0x801d5e14, 0x801d5e20)
			if (a ~ b) & 1 != 0 {
				return shut()
			}
			spend(0x801d5e24, 0x801d5e24)
		}
	} else {
		spend(0x801d5e24, 0x801d5e24)
	}
	spend(0x801d5e28, 0x801d5e30)
	if a & 0xf0 != 0x70 {
		spend(0x801d5e58, 0x801d5e5c)
		return true
	}
	spend(0x801d5e34, 0x801d5e40)
	if b == 0x2d {
		return shut()
	}
	spend(0x801d5e4c, 0x801d5e50)
	if b == 0xa3 {
		spend(0x801d5e58, 0x801d5e5c)
		return false
	}
	spend(0x801d5e54, 0x801d5e5c)
	return true
}

// 0x801d5e60: whether a diagonal step from a onto b may cut across the side
// cell s: s may not close a ramp edge against b, then the step from a onto s
// must be open.
@(private = "file")
corner_open :: proc(a, b, s: u32) -> bool {
	@(static, rodata) rules := [?]Edge_Rule {
		{0xff, 0x2e, 0xf0, 0xb0, 0x801d5e6c, 0x801d5e7c, 0x801d5e90},
		{0xff, 0x2d, 0xf0, 0x70, 0x801d5e90, 0x801d5e9c, 0x801d5eb0},
		{0xff, 0x2c, 0xf0, 0xe0, 0x801d5eb0, 0x801d5eb8, 0x801d5ec8},
		{0xff, 0x2b, 0xf0, 0xc0, 0x801d5ec8, 0x801d5ed4, 0x801d5ee4},
		{0xff, 0x2f, 0xf0, 0xa0, 0x801d5ee4, 0x801d5ef0, 0x801d5f00},
		{0xf0, 0xa0, 0xff, 0x2f, 0x801d5f00, 0x801d5f0c, 0x801d5f1c},
		{0xf0, 0xb0, 0xff, 0x2e, 0x801d5f1c, 0x801d5f28, 0x801d5f38},
		{0xf0, 0xe0, 0xff, 0x2c, 0x801d5f38, 0x801d5f44, 0x801d5f54},
		{0xf0, 0xc0, 0xff, 0x2b, 0x801d5f54, 0x801d5f60, 0x801d5f70},
	}
	shut :: proc(far: bool) -> bool {
		if far {
			spend(0x801d5f90, 0x801d5f94)
		}
		spend(0x801d5fdc, 0x801d5fe8)
		return false
	}
	events()
	spend(0x801d5e60, 0x801d5e68)
	for r, i in rules {
		spend(r.test, r.hit - 4)
		if b & r.a_mask != r.a {
			continue
		}
		spend(r.hit, r.hit + 12)
		if s & r.b_mask == r.b {
			return shut(i != 0)
		}
		if r.next > r.hit + 16 {
			spend(r.hit + 16, r.next - 4)
		}
	}
	spend(0x801d5f70, 0x801d5f78)
	if b & 0xf0 == 0x70 {
		spend(0x801d5f7c, 0x801d5f80)
		if s & 0xf0 == 0x70 {
			return shut(true)
		}
		spend(0x801d5f84, 0x801d5f8c)
		if s == 0x2d {
			return shut(true)
		}
		spend(0x801d5f98, 0x801d5f9c)
		if s == 0xa3 {
			return shut(false)
		}
	}
	spend(0x801d5fa0, 0x801d5fac)
	if b & 0xf0 == 0x20 {
		spend(0x801d5fb0, 0x801d5fb4)
		if s & 0xf0 == 0x20 {
			spend(0x801d5fb8, 0x801d5fc0)
			if (b ~ s) & 1 != 0 {
				return shut(false)
			}
		}
	}
	spend(0x801d5fc4, 0x801d5fd0)
	open := edge_open(a, s)
	spend(0x801d5fd4, 0x801d5fd8)
	spend(0x801d5fdc, 0x801d5fe8)
	return open
}

// 0x801d5fec: whether the ground at cell (x0, z0) on layer l0 and at
// (x1, z1) on l1 are at most one unit apart. Cells 0xa4 and 0x11 at the
// destination always meet. The game's frame sits 72 bytes below `sp`; the
// ground lookups read their position from it.
@(private = "file")
heights_meet :: proc(sp: u32, x0, z0: i32, l0: u32, x1, z1: i32, l1: u32) -> bool {
	events()
	spend(0x801d5fec, 0x801d6040)
	meet :: proc() -> bool {
		spend(0x801d60c8, 0x801d60f4)
		return true
	}
	if attr_lookup_native(u32(x1), u32(z1), l1) == 0xa4 {
		spend(0x801d6044, 0x801d6050)
		return meet()
	}
	spend(0x801d6044, 0x801d6050)
	spend(0x801d6054, 0x801d605c)
	if attr_lookup_native(u32(x1), u32(z1), l1) == 0x11 {
		spend(0x801d6060, 0x801d606c)
		return meet()
	}
	spend(0x801d6060, 0x801d606c)
	c := &cpu.state
	frame := sp - 72
	pos := frame + 16
	c.r[29] = frame
	defer c.r[29] = sp
	spend(0x801d6070, 0x801d6084)
	cpu.w32(pos, u32(x0) << 16)
	cpu.w32(pos + 8, u32(z0) << 16)
	c.r[4], c.r[5] = pos, l0 & 255
	game_call(GROUND, 0x801d6088)
	h0 := i32(c.r[2])
	spend(0x801d6088, 0x801d60a4)
	cpu.w32(pos, u32(x1) << 16)
	cpu.w32(pos + 8, u32(z1) << 16)
	c.r[4], c.r[5] = pos, l1 & 255
	game_call(GROUND, 0x801d60a8)
	d := h0 - i32(c.r[2])
	spend(0x801d60a8, 0x801d60b0)
	if d < 0 {
		spend(0x801d60b4, 0x801d60b4)
		d = -d
	}
	spend(0x801d60b8, 0x801d60c4)
	spend(0x801d60cc, 0x801d60f4)
	return d <= 0x10000
}
