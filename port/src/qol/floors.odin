// Floors: the layer descriptors of the loaded map block as the step and
// ground code see them, decoded into a port-side model that can be written
// back, and a dump of every floor's cells (attribute and ground height) for
// map tools.
//
// A descriptor (map block +0xc4 table, count at +3) is one walkable floor:
//
//   +0 u8 layer (tile grid, +0x04 table) whose tiles give its ground
//   +1 u8 attribute grid (+0xa4 table, count at +2)
//   +2 u8 placed models, 12 bytes each from +4 (Placed_Model)
//   +3 u8 flags: bit 0 lit ground, bits 1-3 layers - 1
//
// A section is the run of floors from the descriptor with its index, as many
// as that descriptor's layers (020b's section 4 is floors 4 and 5). Floors
// with their own attribute grid are the Z levels of one room, stairs (cells
// of kind 0xc0) lead between them (0201's tavern hall, floors 2 and 3);
// floors sharing a grid are extra tile layers over one floor (1000). The attribute grid has one byte per cell, (layer width * 2) x
// (rows * 2) cells, row by row; a cell is half a tile, 256 units of GROUND's
// position. Each section has its own coordinates: neighbouring rooms sit side
// by side (sections.odin places them).
package qol

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import cpu "ps:psx/cpu"

import "ps:core"

@(private = "file")
SECTION_COUNT :: 3
@(private = "file")
SECTION_TABLE :: 0xc4
@(private = "file")
ATTRS_COUNT :: 2
@(private = "file")
ATTRS_TABLE :: 0xa4
@(private = "file")
LAYER_COUNT :: 0
@(private = "file")
LAYER_TABLE :: 0x04

FLOOR_LIT :: 0x01
FLOOR_LAYERS :: 0x0e // layers - 1, on a section's first floor

Map_Floor :: struct {
	layer:  u8,
	attrs:  u8, // attribute grid index
	flags:  u8, // FLOOR_*
	models: []Placed_Model,
}

// The section bytes at `data` (at least the header and its models).
map_floor_decode :: proc(data: []u8) -> (f: Map_Floor, ok: bool) {
	if len(data) < 4 || len(data) < 4 + int(data[2]) * size_of(Placed_Model) {
		return
	}
	f.layer, f.attrs, f.flags = data[0], data[1], data[3]
	f.models = mem.slice_data_cast([]Placed_Model, data[4:])[:data[2]]
	return f, true
}

map_floor_encode :: proc(f: Map_Floor, allocator := context.allocator) -> []u8 {
	out := make([]u8, 4 + len(f.models) * size_of(Placed_Model), allocator)
	out[0], out[1], out[2], out[3] = f.layer, f.attrs, u8(len(f.models)), f.flags
	copy(out[4:], mem.slice_to_bytes(f.models))
	return out
}

// Entry `i` of a map block table, 0 past its count.
@(private = "file")
floor_entry :: proc(block, count_at, table, i: u32) -> u32 {
	if i >= u32(cpu.r8(block + count_at)) {
		return 0
	}
	return block + cpu.r32(block + table + 4 * i)
}

// Section `i` of the loaded map: its bytes, the attribute grid and its size
// in cells.
@(private = "file")
floor_at :: proc(i: u32) -> (desc: u32, data: []u8, attrs: []u8, across, down: int, ok: bool) {
	block := cpu.r32(MAP_BLOCK)
	desc = floor_entry(block, SECTION_COUNT, SECTION_TABLE, i)
	if desc == 0 {
		return
	}
	data = cpu.mem_slice(desc, 4 + u32(cpu.r8(desc + 2)) * size_of(Placed_Model))
	grid := floor_entry(block, LAYER_COUNT, LAYER_TABLE, u32(data[0]))
	at := floor_entry(block, ATTRS_COUNT, ATTRS_TABLE, u32(data[1]))
	if grid == 0 || at == 0 {
		return
	}
	across, down = int(cpu.r16(grid)) * 2, int(cpu.r16(grid + 2)) * 2
	attrs = cpu.mem_slice(at, u32(across * down))
	return desc, data, attrs, across, down, true
}

