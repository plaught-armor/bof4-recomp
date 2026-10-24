// Map geometry: the layers of the loaded map block and a native drawing of
// them in place of the executable's tile passes.
//
// The map block (MAP_BLOCK, always at 0x80069800) starts with four
// counts and tables of offsets from the block start:
//
//   +0x00 u8   layers                +0x04 u32[8]  layer offsets
//   +0x01 u8   model groups          +0x24 u32[32] model group offsets
//   +0x02 u8   +0xa4 entries         +0xa4 u32[8]
//   +0x03 u8   sections              +0xc4 u32[8]  section offsets
//
// A section's first byte is the layer it draws. A layer is a grid of tiles
// 256 units square, stored as rows of runs, plus a pool of free polygons:
//
//   +0x00 u16 width in tiles     +0x08 u32 tiles offset (16 bytes each)
//   +0x02 u16 rows               +0x0c u32 polygon refs offset (4 bytes each)
//   +0x04 u32 row table offset   +0x10 u32 polygons offset (32 bytes each)
//
// The parts follow one another in that order with no gaps; the polygons run
// to the next thing in the block. Each frame LAYER_SETUP picks runs of tiles
// around the view (TILE_RUNS) and LAYER_TILES_DRAW turns them into GPU
// packets in two passes: pass 1 draws the heightfield quad of every tile
// that has one, pass 2 the tile's polygons (walls, roofs, props).
package qol

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "../psx"

@(private = "file")
LAYER_TILES_DRAW :: 0x80143930 // both tile passes over the runs LAYER_SETUP picked
@(private = "file")
MODEL_COLOURS :: 0x128 // map block offset of the u32 offset of the model colour table
@(private = "file")
TILE_RUN_LIST :: 0x8017c618 // LAYER_SETUP's runs, Tile_Run each
@(private = "file")
OT_PTR :: 0x80116b18 // u32, the ordering table being filled; slot n at +0x88+4n
@(private = "file")
OT_FIRST :: 0x88
@(private = "file")
OT_FAR :: 1023 // depth slot of tiles and polygons flagged far
@(private = "file")
PACKET_SIZE :: 52 // each tile packet slot: a POLY_GT4, or a draw mode + POLY_G4
@(private = "file")
PACKET_WRAP :: 1024 // packet count at which the pointer moves to SC_PACKET_WRAP

// Scratchpad words the passes read and leave behind.
@(private = "file")
SC_PASS :: 0x61 // u8, 0 in pass 1, 1 in pass 2
@(private = "file")
SC_COUNT :: 0x64 // u16, packets used
@(private = "file")
SC_VISITS :: 0x66 // u16, tiles and polygons pass 2 looked at
@(private = "file")
SC_PACKET :: 0x6c // u32, next packet
@(private = "file")
SC_DEPTH_SHIFT :: 0x70 // u8, depth = (max sz - SC_DEPTH_BASE) >> this
@(private = "file")
SC_DEPTH_MODE :: 0x71 // u8, 1: halve depths and push below-ground ones back; 2: also squeeze into the far half
@(private = "file")
SC_DEPTH_BASE :: 0x72 // u16
@(private = "file")
SC_BUDGET :: 0x76 // u16, packets allowed
@(private = "file")
SC_PACKET_WRAP :: 0x80 // u32, where packets continue after PACKET_WRAP
@(private = "file")
SC_RUN_COUNT :: 0x90 // u16, runs in TILE_RUN_LIST
@(private = "file")
SC_RUN :: 0xe0 // u32, run being drawn
@(private = "file")
SC_HELPERS :: 0xa8 // u8 x3, optional per-polygon helpers (0x8014bc44/84/c4) in use
@(private = "file")
SC_FOG_BASE :: 0xac // s32, depth where fog starts (with SC_FOG_SHIFT)
@(private = "file")
SC_FOG_SHIFT :: 0xb0 // s8
@(private = "file")
SC_FOG :: 0xb6 // u8, fog on; low 2 bits are the fog's blend mode
@(private = "file")
SC_FOGGED :: 0xb7 // u8, the last quad past the backface test is partly fogged
@(private = "file")
SC_UV_BASE_U :: 0xbc // u8[4], the far texel corner per tile UV slot
@(private = "file")
SC_UV_BASE_V :: 0xc0 // u8[4]
@(private = "file")
SC_REFS :: 0xe8 // u32, the layer's polygon refs
@(private = "file")
SC_POLYS :: 0xec // u32, the layer's polygons
@(private = "file")
SC_TILE_X :: 0x40 // u16, x of the tile being drawn
@(private = "file")
SC_TILE_Z :: 0x44 // u16
@(private = "file")
SC_TILE :: 0xf8 // u32, tile being drawn
@(private = "file")
SC_POLY :: 0xfc // u32, polygon being drawn
@(private = "file")
SC_TEXTURE :: 0x114 // per texture slot: u16 CLUT, u16 texture page
// MODELS_DRAW's own words. The fixed view's sight test is set per view: a
// centre, a manhattan radius (`reach`), a side limit, and a mode (bit 0: the
// diamond test, else a box; bit 1: which diagonal the diamond's side cut runs).
@(private = "file")
SC_POLY_COUNT :: 0x62 // u16, polygons of the model being drawn
@(private = "file")
SC_MODEL_Y :: 0x42 // u16, y of the model being drawn (x and z in SC_TILE_X/Z)
@(private = "file")
SC_SIGHT_X :: 0x84 // u16, the sight test's centre, less 64
@(private = "file")
SC_SIGHT_Z :: 0x86 // u16
@(private = "file")
SC_REACH :: 0x88 // s16
@(private = "file")
SC_SIDE :: 0x8a // s16
@(private = "file")
SC_LAYER :: 0x8c // u8, layer MODELS_DRAW draws
@(private = "file")
SC_SIGHT_MODE :: 0x8d // u8
@(private = "file")
SC_TURN :: 0xb8 // u8, quarter turns of the model being drawn
@(private = "file")
SC_GROUP :: 0xf0 // u32, its model group
@(private = "file")
SC_COLOURS :: 0xf4 // u32, the map block's model colour table
@(private = "file")
SC_COLOUR :: 0x100 // u32, the next polygon's corner colours
@(private = "file")
SC_MODEL_POLY :: 0x104 // u32, the next polygon
@(private = "file")
SC_MODEL :: 0x108 // u32, the placed model being drawn
// The fourth byte of each corner colour word the passes build at 0x20..0x2f:
// the polygon's own bytes in pass 2, carried into the packets' unused bytes.
@(private = "file")
SC_COLOR_TAIL :: [4]u32{0x23, 0x27, 0x2b, 0x2f}

Layer_Header :: struct #packed {
	width:  u16le,
	rows:   u16le,
	row_at: u32le,
	tile_at: u32le,
	ref_at: u32le,
	poly_at: u32le,
}

// One row of the tile grid: `count` tiles from column `x`, the first being
// tile `first`.
Map_Row :: struct #packed {
	x:     u8,
	count: u8,
	first: u16le,
}

// Tile flags (byte 0).
TILE_GROUND :: 0x01 // has a heightfield quad; else bytes 0-3 are u16 polygon count << 1, u16 first polygon
TILE_FLIP :: 0x02 // mirror the texture across the quad's other diagonal
TILE_UV_TURN :: 0x0c // which corner the texture starts at
TILE_SEMI :: 0x10 // semi-transparent
TILE_FAR :: 0x20 // drawn behind everything (depth slot OT_FAR)

Map_Tile :: struct #packed {
	flags:  u8,
	ref:    u8, // ground tiles: polygon ref index bits 0-7 (REF_NONE: no polygons)
	page:   u8, // bits 0-3 texture slot, 4-5 UV base slot, 6-7 polygon ref index bits 8-9
	cell:   u8, // texel cell: u = low nibble * 16, v = high nibble & 0xf0
	height: [4]i8, // corner heights / 16, corners (x,z) (x+1,z) (x,z+1) (x+1,z+1)
	color:  [4]u16le, // corner colours, 5 bits each, red highest
}

REF_NONE :: 1023

// A ground tile's polygons: `count` from polygon `first`.
Poly_Ref :: struct #packed {
	count: u16le,
	first: u16le,
}

// Polygon flags (byte 7).
POLY_SEMI :: 0x10
POLY_FAR :: 0x20

// A quad, corners in units of 16 relative to its tile's corner.
Map_Poly :: struct #packed {
	v0:      [3]i8,
	texture: i8, // texture slot
	v1:      [3]i8,
	flags:   u8,
	v2:      [3]i8,
	spare2:  u8,
	v3:      [3]i8,
	spare3:  u8,
	uv:      [4][2]u8,
	color:   [4]u16le,
}

// A model placed on a layer: the layer's u8 count at +2, the models from +4.
Placed_Model :: struct #packed {
	group:   u8, // model group (map block +0x24)
	colours: u8, // colour set in the block's model colour table
	flags:   u8, // PLACED_*
	_:       u8,
	x:       u16le, // units of 16
	y:       u16le,
	z:       u16le,
	_:       u8,
	octants: u8, // with PLACED_OCTANTS: bit n hides it from camera octant n
}

PLACED_TURN :: 0x03 // quarter turns
PLACED_OCTANTS :: 0x04 // hidden from the camera octants in `octants`
PLACED_DRAWN :: 0x20

// A model group: u16 polygon count, u16, s8[4] bounding box (x0, z0, x1, z1
// in units of 128), then the polygons. Their corners are in units of 16 from
// the placed model, turned with it; colours are in the colour table.
Model_Poly :: struct #packed {
	v0:      [3]i8,
	texture: i8,
	v1:      [3]i8,
	flags:   u8, // POLY_SEMI, POLY_FAR, POLY_DOUBLE
	v2:      [3]i8,
	spare2:  u8,
	v3:      [3]i8,
	spare3:  u8,
	uv:      [4]u16le,
}

POLY_DOUBLE :: 0x08 // drawn from both sides

#assert(size_of(Layer_Header) == 0x14)
#assert(size_of(Placed_Model) == 12)
#assert(size_of(Model_Poly) == 24)
#assert(size_of(Map_Tile) == 16)
#assert(size_of(Map_Poly) == 32)

// A run of tiles LAYER_SETUP picked: `count` tiles from `tile` (a RAM
// address), the first at block (x, z).
@(private = "file")
Tile_Run :: struct #packed {
	tile:  u32le,
	count: i16le,
	x:     i8,
	z:     i8,
}

Map_Layer :: struct {
	width: u16,
	rows:  []Map_Row,
	tiles: []Map_Tile,
	refs:  []Poly_Ref,
	polys: []Map_Poly,
}

// The polygons of a tile: `first` and `count` into the layer's polygons.
tile_polys :: proc(l: ^Map_Layer, t: Map_Tile) -> (first, count: int) {
	if t.flags & TILE_GROUND == 0 {
		raw := transmute([16]u8)t
		return int(u16(raw[2]) | u16(raw[3]) << 8), int((u16(raw[0]) | u16(raw[1]) << 8) >> 1)
	}
	i := int(t.ref) | int(t.page & 0xc0) << 2
	if i == REF_NONE || i >= len(l.refs) {
		return 0, 0
	}
	return int(l.refs[i].first), int(l.refs[i].count)
}

// Decode a layer from its bytes (header up to the next thing in the block).
// The slices point into `data`.
map_layer_decode :: proc(data: []u8) -> (l: Map_Layer, ok: bool) {
	if len(data) < size_of(Layer_Header) {
		return
	}
	h := (^Layer_Header)(raw_data(data))^
	n := u32(len(data))
	at := [4]u32{u32(h.row_at), u32(h.tile_at), u32(h.ref_at), u32(h.poly_at)}
	if at[0] != size_of(Layer_Header) || at[1] < at[0] || at[2] < at[1] || at[3] < at[2] || at[3] > n {
		return
	}
	if at[1] - at[0] != u32(h.rows) * size_of(Map_Row) || (at[2] - at[1]) % size_of(Map_Tile) != 0 ||
	   (at[3] - at[2]) % size_of(Poly_Ref) != 0 || (n - at[3]) % size_of(Map_Poly) != 0 {
		return
	}
	l.width = u16(h.width)
	l.rows = mem.slice_data_cast([]Map_Row, data[at[0]:at[1]])
	l.tiles = mem.slice_data_cast([]Map_Tile, data[at[1]:at[2]])
	l.refs = mem.slice_data_cast([]Poly_Ref, data[at[2]:at[3]])
	l.polys = mem.slice_data_cast([]Map_Poly, data[at[3]:])
	return l, true
}

// The bytes of a layer, laid out as the game stores it.
map_layer_encode :: proc(l: Map_Layer, allocator := context.allocator) -> []u8 {
	h := Layer_Header {
		width = u16le(l.width),
		rows  = u16le(len(l.rows)),
	}
	h.row_at = size_of(Layer_Header)
	h.tile_at = h.row_at + u32le(len(l.rows) * size_of(Map_Row))
	h.ref_at = h.tile_at + u32le(len(l.tiles) * size_of(Map_Tile))
	h.poly_at = h.ref_at + u32le(len(l.refs) * size_of(Poly_Ref))
	out := make([]u8, int(h.poly_at) + len(l.polys) * size_of(Map_Poly), allocator)
	copy(out, mem.ptr_to_bytes(&h))
	copy(out[h.row_at:], mem.slice_to_bytes(l.rows))
	copy(out[h.tile_at:], mem.slice_to_bytes(l.tiles))
	copy(out[h.ref_at:], mem.slice_to_bytes(l.refs))
	copy(out[h.poly_at:], mem.slice_to_bytes(l.polys))
	return out
}

// The loaded map block's layers as byte ranges in RAM: each runs from its
// offset to the next offset of any table in the block.
@(private = "file")
map_layer_spans :: proc(spans: ^[8][2]u32) -> (n: int) {
	block := psx.r32(MAP_BLOCK)
	if block & 0x1fffff == 0 {
		return 0
	}
	ends: [56]u32
	ne := 0
	tables := [4][2]u32{{0x04, 8}, {0x24, 32}, {0xa4, 8}, {0xc4, 8}}
	for t, k in tables {
		count := min(u32(psx.r8(block + u32(k))), t[1])
		for i in 0 ..< count {
			ends[ne] = psx.r32(block + t[0] + 4 * i)
			ne += 1
		}
	}
	n = min(int(psx.r8(block)), 8)
	for i in 0 ..< n {
		start := psx.r32(block + 4 + 4 * u32(i))
		end := u32(0)
		for e in ends[:ne] {
			if e > start && (end == 0 || e < end) {
				end = e
			}
		}
		spans[i] = {block + start, block + end}
	}
	return n
}

map_geometry: struct {
	tiles_draw: psx.Func_Proc,
	models_draw: psx.Func_Proc,
	check:      bool, // BOF4_MAPCHECK: run both drawings and compare
	checked:    int,
	mismatches: int,
	timed:      int, // drawings that differ only after an interrupt
	cycle_misses: int, // untimed drawings whose native cycles differ from the game's
	block_seen: u32, // map block checksum the layer round trip last ran on
}

@(private)
map_geometry_init :: proc() -> bool {
	ok: bool
	map_geometry.tiles_draw = psx.hook(LAYER_TILES_DRAW, map_tiles_draw) or_return
	map_geometry.models_draw = psx.hook(MODELS_DRAW, map_models_draw) or_return
	map_geometry.check = os.get_env("BOF4_MAPCHECK", context.temp_allocator) != ""
	floors.dump_dir = os.get_env("BOF4_FLOORDUMP", context.allocator)
	return true
}

// The optional per-polygon helpers read the game's own working words, so
// with any in use the game draws.
@(private = "file")
map_helpers :: proc() -> bool {
	sc := &psx.scratch
	return sc[SC_HELPERS] | sc[SC_HELPERS + 1] | sc[SC_HELPERS + 2] != 0
}

@(private = "file")
map_tiles_draw :: proc() {
	floors_dump()
	if map_helpers() {
		map_geometry.tiles_draw()
		return
	}
	if !map_geometry.check {
		tiles_draw_native()
		return
	}
	map_check_layers()
	@(static, rodata) interface := [?]u32{SC_PASS, SC_COUNT, SC_COUNT + 1, SC_VISITS, SC_VISITS + 1, SC_PACKET, SC_PACKET + 1, SC_PACKET + 2, SC_PACKET + 3, SC_FOGGED, 0x23, 0x27, 0x2b, 0x2f}
	map_check_draw(map_geometry.tiles_draw, tiles_draw_native, interface[:], "tiles")
}

@(private = "file")
map_models_draw :: proc() {
	if map_helpers() {
		map_geometry.models_draw()
		return
	}
	if !map_geometry.check {
		models_draw_native()
		return
	}
	@(static, rodata) interface := [?]u32 {
		SC_PASS, SC_POLY_COUNT, SC_POLY_COUNT + 1, SC_COUNT, SC_COUNT + 1, SC_VISITS, SC_VISITS + 1,
		SC_PACKET, SC_PACKET + 1, SC_PACKET + 2, SC_PACKET + 3, SC_FOGGED, SC_TURN,
		SC_TILE_X, SC_TILE_X + 1, SC_MODEL_Y, SC_MODEL_Y + 1, SC_TILE_Z, SC_TILE_Z + 1, 0x23, 0x27, 0x2b, 0x2f,
		SC_GROUP, SC_GROUP + 1, SC_GROUP + 2, SC_GROUP + 3, SC_COLOURS, SC_COLOURS + 1, SC_COLOURS + 2, SC_COLOURS + 3,
		SC_COLOUR, SC_COLOUR + 1, SC_COLOUR + 2, SC_COLOUR + 3, SC_MODEL_POLY, SC_MODEL_POLY + 1, SC_MODEL_POLY + 2, SC_MODEL_POLY + 3,
		SC_MODEL, SC_MODEL + 1, SC_MODEL + 2, SC_MODEL + 3,
	}
	map_check_draw(map_geometry.models_draw, models_draw_native, interface[:], "models")
}

// ---------------------------------------------------------------- drawing
//
// The native passes take no emulated time (see `spend`); due interrupts run
// where the game checks for them, at function entries and loop back edges.
// Each path still names the instructions the game runs on it by their
// addresses in the game's pass 1 (pass 2 repeats pass 1's projection and
// packet code instruction for instruction), for BOF4_MAPCHECK.