// The cells of the loaded map's section `i` one can stand on (any kind but
// walls, 0x1x), as a box: lo and hi past the last; false when there are none.
@(private)
floor_open_box :: proc(i: u32) -> (lo, hi: [2]int, ok: bool) {
	_, _, attrs, across, down, found := floor_at(i)
	if !found {
		return
	}
	lo, hi = {max(int), max(int)}, {min(int), min(int)}
	for z in 0 ..< down {
		for x in 0 ..< across {
			if attrs[z * across + x] >> 4 != 1 {
				lo, hi = {min(lo.x, x), min(lo.y, z)}, {max(hi.x, x + 1), max(hi.y, z + 1)}
			}
		}
	}
	return lo, hi, lo.x < hi.x
}

// Every section of the loaded map decodes and encodes back to its bytes.
@(private)
map_check_floors :: proc() {
	block := cpu.r32(MAP_BLOCK)
	for i in 0 ..< u32(cpu.r8(block + SECTION_COUNT)) {
		desc, data, _, across, down, ok := floor_at(i)
		f: Map_Floor
		if ok {
			f, ok = map_floor_decode(data)
		}
		if !ok {
			fmt.eprintfln("mapcheck: floor %d does not decode", i)
			continue
		}
		out := map_floor_encode(f, context.temp_allocator)
		same := len(out) == len(data)
		for k := 0; same && k < len(out); k += 1 {
			same = out[k] == data[k]
		}
		fmt.eprintfln("mapcheck: floor %d at %#08x layer %d, attrs %d %dx%d, %d models: round trip %s",
			i, desc, f.layer, f.attrs, across, down, len(f.models), same ? "same" : "DIFFERS")
	}
}

// ---------------------------------------------------------------- dump

floors: struct {
	dump_dir: string, // BOF4_FLOORDUMP: where each map's floors go
	dumped:   map[[2]u32]bool, // map, section bytes checksum: dumped
	blocks:   map[u16]int, // map: blocks dumped for it
}

// Once per map and block: write `<map>.json` with every floor's cells. A map
// can show more than one block (door rooms swap theirs in each frame); the
// others go to `<map>-<n>.json`. The checksum leaves out the attribute grids,
// which the game writes as things move.
@(private)
floors_dump :: proc() {
	if floors.dump_dir == "" {
		return
	}
	block := cpu.r32(MAP_BLOCK)
	count := u32(cpu.r8(block + SECTION_COUNT))
	sum := count
	for i in 0 ..< count {
		_, data, _, _, _, ok := floor_at(i)
		if !ok {
			return
		}
		for b in data {
			sum = sum * 31 + u32(b)
		}
	}
	id := cpu.r16(MAP_ID)
	key := [2]u32{u32(id), sum}
	if key in floors.dumped {
		return
	}
	floors.dumped[key] = true
	n := floors.blocks[id]
	floors.blocks[id] = n + 1

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "{{\"map\": \"%04x\", \"floors\": [", id)
	for i in 0 ..< count {
		desc, data, attrs, across, down, _ := floor_at(i)
		f, _ := map_floor_decode(data)
		fmt.sbprintf(&b, "%s\n {{\"floor\": %d, \"layer\": %d, \"attrs\": %d, \"lit\": %v, \"layers\": %d, \"width\": %d, \"depth\": %d, \"models\": %d,\n  \"cells\": [",
			i == 0 ? "" : ",", i, f.layer, f.attrs, f.flags & FLOOR_LIT != 0, (f.flags & FLOOR_LAYERS) >> 1 + 1, across, down, len(f.models))
		for z in 0 ..< down {
			fmt.sbprintf(&b, "%s\n   \"", z == 0 ? "" : ",")
			for x in 0 ..< across {
				fmt.sbprintf(&b, "%s%02x", x == 0 ? "" : " ", attrs[z * across + x])
			}
			strings.write_byte(&b, '"')
		}
		strings.write_string(&b, "],\n  \"ground\": [")
		for z in 0 ..< down {
			fmt.sbprintf(&b, "%s\n   [", z == 0 ? "" : ",")
			for x in 0 ..< across {
				fmt.sbprintf(&b, "%s%d", x == 0 ? "" : ",", ground_probe(desc, i32(x), i32(z)))
			}
			strings.write_byte(&b, ']')
		}
		strings.write_string(&b, "]}")
	}
	strings.write_string(&b, "]}\n")
	path := n == 0 ? fmt.tprintf("%s/%04x.json", floors.dump_dir, id) : fmt.tprintf("%s/%04x-%d.json", floors.dump_dir, id, n)
	if err := os.write_entire_file(path, transmute([]u8)strings.to_string(b)); err != nil {
		fmt.eprintfln("floors: cannot write %s", path)
		return
	}
	core.tracef(.Game, "floors: %04x: %d floors to %s", id, count, path)
}