// What the drawing of one quad (quad_draw) is common to: the tile passes and
// MODEL_DRAW, which carries its own copy of the code. Over most of their
// length the copies match instruction for instruction, so the copy's
// addresses are pass 1's moved by `mid` (depth, fog, packet budget) and
// `late` (depth mode, insert, fog packet); the rest differ and are listed.
@(private = "file")
Quad_Code :: struct {
	project:    [2]u32, // the projection, after the corners are in place
	bounds:     u32, // the first corner's on-screen test
	back:       u32, // the backface test
	sides:      [2]u32, // a back face's double-sided test (none in the tile passes)
	mid:        u32,
	wrap:       [2][2]u32, // the packet count test, the move to the wrap
	packet:     [3][2]u32, // writing the packet
	semi:       [2]u32, // making it semi-transparent
	late:       u32,
	far_insert: u32, // where the insert starts for a quad at OT_FAR
}

@(private = "file", rodata)
TILE_QUAD := Quad_Code {
	project    = {0x80143ad8, 0x80143b80},
	bounds     = 0x80143b84,
	back       = 0x80143c64,
	wrap       = {{0x80143f78, 0x80143f80}, {0x80143f84, 0x80143f8c}},
	packet     = {{0x80144238, 0x80144260}, {0x8014427c, 0x80144288}, {0x80144294, 0x801443b0}},
	semi       = {0x80144264, 0x80144278},
	far_insert = 0x80144490,
}

@(private = "file", rodata)
MODEL_QUAD := Quad_Code {
	project    = {0x8014641c, 0x801464c4},
	bounds     = 0x801464c8,
	back       = 0x801465a8,
	sides      = {0x801465c8, 0x801465d8},
	mid        = 0x801465dc - 0x80143c84,
	wrap       = {{0x801468d0, 0x801468d4}, {0x801468d8, 0x801468e0}},
	packet     = {{0x801468e4, 0x801469e4}, {0x801469f0, 0x80146a18}, {0x80146a34, 0x80146b60}},
	semi       = {0x80146a1c, 0x80146a30},
	late       = 0x80146b64 - 0x801443b4,
	far_insert = 0x80146c3c,
}

// How quad_draw left off: the quad culled; drawn (or found in the fog) on the
// path through the last instruction before the tile tail (0x80144794 in pass
// 1, the first of MODEL_DRAW's polygon tail); or no packet left.
@(private = "file")
Quad_End :: enum {
	Culled,
	Tail,
	Out_Of_Packets,
}

@(private = "file")
Quad_Draw :: struct {
	ot:          u32,
	packet:      u32,
	wrap:        u32,
	count:       u16,
	budget:      u16,
	depth_base:  u32,
	depth_shift: u32,
	depth_mode:  u8,
	fog:         u8,
	fog_base:    i32, // fog start minus 4096 >> fog shift, the value subtracted from depths
	fog_shift:   u32,
	unculled:    bool,
	fogged:      u8, // SC_FOGGED: the last quad past the backface test needed a fog packet
	tail:        [4]u8,
	// The quad being drawn.
	v:           [4][3]i16,
	rgb:         [4][3]u8,
	uv:          [4]u16,
	clut:        u16,
	tpage:       u16,
	semi:        bool,
	far:         bool,
	both_sides:  bool,
	colour_cost: u64, // cycles of the pass's own colour and texel code, spent once the quad has a packet
}

// The drawing state as the scratchpad holds it.
@(private = "file")
quad_draw_begin :: proc() -> (d: Quad_Draw) {
	sc := &psx.scratch
	d = Quad_Draw {
		ot          = psx.r32(OT_PTR),
		packet      = sc_u32(SC_PACKET),
		wrap        = sc_u32(SC_PACKET_WRAP),
		count       = sc_u16(SC_COUNT),
		budget      = sc_u16(SC_BUDGET),
		depth_base  = u32(sc_u16(SC_DEPTH_BASE)),
		depth_shift = u32(sc[SC_DEPTH_SHIFT]) & 31,
		depth_mode  = sc[SC_DEPTH_MODE],
		fog         = sc[SC_FOG],
		fog_shift   = u32(sc[SC_FOG_SHIFT]) & 31,
		unculled    = psx.tiles_unculled,
		fogged      = sc[SC_FOGGED],
	}
	d.fog_base = i32(sc_u32(SC_FOG_BASE)) - (4096 >> (u32(i8(sc[SC_FOG_SHIFT])) & 31))
	for o, i in SC_COLOR_TAIL {
		d.tail[i] = sc[o]
	}
	return d
}

// Leave the drawing state in the scratchpad.
@(private = "file")
quad_draw_end :: proc(d: ^Quad_Draw) {
	sc_w32(SC_PACKET, d.packet)
	sc_w16(SC_COUNT, d.count)
	psx.scratch[SC_FOGGED] = d.fogged
	for o, i in SC_COLOR_TAIL {
		psx.scratch[o] = d.tail[i]
	}
}

// The native code knows the emulated cycles the game's code would have
// taken, path by path, as spans of the game's instruction addresses (delay
// slots included), but charges them only under BOF4_MAPCHECK, which compares
// the counts on every drawing no interrupt fell inside, and when replaying a
// record made while it always did (psx.charge_native). Otherwise it takes no
// emulated time: the map drawing was most of a town's frame (Sarai: about
// two vblanks of the three each game frame took, 20 game frames a second
// against 30 in rooms, so the party walked at two thirds speed), and free
// it fits in two. Interrupts, CD reads and vblanks then land at other
// points of the frame than on a PS1, so recordings made while it was
// charged (before 2026-10-22) need the charge back to replay.
//
// Cycles the game's instructions `from` to `to` (inclusive) take.
@(private)
cost :: #force_inline proc(from, to: u32) -> u64 {
	return u64((to - from) / 4 + 1) * psx.CYCLES_PER_INSN
}

@(private)
spend :: #force_inline proc(from, to: u32) {
	if map_geometry.check || psx.charge_native {
		psx.cpu.cycles += cost(from, to)
	}
}

// Run the interrupts that are due, as the game's code does on entering a
// function and on each loop back edge.
@(private)
events :: #force_inline proc() {
	if psx.cpu.cycles >= psx.next_event {
		psx.run_events()
	}
}

@(private = "file")
tiles_draw_native :: proc() {
	sc := &psx.scratch
	events()
	spend(0x80143930, 0x8014393c) // LAYER_TILES_DRAW calls pass 1
	d := quad_draw_begin()
	runs := i16(sc_u16(SC_RUN_COUNT))
	refs, polys := sc_u32(SC_REFS), sc_u32(SC_POLYS)
	visits := sc_u16(SC_VISITS)

	// Pass 1: the heightfield quads.
	events()
	spend(0x80143958, 0x80143998)
	run_at := u32(TILE_RUN_LIST)
	pass1: {
		if runs <= 0 {
			break pass1
		}
		spend(0x8014399c, 0x801439ac)
		for r := runs; r > 0; r -= 1 {
			if r != runs {
				events()
			}
			spend(0x801439b0, 0x80143a00)
			run := (^Tile_Run)(ram_ptr(run_at))^
			x := u16(i16(run.x) << 8 - 64)
			z := u16(i16(run.z) << 8 - 64)
			tile_at := u32(run.tile)
			for n := run.count; n > 0; n -= 1 {
				if n != run.count {
					events()
				}
				spend(0x80143a04, 0x80143a28)
				t := (^Map_Tile)(ram_ptr(tile_at))
				if t.flags & TILE_GROUND != 0 {
					spend(0x80143a2c, 0x80143acc)
					xs := [4]u16{x, x + 256, x, x + 256}
					zs := [4]u16{z, z, z + 256, z + 256}
					for i in 0 ..< 4 {
						d.v[i] = {i16(xs[i]), i16(t.height[i]) * 16, i16(zs[i])}
						d.rgb[i] = color_unpack(u16(t.color[i]))
					}
					tile_uv(&d, t)
					slot := u32(t.page & 15) * 4
					d.clut, d.tpage = sc_u16(SC_TEXTURE + slot), sc_u16(SC_TEXTURE + slot + 2)
					d.semi, d.far = t.flags & TILE_SEMI != 0, t.flags & TILE_FAR != 0
					switch quad_draw(&d, TILE_QUAD) {
					case .Culled:
					case .Tail:
						spend(0x80144794, 0x80144794)
					case .Out_Of_Packets:
						break pass1
					}
				}
				spend(0x80144798, 0x801447b8)
				x += 256
				tile_at += size_of(Map_Tile)
			}
			spend(0x801447bc, 0x801447d4)
			run_at += 8
		}
	}
	spend(0x801447d8, 0x801447fc)
	spend(0x80143940, 0x80143944) // and pass 2

	// Pass 2: each tile's polygons.
	events()
	spend(0x80144800, 0x8014484c)
	run_at = TILE_RUN_LIST
	poly_at := sc_u32(SC_POLY)
	x, z: u16
	tile_at: u32
	pass2: {
		if runs <= 0 {
			break pass2
		}
		spend(0x80144850, 0x8014485c)
		for r := runs; r > 0; r -= 1 {
			if r != runs {
				events()
			}
			spend(0x80144860, 0x801448b0)
			run := (^Tile_Run)(ram_ptr(run_at))^
			x = u16(i16(run.x) << 8 - 64)
			z = u16(i16(run.z) << 8 - 64)
			tile_at = u32(run.tile)
			for n := run.count; n > 0; n -= 1 {
				if n != run.count {
					events()
				}
				spend(0x801448b4, 0x801448d8)
				raw := (^[4]u8)(ram_ptr(tile_at))^
				count: i16
				if raw[0] & TILE_GROUND != 0 {
					spend(0x801448dc, 0x801448f8)
					i := u32(raw[1]) + u32(raw[2] & 0xc0) << 2
					if i != REF_NONE {
						spend(0x801448fc, 0x80144918)
						spend(0x8014493c, 0x8014494c)
						ref := (^Poly_Ref)(ram_ptr(refs + i * 4))^
						count = i16(ref.count)
						poly_at = polys + u32(ref.first) * size_of(Map_Poly)
					} else {
						spend(0x8014491c, 0x80144920)
					}
				} else {
					spend(0x80144924, 0x8014494c)
					count = i16((u16(raw[0]) | u16(raw[1]) << 8) >> 1)
					poly_at = polys + (u32(raw[2]) | u32(raw[3]) << 8) * size_of(Map_Poly)
				}
				spend(0x80144950, 0x80144968)
				visits += 1
				for k := count; k > 0; k -= 1 {
					if k != count {
						events()
					}
					spend(0x8014496c, 0x80144aa4)
					p := (^Map_Poly)(ram_ptr(poly_at))
					corners := [4][3]i8{p.v0, p.v1, p.v2, p.v3}
					for c, i in corners {
						d.v[i] = {i16(x + u16(i16(c[0]) * 16)), i16(c[1]) * 16, i16(z + u16(i16(c[2]) * 16))}
						d.rgb[i] = color_unpack(u16(p.color[i]))
						d.uv[i] = u16(p.uv[i][0]) | u16(p.uv[i][1]) << 8
					}
					d.tail = {u8(p.texture), p.flags, p.spare2, p.spare3}
					slot := u32(i32(p.texture) * 4)
					d.clut, d.tpage = sc_u16(SC_TEXTURE + slot), sc_u16(SC_TEXTURE + slot + 2)
					d.semi, d.far = p.flags & POLY_SEMI != 0, p.flags & POLY_FAR != 0
					d.colour_cost = cost(0x80144f68, 0x8014505c)
					switch quad_draw(&d, TILE_QUAD) {
					case .Culled:
					case .Tail:
						spend(0x80144794, 0x80144794)
					case .Out_Of_Packets:
						break pass2
					}
					spend(0x801455c0, 0x801455e0)
					visits += 1
					poly_at += size_of(Map_Poly)
				}
				if count > 0 {
					spend(0x801455e4, 0x801455e4)
				}
				spend(0x801455e8, 0x80145608)
				x += 256
				tile_at += size_of(Map_Tile)
			}
			spend(0x8014560c, 0x80145624)
			run_at += 8
		}
	}
	spend(0x80145628, 0x80145650)
	spend(0x80143948, 0x80143954) // LAYER_TILES_DRAW returns
	// Leave the words the game's pass 2 leaves, for anything reading them after.
	sc_w16(SC_TILE_X, x)
	sc_w16(SC_TILE_Z, z)
	sc_w32(SC_TILE, tile_at)
	sc[SC_PASS] = 1
	sc_w16(SC_VISITS, visits)
	sc_w32(SC_RUN, run_at)
	sc_w32(SC_POLY, poly_at)
	quad_draw_end(&d)
}

// Corner colour word to 8-bit components.
@(private = "file")
color_unpack :: #force_inline proc(c: u16) -> [3]u8 {
	return {u8(c >> 7) & 0xf8, u8(c >> 2) & 0xf8, u8(c << 3) & 0xf8}
}

// A ground tile's corner texels: its cell at one corner, the cell plus the
// slot's base at the opposite one, the other two mixed from those.
@(private = "file")
tile_uv :: proc(d: ^Quad_Draw, t: ^Map_Tile) {
	sc := &psx.scratch
	base := u32(t.page >> 4) & 3
	bu, bv := sc[SC_UV_BASE_U + base], sc[SC_UV_BASE_V + base]
	u, v := t.cell << 4, t.cell & 0xf0
	uv: [4][2]u8
	c := cost(0x80143f90, 0x801440b4)
	turn := t.flags & TILE_UV_TURN
	switch turn {
	case 0:
		uv[0], uv[3] = {u, v}, {u + bu, v + bv}
		c += cost(0x801440b8, 0x801440e8)
	case 4:
		uv[1], uv[2] = {u, v}, {u + bu, v + bv}
		c += cost(0x801440ec, 0x801440f0) + cost(0x801440f4, 0x80144124)
	case 8:
		uv[2], uv[1] = {u, v}, {u + bu, v + bv}
		c += cost(0x801440ec, 0x801440f0) + cost(0x80144128, 0x8014412c) + cost(0x80144130, 0x80144160)
	case:
		uv[3], uv[0] = {u, v}, {u + bu, v + bv}
		c += cost(0x801440ec, 0x801440f0) + cost(0x80144128, 0x8014412c) + cost(0x80144164, 0x80144190)
	}
	c += cost(0x80144194, 0x801441a4)
	if turn != 0 {
		c += cost(0x801441a8, 0x801441ac)
	}
	flip := t.flags & TILE_FLIP != 0
	if turn == 0 || turn == 12 {
		if !flip {
			uv[1], uv[2] = {uv[3][0], uv[0][1]}, {uv[0][0], uv[3][1]}
			c += cost(0x801441bc, 0x801441d0)
		} else {
			uv[1], uv[2] = {uv[0][0], uv[3][1]}, {uv[3][0], uv[0][1]}
			c += cost(0x801441d4, 0x801441e4)
		}
		c += cost(0x801441b0, 0x801441b8) + cost(0x801441e8, 0x801441f4)
	} else {
		if !flip {
			uv[0], uv[3] = {uv[2][0], uv[1][1]}, {uv[1][0], uv[2][1]}
			c += cost(0x80144200, 0x80144214)
		} else {
			uv[0], uv[3] = {uv[1][0], uv[2][1]}, {uv[2][0], uv[1][1]}
			c += cost(0x80144218, 0x80144228)
		}
		c += cost(0x801441f8, 0x801441fc) + cost(0x8014422c, 0x80144234)
	}
	for e, i in uv {
		d.uv[i] = u16(e[0]) | u16(e[1]) << 8
	}
	d.colour_cost = c
}

// The unculled drawing's test (psx.tiles_unculled): the game's needs a
// corner on screen, which drops a big quad whose corners all lie off it. This
// one drops a quad only when it cannot show: every corner behind the lens, or
// every corner before it and off the same side of the screen (the game's
// margins). Without it, the third-person tile window's every tile, behind
// the camera too, takes one of the frame's packets, and in a big town they
// run out before the placed models (the houses) are drawn.
@(private = "file")
quad_may_show :: proc(sxy: [4]u32, sz: [4]i32) -> bool {
	behind, left, right, above, below := 0, 0, 0, 0, 0
	for s, i in sxy {
		if sz[i] == 0 {
			behind += 1
			continue
		}
		x, y := i32(i16(u16(s))), i32(i16(u16(s >> 16)))
		left += int(x < -16)
		right += int(x >= 336)
		above += int(y < -16)
		below += int(y >= 256)
	}
	if behind == 4 {
		return false
	}
	return behind > 0 || (left < 4 && right < 4 && above < 4 && below < 4)
}

// quad_may_show for a quad drawn in 3D, by its corners in view space: one
// drops only when every corner is behind the near plane or past the same
// side of the screen (the game's margins), each side a plane through the
// lens.
@(private = "file")
world_may_show :: proc(at: [4][3]f32) -> bool {
	h, of := psx.world_lens()
	near, left, right, above, below := 0, 0, 0, 0, 0
	for c in at {
		near += int(c.z < psx.WORLD_NEAR)
		left += int(h * c.x + (of.x + 16) * c.z < 0)
		right += int(h * c.x + (of.x - 336) * c.z >= 0)
		above += int(h * c.y + (of.y + 16) * c.z < 0)
		below += int(h * c.y + (of.y - 256) * c.z >= 0)
	}
	return near < 4 && left < 4 && right < 4 && above < 4 && below < 4
}

// NCLIP's sign for view-space corners a, b, c: that of their triple
// product, which projecting in front of the lens keeps.
@(private = "file")
world_turn :: proc(a, b, c: [3]f32) -> i32 {
	t := linalg.dot(a, linalg.cross(b, c))
	return t > 0 ? 1 : t < 0 ? -1 : 0
}

// Project the quad in `d` and put it into the ordering table: a POLY_GT4
// and, in fog, a grey POLY_G4 blended over it. Spends the cycles of `q`'s copy
// of the code up to the caller's tail (see Quad_End).
@(private = "file")
quad_draw :: proc(d: ^Quad_Draw, q: Quad_Code) -> Quad_End {
	xy :: #force_inline proc(v: [3]i16) -> u32 {return u32(u16(v[0])) | u32(u16(v[1])) << 16}
	psx.gte_write(0, xy(d.v[0]))
	psx.gte_write(1, u32(u16(d.v[0][2])))
	psx.gte_write(2, xy(d.v[1]))
	psx.gte_write(3, u32(u16(d.v[1][2])))
	psx.gte_write(4, xy(d.v[2]))
	psx.gte_write(5, u32(u16(d.v[2][2])))
	psx.gte_cmd(0x280030) // RTPT
	sxy: [4]u32
	sz: [4]i32
	sxy[0], sxy[1], sxy[2] = psx.gte_read(12), psx.gte_read(13), psx.gte_read(14)
	sz[0], sz[1], sz[2] = i32(psx.gte_read(17)), i32(psx.gte_read(18)), i32(psx.gte_read(19))
	psx.gte_cmd(0x1400006) // NCLIP
	turn0 := i32(psx.gte_read(24))
	psx.gte_write(0, xy(d.v[3]))
	psx.gte_write(1, u32(u16(d.v[3][2])))
	psx.gte_cmd(0x180001) // RTPS
	psx.gte_cmd(0x1400006)
	turn1 := i32(psx.gte_read(24))
	sxy[3], sz[3] = psx.gte_read(14), i32(psx.gte_read(19))
	spend(q.project[0], q.project[1])
	// Drawn in 3D (psx.world_on), the quad is tested by its corners in view
	// space: the GTE's screen corners are clamped, and nonsense behind the
	// lens.
	world := psx.world_on()
	at: [4][3]f32
	if world {
		for &c, i in at {
			c = psx.world_view(d.v[i])
		}
		turn0, turn1 = world_turn(at[0], at[1], at[2]), world_turn(at[1], at[2], at[3])
	}

	if !d.unculled {
		on := false
		for s, i in sxy {
			at := q.bounds + 0x38 * u32(i)
			spend(at, at + 0x18)
			if u16(s) + 16 >= 352 {
				continue
			}
			spend(at + 0x1c, at + 0x34)
			if u16(s >> 16) + 16 < 272 {
				on = true
				break
			}
		}
		if !on {
			return .Culled
		}
	} else if !(world ? world_may_show(at) : quad_may_show(sxy, sz)) {
		return .Culled
	}
	spend(q.back, q.back + 0xc)
	if turn0 <= 0 {
		spend(q.back + 0x10, q.back + 0x1c)
		if turn1 >= 0 {
			if q.sides[0] == 0 {
				return .Culled
			}
			spend(q.sides[0], q.sides[1])
			if !d.both_sides {
				return .Culled
			}
		}
	}
	m := q.mid
	spend(0x80143c84 + m, 0x80143c94 + m)
	depth: i32 = OT_FAR
	if d.far {
		spend(0x80143c98 + m, 0x80143c9c + m)
	} else {
		spend(0x80143ca0 + m, 0x80143cb4 + m)
		depth = sz[0]
		if depth < sz[1] {
			depth = sz[1]
			spend(0x80143cb8 + m, 0x80143cb8 + m)
		}
		spend(0x80143cbc + m, 0x80143cd0 + m)
		if depth < sz[2] {
			depth = sz[2]
			spend(0x80143cd4 + m, 0x80143cd4 + m)
		}
		spend(0x80143cd8 + m, 0x80143cec + m)
		if depth < sz[3] {
			depth = sz[3]
			spend(0x80143cf0 + m, 0x80143cf0 + m)
		}
		spend(0x80143cf4 + m, 0x80143d08 + m)
		depth = i32(u32(depth) - d.depth_base) >> d.depth_shift
		// Nearer than the table's first slot is the first slot: in 3D the
		// quad running under the lens is drawn.
		if world && depth < 0 {
			depth = 0
		}
	}
	spend(0x80143d0c + m, 0x80143d18 + m)
	d.fogged = 0
	fogged := false
	fog: [4]i32
	if d.fog != 0 {
		// Each corner's code, then its clamp: below 0, in range, above.
		@(static, rodata) corner := [4][2]u32{{0x80143d1c, 0x80143d50}, {0x80143d6c, 0x80143db4}, {0x80143dd0, 0x80143e18}, {0x80143e34, 0x80143e7c}}
		for at, i in corner {
			spend(at[0] + m, at[1] + m)
			f := (sz[i] - d.fog_base) << d.fog_shift
			switch {
			case f < 0:
				spend(at[1] + m + 4, at[1] + m + 8)
			case f < 4096:
				spend(at[1] + m + 0xc, at[1] + m + 0x14)
			case:
				spend(at[1] + m + 0xc, at[1] + m + 0x18)
			}
			f = clamp(f, 0, 4095)
			fog[i] = f * f >> 12
			fogged ||= fog[i] < 3072
		}
		spend(0x80143e98 + m, 0x80143ebc + m)
		switch {
		case fog[0] < 3072:
			spend(0x80143ef4 + m, 0x80143f28 + m)
		case fog[1] < 3072:
			spend(0x80143ec0 + m, 0x80143ed0 + m)
			spend(0x80143ef8 + m, 0x80143f28 + m)
		case fog[2] < 3072:
			spend(0x80143ec0 + m, 0x80143ee4 + m)
			spend(0x80143ef8 + m, 0x80143f28 + m)
		case fog[3] < 3072:
			spend(0x80143ec0 + m, 0x80143ef0 + m)
			spend(0x80143ef4 + m, 0x80143f28 + m)
		case:
			spend(0x80143ec0 + m, 0x80143ef0 + m)
		}
		spend(0x80143f2c + m, 0x80143f48 + m)
		if !fogged {
			return .Culled // wholly in the fog
		}
		d.fogged = 1
		for &f in fog {
			f >>= 4
		}
	}
	spend(0x80143f4c + m, 0x80143f5c + m)
	if u16(depth) >= 1024 {
		return .Culled
	}
	spend(0x80143f60 + m, 0x80143f74 + m)
	if d.count >= d.budget {
		return .Out_Of_Packets
	}
	spend(q.wrap[0][0], q.wrap[0][1])
	if d.count == PACKET_WRAP {
		spend(q.wrap[1][0], q.wrap[1][1])
		d.packet = d.wrap
	}
	if map_geometry.check || psx.charge_native {
		psx.cpu.cycles += d.colour_cost
	}

	p := d.packet
	spend(q.packet[0][0], q.packet[0][1])
	psx.w8(p + 3, 12)
	psx.w8(p + 7, 0x3c | (d.semi ? 2 : 0))
	if d.semi {
		spend(q.semi[0], q.semi[1])
	}
	spend(q.packet[1][0], q.packet[1][1])
	spend(q.packet[2][0], q.packet[2][1])
	l := q.late
	psx.w16(p + 26, d.tpage)
	psx.w16(p + 14, d.clut)
	for i in 0 ..< 4 {
		at := p + 4 + 12 * u32(i)
		if i == 0 {
			psx.w8(at, d.rgb[0][0])
			psx.w8(at + 1, d.rgb[0][1])
			psx.w8(at + 2, d.rgb[0][2])
		} else {
			psx.w32(at, u32(d.rgb[i][0]) | u32(d.rgb[i][1]) << 8 | u32(d.rgb[i][2]) << 16 | u32(d.tail[i]) << 24)
		}
		psx.w32(at + 4, sxy[i])
		psx.w16(at + 8, d.uv[i])
	}
	switch {
	case d.depth_mode == 0:
		spend(0x8014448c + l, 0x801444e8 + l)
	case depth == OT_FAR:
		spend(0x801443b4 + l, 0x801443c0 + l)
		spend(q.far_insert, 0x801444e8 + l)
	case:
		spend(0x801443b4 + l, 0x801443c0 + l)
		ys := [4]i16{d.v[0][1], d.v[1][1], d.v[2][1], d.v[3][1]}
		// Corner heights are tested in order up to the first non-zero one,
		// then signs up to the first negative one.
		k := 0
		for k < 4 && ys[k] == 0 {
			k += 1
		}
		spend(0x801443c4 + l, 0x801443d0 + l + 16 * u32(min(k, 3)))
		if k == 4 {
			spend(0x80144464 + l, 0x80144464 + l)
			depth = 512
		} else {
			depth >>= 1
			spend(0x80144404 + l, 0x80144418 + l)
			k = 0
			for k < 4 && ys[k] >= 0 {
				k += 1
			}
			if k > 0 {
				spend(0x8014441c + l, 0x8014442c + l + 0x14 * u32(min(k, 3) - 1))
			}
			if k < 4 {
				spend(0x80144458 + l, 0x80144464 + l)
				depth += 512
			}
		}
		spend(0x80144468 + l, 0x80144474 + l)
		if d.depth_mode == 2 {
			spend(0x80144478 + l, 0x80144488 + l)
			depth = depth >> 1 + 512
		}
		spend(0x8014448c + l, 0x801444e8 + l)
	}
	if world {
		psx.world_quad_add(p, at)
	}
	ot_insert(d.ot + OT_FIRST + u32(depth) * 4, p)
	d.count += 1
	d.packet += PACKET_SIZE
	spend(0x801444f4 + l, 0x80144514 + l)

	if !fogged {
		return .Tail
	}
	k := 0
	for k < 4 && fog[k] == 0 {
		k += 1
	}
	spend(0x80144518 + l, 0x80144524 + l + 16 * u32(min(k, 3)))
	if k == 4 {
		return .Culled
	}
	spend(0x80144558 + l, 0x8014456c + l)
	if d.count >= d.budget {
		return .Tail
	}
	spend(0x80144570 + l, 0x80144574 + l)
	if d.count == PACKET_WRAP {
		spend(0x80144578 + l, 0x80144580 + l)
		d.packet = d.wrap
	}
	spend(0x80144584 + l, 0x80144790 + l)
	p = d.packet
	psx.w8(p + 11, 8)
	psx.w8(p + 15, 0x38 | 2)
	for i in 0 ..< 4 {
		g := u8(fog[i] >> 1 + fog[i] >> 2)
		at := p + 12 + 8 * u32(i)
		if i == 0 {
			psx.w8(at, g)
			psx.w8(at + 1, g)
			psx.w8(at + 2, g)
		} else {
			psx.w32(at, u32(g) | u32(g) << 8 | u32(g) << 16 | u32(d.tail[i]) << 24)
		}
		psx.w32(at + 4, sxy[i])
	}
	if world {
		psx.world_quad_add(p + 8, at)
	}
	slot := d.ot + OT_FIRST - 4 + u32(depth) * 4
	ot_insert(slot, p + 8)
	psx.w8(p + 3, 1)
	psx.w32(p + 4, 0xe1000200 | u32(d.fog & 3) << 5)
	ot_insert(slot, p)
	d.count += 1
	d.packet += PACKET_SIZE
	return .Tail
}

// ---------------------------------------------------------------- models
//
// MODELS_DRAW: each placed model of the layer whose bounding box has a point
// in the fixed view's sight and that does not hide from the camera's octant
// goes to MODEL_DRAW, which draws its polygons with its own copy of the quad
// code (MODEL_QUAD).

@(private = "file")
models_draw_native :: proc() {
	sc := &psx.scratch
	events()
	spend(0x80145674, 0x801456a0)
	layer := block_entry(0x80149728, 3, 0xc4, u32(sc[SC_LAYER]))
	spend(0x801456a4, 0x801456c0)
	d := quad_draw_begin()
	visits := sc_u16(SC_VISITS)
	at := layer + 4
	n := psx.r8(layer + 2)
	for i in 0 ..< n {
		if i != 0 {
			events()
		}
		spend(0x801456c4, 0x801456dc)
		m := (^Placed_Model)(ram_ptr(at))^
		if m.flags & PLACED_DRAWN != 0 {
			model_place(&d, &visits, m)
		}
		spend(0x8014590c, 0x8014592c)
		at += size_of(Placed_Model)
	}
	spend(0x80145930, 0x80145954)
	sc_w32(SC_MODEL, at)
	sc_w16(SC_VISITS, visits)
	quad_draw_end(&d)
}

// Entry `i` of the map block table at `table` (count byte at `count_at`), as
// the game's lookup at `at` finds it: 0 past the count.
@(private)
block_entry :: proc(at, count_at, table, i: u32) -> u32 {
	events()
	spend(at, at + 0x20)
	block := psx.r32(MAP_BLOCK)
	if i32(psx.r8(block + count_at)) - 1 < i32(i) {
		spend(at + 0x34, at + 0x38)
		return 0
	}
	spend(at + 0x24, at + 0x30)
	return block + psx.r32(block + table + 4 * i)
}

// (a, c) turned `turn` quarter turns, as the models' corners turn.
@(private = "file")
quarter_turn :: #force_inline proc(turn: u8, a, c: i32) -> [2]i32 {
	switch turn & 3 {
	case 0:
		return {a, c}
	case 1:
		return {c, -a}
	case 2:
		return {-a, -c}
	case:
		return {-c, a}
	}
}

// MODELS_DRAW's look at one placed model.
@(private = "file")
model_place :: proc(d: ^Quad_Draw, visits: ^u16, m: Placed_Model) {
	sc := &psx.scratch
	spend(0x801456e0, 0x801456e8)
	group := block_entry(0x801497dc, 1, 0x24, u32(m.group))
	sc_w32(SC_GROUP, group)
	spend(0x801456ec, 0x80145708)
	turn := m.flags & PLACED_TURN
	sc[SC_TURN] = turn
	switch turn {
	case 0:
		spend(0x8014570c, 0x80145758)
		spend(0x80145868, 0x80145870)
	case 1:
		spend(0x8014575c, 0x80145764)
		spend(0x80145768, 0x801457b4)
		spend(0x8014580c, 0x80145818)
	case 2:
		spend(0x8014575c, 0x80145764)
		spend(0x801457b8, 0x801457bc)
		spend(0x801457c0, 0x80145818)
	case:
		spend(0x8014575c, 0x80145764)
		spend(0x801457b8, 0x801457bc)
		spend(0x8014581c, 0x80145870)
	}
	box := (^[4]i8)(ram_ptr(group + 4))^
	x, z := i32(m.x) << 4, i32(m.z) << 4
	a := quarter_turn(turn, i32(box[0]) * 128, i32(box[1]) * 128)
	b := quarter_turn(turn, i32(box[2]) * 128, i32(box[3]) * 128)
	x0, z0 := i32(i16(x + a[0])), i32(i16(z + a[1]))
	x1, z1 := i32(i16(x + b[0])), i32(i16(z + b[1]))
	spend(0x80145874, 0x801458a4)
	// The centre, then the corners, until one is in sight.
	points := [5][2]i32{{(x0 + x1) >> 1, (z0 + z1) >> 1}, {x0, z0}, {x1, z0}, {x0, z1}, {x1, z1}}
	seen := false
	for p, k in points {
		at := 16 * u32(k)
		if k > 0 {
			spend(0x801458a0 + at, 0x801458a4 + at)
		}
		seen = model_in_sight(u32(p[0]), u32(p[1]))
		spend(0x801458a8 + at, 0x801458ac + at)
		if seen {
			break
		}
	}
	if !seen {
		return
	}
	spend(0x801458f0, 0x801458f8)
	shown := model_unhidden(m)
	spend(0x801458fc, 0x80145900)
	if shown {
		spend(0x80145904, 0x80145908)
		model_draw(d, visits, m, group)
	}
}

// MODEL_IN_VIEW (0x80145c08): whether point (x, z) of a placed model's box is
// in the fixed view's sight.
@(private = "file")
model_in_sight :: proc(x, z: u32) -> bool {
	if models_all_shown() {
		return true
	}
	events()
	sc := &psx.scratch
	dx := x - (u32(sc_u16(SC_SIGHT_X)) + 64)
	dz := z - (u32(sc_u16(SC_SIGHT_Z)) + 64)
	sx, sz := i32(i16(dx)), i32(i16(dz))
	reach, side := i32(i16(sc_u16(SC_REACH))), i32(i16(sc_u16(SC_SIDE)))
	mode := sc[SC_SIGHT_MODE]
	spend(0x80145c08, 0x80145c3c)
	if mode & 1 != 0 {
		spend(0x80145c40, 0x80145c48)
		ax := sx
		if sx <= 0 {
			spend(0x80145c4c, 0x80145c4c)
			ax = i32(i16(-dx))
		}
		spend(0x80145c50, 0x80145c58)
		az := sz
		if sz <= 0 {
			spend(0x80145c5c, 0x80145c5c)
			az = i32(i16(-dz))
		}
		spend(0x80145c60, 0x80145c88)
		if reach < ax + az {
			spend(0x80145c8c, 0x80145c90)
			return false
		}
		spend(0x80145c94, 0x80145ca4)
		if mode & 2 == 0 {
			spend(0x80145ca8, 0x80145cd0)
			if -sx + side < sz {
				spend(0x80145c8c, 0x80145c90)
				return false
			}
			spend(0x80145cd4, 0x80145cdc)
			if !(sz < -sx - side) {
				spend(0x80145d88, 0x80145d8c)
				return true
			}
			spend(0x80145ce0, 0x80145ce4)
		} else {
			spend(0x80145ce8, 0x80145d0c)
			if sz < sx - side {
				spend(0x80145c8c, 0x80145c90)
				return false
			}
			spend(0x80145d10, 0x80145d18)
			if !(sx + side < sz) {
				spend(0x80145d88, 0x80145d8c)
				return true
			}
			spend(0x80145d1c, 0x80145d20)
		}
		spend(0x80145c8c, 0x80145c90)
		return false
	}
	spend(0x80145d24, 0x80145d44)
	if sx < -side {
		spend(0x80145c8c, 0x80145c90)
		return false
	}
	spend(0x80145d48, 0x80145d4c)
	if side < sx {
		spend(0x80145d50, 0x80145d6c)
		if sz < -reach {
			spend(0x80145c8c, 0x80145c90)
			return false
		}
	}
	spend(0x80145d70, 0x80145d84)
	if reach < sz {
		spend(0x80145c8c, 0x80145c90)
		return false
	}
	spend(0x80145d88, 0x80145d8c)
	return true
}

// MODEL_SHOWN (0x80149ee0): whether a placed model shows from the camera's
// octant.
@(private = "file")
model_unhidden :: proc(m: Placed_Model) -> bool {
	if models_all_shown() {
		return true
	}
	events()
	spend(0x80149ee0, 0x80149ef0)
	if m.flags & PLACED_OCTANTS != 0 {
		spend(0x80149ef4, 0x80149f14)
		octant := ((i32(i16(psx.r16(CAMERA_YAW))) + 256) & 4095) >> 9
		if (m.octants >> u32(octant)) & 1 != 0 {
			spend(0x80149f1c, 0x80149f20)
			return false
		}
	}
	spend(0x80149f18, 0x80149f20)
	return true
}

// MODEL_DRAW (0x80145d90): the placed model's polygons whose first corner is
// in the fixed view's sight.
@(private = "file")
model_draw :: proc(d: ^Quad_Draw, visits: ^u16, m: Placed_Model, group: u32) {
	sc := &psx.scratch
	events()
	spend(0x80145d90, 0x80145e3c)
	block := psx.r32(MAP_BLOCK)
	colours := block + psx.r32(block + MODEL_COLOURS)
	colour := colours + u32(psx.r16(colours + 4 + 2 * u32(m.colours)))
	poly := group + 8
	base := [3]u16{u16(m.x) << 4 - 64, u16(m.y) << 4, u16(m.z) << 4 - 64}
	count := psx.r16(group)
	sc_w32(SC_COLOURS, colours)
	sc_w16(SC_TILE_X, base[0])
	sc_w16(SC_TILE_Z, base[2])
	sc_w16(SC_MODEL_Y, base[1])
	sc_w16(SC_POLY_COUNT, count)
	defer {
		sc_w32(SC_COLOUR, colour)
		sc_w32(SC_MODEL_POLY, poly)
	}
	if count == 0 {
		spend(0x80146f7c, 0x80146f9c)
		return
	}
	spend(0x80145e40, 0x80145e50)
	turn := sc[SC_TURN]
	corner :: #force_inline proc(turn: u8, base: [3]u16, c: [3]i8) -> [3]i16 {
		t := quarter_turn(turn, i32(c[0]) * 16, i32(c[2]) * 16)
		return {i16(base[0] + u16(t[0])), i16(base[1] + u16(i32(c[1]) * 16)), i16(base[2] + u16(t[1]))}
	}
	for i in 0 ..< count {
		if i != 0 {
			events()
		}
		spend(0x80145e54, 0x80145e68)
		p := (^Model_Poly)(ram_ptr(poly))^
		d.tail[0] = u8(p.texture)
		switch turn {
		case 0:
			spend(0x80145e6c, 0x80145e84)
			spend(0x80145f18, 0x80145f28)
		case 1:
			spend(0x80145e88, 0x80145e90)
			spend(0x80145e94, 0x80145ec0)
		case 2:
			spend(0x80145e88, 0x80145e90)
			spend(0x80145ec4, 0x80145ecc)
			spend(0x80145ed0, 0x80145efc)
		case:
			spend(0x80145e88, 0x80145e90)
			spend(0x80145ec4, 0x80145ecc)
			spend(0x80145f00, 0x80145f28)
		}
		spend(0x80145f2c, 0x80145f58)
		v0 := corner(turn, base, p.v0)
		if !poly_in_sight(i32(i16(u16(v0[0]) - sc_u16(SC_SIGHT_X))), i32(i16(u16(v0[2]) - sc_u16(SC_SIGHT_Z)))) {
			spend(0x801460b8, 0x801460dc)
			spend(0x80146f68, 0x80146f78)
		} else {
			spend(0x801460e0, 0x801460f4)
			d.tail[1], d.tail[2], d.tail[3] = p.flags, p.spare2, p.spare3
			switch turn {
			case 0:
				spend(0x801460f8, 0x8014618c)
				spend(0x80146398, 0x801463a4)
			case 1:
				spend(0x80146190, 0x80146198)
				spend(0x8014619c, 0x80146240)
			case 2:
				spend(0x80146190, 0x80146198)
				spend(0x80146244, 0x8014624c)
				spend(0x80146250, 0x801462f4)
			case:
				spend(0x80146190, 0x80146198)
				spend(0x80146244, 0x8014624c)
				spend(0x801462f8, 0x801463a4)
			}
			spend(0x801463a8, 0x80146410)
			corners := [4][3]i8{p.v0, p.v1, p.v2, p.v3}
			for c, k in corners {
				d.v[k] = corner(turn, base, c)
				d.rgb[k] = color_unpack(psx.r16(colour + 2 * u32(k)))
				d.uv[k] = u16(p.uv[k])
			}
			slot := u32(i32(p.texture) * 4)
			d.clut, d.tpage = sc_u16(SC_TEXTURE + slot), sc_u16(SC_TEXTURE + slot + 2)
			d.semi, d.far, d.both_sides = p.flags & POLY_SEMI != 0, p.flags & POLY_FAR != 0, p.flags & POLY_DOUBLE != 0
			d.colour_cost = 0
			packets := d.count
			end := quad_draw(d, MODEL_QUAD)
			if d.count != packets {
				sc[SC_PASS] = 2
			}
			if end == .Out_Of_Packets {
				spend(0x80146f7c, 0x80146f9c)
				return
			}
			spend(0x80146f44, 0x80146f78)
		}
		visits^ += 1
		colour += 8
		poly += size_of(Model_Poly)
	}
	spend(0x80146f7c, 0x80146f9c)
}

// MODEL_DRAW's sight test of a polygon's first corner at (sx, sz) from the
// sight's centre: the placed models' test with its box test's side cut
// culling outright. The third-person camera passes every polygon, as it does
// every model (a town's houses past the fixed view's sight lost all of
// theirs).
@(private = "file")
poly_in_sight :: proc(sx, sz: i32) -> bool {
	if models_all_shown() {
		return true
	}
	sc := &psx.scratch
	reach, side := i32(i16(sc_u16(SC_REACH))), i32(i16(sc_u16(SC_SIDE)))
	mode := sc[SC_SIGHT_MODE]
	cull: bool
	if mode & 1 != 0 {
		spend(0x80145f5c, 0x80145f6c)
		ax := sx
		if sx > 0 {
			spend(0x80145f70, 0x80145f74)
		} else {
			spend(0x80145f78, 0x80145f78)
			ax = i32(i16(-sx))
		}
		spend(0x80145f7c, 0x80145f8c)
		az := sz
		if sz > 0 {
			spend(0x80145f90, 0x80145f94)
		} else {
			spend(0x80145f98, 0x80145f98)
			az = i32(i16(-sz))
		}
		spend(0x80145f9c, 0x80145fcc)
		if reach < ax + az {
			return false
		}
		spend(0x80145fd0, 0x80145fe0)
		if mode & 2 == 0 {
			spend(0x80145fe4, 0x80146018)
			if -sx + side < sz {
				return false
			}
			spend(0x8014601c, 0x80146020)
			cull = sz < -sx - side
		} else {
			spend(0x80146024, 0x80146054)
			if sz < sx - side {
				return false
			}
			spend(0x80146058, 0x8014605c)
			cull = sx + side < sz
		}
	} else {
		spend(0x80146060, 0x80146084)
		if sx < -side {
			return false
		}
		spend(0x80146088, 0x8014608c)
		if side < sx {
			return false
		}
		spend(0x80146090, 0x801460ac)
		if sz < -reach {
			return false
		}
		cull = reach < sz
	}
	spend(0x801460b0, 0x801460b4)
	return !cull
}

// Link the packet at `p` in at the head of the ordering table slot `slot`.
@(private = "file")
ot_insert :: #force_inline proc(slot, p: u32) {
	link := psx.r32(slot)
	psx.w32(p, psx.r32(p) & 0xff000000 | link & 0xffffff)
	psx.w32(slot, link & 0xff000000 | p & 0xffffff)
}

@(private)
ram_ptr :: #force_inline proc(addr: u32) -> rawptr {return &psx.ram[addr & (psx.RAM_SIZE - 1)]}
@(private)
sc_u16 :: #force_inline proc(o: u32) -> u16 {return psx.r16(psx.SCRATCH_BASE + (o & (psx.SCRATCH_SIZE - 1)))}
@(private)
sc_u32 :: #force_inline proc(o: u32) -> u32 {return psx.r32(psx.SCRATCH_BASE + (o & (psx.SCRATCH_SIZE - 1)))}
@(private)
sc_w16 :: #force_inline proc(o: u32, v: u16) {psx.w16(psx.SCRATCH_BASE + o, v)}
@(private)
sc_w32 :: #force_inline proc(o: u32, v: u32) {psx.w32(psx.SCRATCH_BASE + o, v)}

// ---------------------------------------------------------------- checks

// Every layer of the loaded map decodes and encodes back to the same bytes.
// Runs once per map block (by checksum).
@(private = "file")
map_check_layers :: proc() {
	spans: [8][2]u32
	n := map_layer_spans(&spans)
	sum := u32(n)
	for s in spans[:n] {
		for b in psx.mem_slice(s[0], s[1] - s[0]) {
			sum = sum * 31 + u32(b)
		}
	}
	if sum == map_geometry.block_seen {
		return
	}
	map_geometry.block_seen = sum
	map_check_floors()
	for s, i in spans[:n] {
		data := psx.mem_slice(s[0], s[1] - s[0])
		l, ok := map_layer_decode(data)
		if !ok {
			fmt.eprintfln("mapcheck: layer %d at %#08x does not decode", i, s[0])
			continue
		}
		out := map_layer_encode(l, context.temp_allocator)
		same := len(out) == len(data)
		for k := 0; same && k < len(out); k += 1 {
			same = out[k] == data[k]
		}
		fmt.eprintfln("mapcheck: layer %d at %#08x %dx%d, %d tiles, %d refs, %d polygons: round trip %s",
			i, s[0], l.width, len(l.rows), len(l.tiles), len(l.refs), len(l.polys), same ? "same" : "DIFFERS")
	}
}

// Run the game's drawing and the native one from the same state and compare
// RAM and the scratch words `interface` the drawing leaves; with `result`,
// also the v0 and GTE state each leaves.
@(private)
map_check_draw :: proc(game: psx.Func_Proc, native: proc(), interface: []u32, label: string, result := false, stack: u32 = 0x100) {
	@(static) before, after: [psx.RAM_SIZE]u8
	@(static) sc_before, sc_after: [psx.SCRATCH_SIZE]u8
	// Hooked functions the two passes call run natively, unchecked: the
	// buffers above hold this check.
	map_geometry.check = false
	defer map_geometry.check = true
	sp := psx.cpu.r[29] & (psx.RAM_SIZE - 1)
	before = psx.ram
	sc_before = psx.scratch
	gte_before := psx.gte_save()
	event_due := psx.next_event
	start := psx.cpu.cycles
	game()
	// Interrupts that came due while the game's passes ran change RAM; the
	// native passes run with them held off, so only untimed drawings compare.
	timed := psx.cpu.cycles >= event_due
	game_end, next := psx.cpu.cycles, psx.next_event
	after = psx.ram
	sc_after = psx.scratch
	gte_after := psx.gte_save()
	cpu_after := psx.cpu
	psx.ram_touch(0, psx.RAM_SIZE)
	psx.ram = before
	psx.scratch = sc_before
	psx.gte_load(gte_before)
	psx.cpu.cycles, psx.next_event = start, psx.EVENT_OFF
	native()
	native_cycles := psx.cpu.cycles - start
	psx.cpu.cycles, psx.next_event = game_end, next
	map_geometry.checked += 1
	if !timed && native_cycles != game_end - start {
		map_geometry.cycle_misses += 1
		if map_geometry.cycle_misses <= 10 {
			fmt.eprintfln("mapcheck: %s: game took %d cycles, native %d (%d packets)",
				label, game_end - start, native_cycles, sc_u16(SC_COUNT))
		}
	}
	bad := 0
	run_start := -1
	for i in 0 ..= psx.RAM_SIZE {
		differs := i < psx.RAM_SIZE && psx.ram[i] != after[i] && (u32(i) >= sp || u32(i) < sp - stack)
		if differs {
			bad += 1
			if run_start < 0 {
				run_start = i
			}
		} else if run_start >= 0 {
			if map_geometry.mismatches < 6 && !timed {
				fmt.eprintfln("mapcheck: %s: ram %#08x..%#08x differs (game %02x native %02x)",
					label, 0x80000000 + run_start, 0x80000000 + i, after[run_start], psx.ram[run_start])
			}
			run_start = -1
		}
	}
	for o in interface {
		if psx.scratch[o] != sc_after[o] {
			if bad < 4 && map_geometry.mismatches < 40 {
				fmt.eprintfln("mapcheck: %s: scratch %#x game %02x native %02x", label, o, sc_after[o], psx.scratch[o])
			}
			bad += 1
		}
	}
	if result && psx.cpu.r[2] != cpu_after.r[2] {
		if map_geometry.mismatches < 40 {
			fmt.eprintfln("mapcheck: %s: v0 game %#x native %#x", label, cpu_after.r[2], psx.cpu.r[2])
		}
		bad += 1
	}
	if result && psx.gte_save() != gte_after {
		if map_geometry.mismatches < 40 {
			fmt.eprintfln("mapcheck: %s: GTE state differs", label)
		}
		bad += 1
	}
	if bad != 0 && timed {
		map_geometry.timed += 1
	} else if bad != 0 {
		map_geometry.mismatches += 1
	}
	if map_geometry.checked % 200 == 0 || (bad != 0 && !timed && map_geometry.mismatches <= 10) {
		fmt.eprintfln("mapcheck: %d drawings, %d differ, %d more across an interrupt, %d in cycles (this one %s, %d bytes, %d packets)",
			map_geometry.checked, map_geometry.mismatches, map_geometry.timed, map_geometry.cycle_misses, label, bad, sc_u16(SC_COUNT))
	}
	// Keep the game's own result so the run plays on as without the check.
	psx.ram_touch(0, psx.RAM_SIZE)
	psx.ram = after
	psx.scratch = sc_after
	psx.gte_load(gte_after)
	psx.cpu = cpu_after
}

// A triangle of map geometry, corners in view units of its layer's frame.
Map_Tri :: [3][3]f32

// How far past its tile (tiles) a tile's polygons may reach: corners are
// i8 units of 16 from the tile's corner, so a roof can hang over the next
// tiles.
@(private = "file")
TILE_SPILL :: 2
// How far from a placed model's place (view units) its polygons reach.
@(private = "file")
MODEL_REACH :: 2048

// The polygons of `layer` (counted from the map's first) near the box
// `lo`..`hi` (view x, z), two triangles a quad: its tiles' own polygons and
// its drawn placed models, as the passes place them, moved by `shift`. Fills
// `out`; returns how many.
@(private)
layer_tris :: proc(layer: u32, shift: [3]f32, lo, hi: [2]f32, out: []Map_Tri) -> int {
	desc := layer_desc(layer)
	if desc == 0 {
		return 0
	}
	block := psx.r32(MAP_BLOCK)
	header := block + psx.r32(block + 4 + 4 * u32(psx.r8(desc)))
	if !in_ram(header) {
		return 0
	}
	h := (^Layer_Header)(ram_ptr(header))^
	n := 0
	add_quad :: proc(out: []Map_Tri, n: ^int, v: [4][3]f32, shift: [3]f32) {
		if n^ + 2 <= len(out) {
			out[n^], out[n^ + 1] = {v[0] + shift, v[1] + shift, v[2] + shift}, {v[1] + shift, v[3] + shift, v[2] + shift}
			n^ += 2
		}
	}
	lo, hi := lo - shift.xz, hi - shift.xz
	// Tile tx spans view x 256 tx - 64 .. 256 tx + 192.
	t0 := [2]i32{i32(math.floor((lo.x + 64) / 256)), i32(math.floor((lo.y + 64) / 256))} - TILE_SPILL
	t1 := [2]i32{i32(math.floor((hi.x + 64) / 256)), i32(math.floor((hi.y + 64) / 256))} + TILE_SPILL
	for tz in max(t0.y, 0) ..= min(t1.y, i32(h.rows) - 1) {
		row := (^Map_Row)(ram_ptr(header + u32(h.row_at) + u32(tz) * size_of(Map_Row)))^
		for tx in max(t0.x, i32(row.x)) ..= min(t1.x, i32(row.x) + i32(row.count) - 1) {
			tile := header + u32(h.tile_at) + (u32(row.first) + u32(tx - i32(row.x))) * size_of(Map_Tile)
			raw := (^[4]u8)(ram_ptr(tile))^
			first, count: u32
			if raw[0] & TILE_GROUND != 0 {
				i := u32(raw[1]) + u32(raw[2] & 0xc0) << 2
				if i == REF_NONE {
					continue
				}
				ref := (^Poly_Ref)(ram_ptr(header + u32(h.ref_at) + i * size_of(Poly_Ref)))^
				first, count = u32(ref.first), u32(ref.count)
			} else {
				first, count = u32(raw[2]) | u32(raw[3]) << 8, (u32(raw[0]) | u32(raw[1]) << 8) >> 1
			}
			x, z := f32(tx * 256 - 64), f32(tz * 256 - 64)
			for k in 0 ..< count {
				p := (^Map_Poly)(ram_ptr(header + u32(h.poly_at) + (first + k) * size_of(Map_Poly)))^
				v: [4][3]f32
				for c, i in ([4][3]i8{p.v0, p.v1, p.v2, p.v3}) {
					v[i] = {x + f32(c[0]) * 16, f32(c[1]) * 16, z + f32(c[2]) * 16}
				}
				add_quad(out, &n, v, shift)
			}
		}
	}
	at := desc + 4
	for _ in 0 ..< u32(psx.r8(desc + 2)) {
		m := (^Placed_Model)(ram_ptr(at))^
		at += size_of(Placed_Model)
		base := [3]f32{f32(m.x) * 16 - 64, f32(m.y) * 16, f32(m.z) * 16 - 64}
		if m.flags & PLACED_DRAWN == 0 || base.x < lo.x - MODEL_REACH || base.x > hi.x + MODEL_REACH ||
		   base.z < lo.y - MODEL_REACH || base.z > hi.y + MODEL_REACH {
			continue
		}
		group := block_entry_of(1, 0x24, u32(m.group))
		if group == 0 {
			continue
		}
		poly := group + 8
		for _ in 0 ..< u32(psx.r16(group)) {
			p := (^Model_Poly)(ram_ptr(poly))^
			poly += size_of(Model_Poly)
			v: [4][3]f32
			for c, i in ([4][3]i8{p.v0, p.v1, p.v2, p.v3}) {
				t := quarter_turn(m.flags & PLACED_TURN, i32(c[0]) * 16, i32(c[2]) * 16)
				v[i] = base + {f32(t[0]), f32(c[1]) * 16, f32(t[1])}
			}
			add_quad(out, &n, v, shift)
		}
	}
	return n
}

// block_entry without the game's timing.
@(private = "file")
block_entry_of :: proc(count_at, table, i: u32) -> u32 {
	block := psx.r32(MAP_BLOCK)
	if u32(psx.r8(block + count_at)) <= i {
		return 0
	}
	return block + psx.r32(block + table + 4 * i)
}

// Where the segment from `a` to `b` first meets one of `tris` (from either
// side), as a share of the way along it; 1 when it meets none.
@(private)
segment_hit :: proc(a, b: [3]f32, tris: []Map_Tri) -> f32 {
	d := b - a
	near := f32(1)
	for t in tris {
		e1, e2 := t[1] - t[0], t[2] - t[0]
		p := linalg.cross(d, e2)
		det := linalg.dot(e1, p)
		if abs(det) < 1e-6 {
			continue
		}
		s := a - t[0]
		u := linalg.dot(s, p) / det
		if u < 0 || u > 1 {
			continue
		}
		q := linalg.cross(s, e1)
		v := linalg.dot(d, q) / det
		if v < 0 || u + v > 1 {
			continue
		}
		f := linalg.dot(e2, q) / det
		if f > 0 && f < near {
			near = f
		}
	}
	return near
}
