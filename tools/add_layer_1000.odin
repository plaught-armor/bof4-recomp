// Example: give map 1000 a new drawn layer (docs/field.md, Adding a drawn
// layer).
//
// Takes an unpacked block (map-block unpack) and writes a copy with layer 3:
// a raised platform and ramp of new tiles with stone side walls, walked as
// floor 3 (its own attribute grid 1), stairs from floor 0 at x 17.
//
//     bof4tools map-block unpack mods/1000.blk work/1000
//     bof4tools add-layer-1000 work/1000 work/1000-l3
//     bof4tools map-block pack work/1000-l3 mods/1000.blk
package tools

import "core:os"

ADD_LAYER_1000_USAGE :: "Usage: bof4tools add-layer-1000 <unpacked 1000 dir> <out dir>"

// Platform height, steps of 16 drawing units.
PLATFORM :: 12

// A side wall: its two corners along the edge (bottom a, bottom b; the top
// ones above them, outward facing) and the tile heights at them.
Wall_Side :: struct {
	a, b:   [2]i8,
	ha, hb: int,
	minus:  bool, // faces -x or -z: the darker colour
}

WALL_MINUS_Z :: Wall_Side{{0, 0}, {16, 0}, 0, 1, true}
WALL_PLUS_Z :: Wall_Side{{16, 16}, {0, 16}, 3, 2, false}
WALL_PLUS_X :: Wall_Side{{16, 0}, {16, 16}, 1, 3, false}

add_layer_1000_main :: proc(args: []string) {
	usage(args, ADD_LAYER_1000_USAGE, 2)
	src, dst := args[0], args[1]
	os.remove_all(dst)
	for rel in walk_sorted(src) {
		path := join(dst, rel)
		make_dirs(join(path, ".."))
		write_file(path, read_file(join(src, rel)))
	}

	ramp := [5][4]i8{{0, 6, 0, 6}, {6, PLATFORM, 6, PLATFORM}, PLATFORM, PLATFORM, PLATFORM}
	layer: [dynamic]u8
	append_u16 :: proc(out: ^[dynamic]u8, v: int) {append(out, u8(v), u8(v >> 8))}
	TILES :: 10
	ROWS :: 17
	tile_at := 0x14 + 4 * ROWS
	ref_at := tile_at + 16 * TILES
	poly_at := ref_at + 4 * TILES
	append_u16(&layer, 14)
	append_u16(&layer, ROWS)
	for at in ([]int{0x14, tile_at, ref_at, poly_at}) {
		append_u32(&layer, u32(at))
	}
	for _ in 0 ..< 15 {
		append(&layer, 0, 0, 0, 0)
	}
	append(&layer, 9, 5, 0, 0, 9, 5, 5, 0)
	refs, polys: [dynamic]u8
	poly_count := 0
	for i in 0 ..< TILES {
		x, z := 9 + i % 5, 15 + i / 5
		h := ramp[i % 5]
		sides: [2]Wall_Side
		n := 0
		sides[n] = z == 15 ? WALL_MINUS_Z : WALL_PLUS_Z
		n += 1
		if x == 13 {
			sides[n] = WALL_PLUS_X
			n += 1
		}
		append(&layer, 7, u8(i), 0x04, 0)
		for c in h {
			append(&layer, u8(c))
		}
		for _ in 0 ..< 4 {
			append_u16(&layer, 21139)
		}
		append_u16(&refs, n)
		append_u16(&refs, poly_count)
		for s in sides[:n] {
			top_a, top_b := h[s.ha], h[s.hb]
			v := [4][3]i8{{s.a[0], 0, s.a[1]}, {s.b[0], 0, s.b[1]}, {s.a[0], top_a, s.a[1]}, {s.b[0], top_b, s.b[1]}}
			after := [4]u8{4, 0, 9, 0} // texture (layer 2's stone), flags, spare
			for k in 0 ..< 4 {
				append(&polys, u8(v[k][0]), u8(v[k][1]), u8(v[k][2]), after[k])
			}
			append(&polys, 31, 143, 0, 143, 31, u8(143 - 2 * int(top_a)), 0, u8(143 - 2 * int(top_b)))
			for _ in 0 ..< 4 {
				append_u16(&polys, s.minus ? 26423 : 16913)
			}
			poly_count += 1
		}
	}
	append(&layer, ..refs[:])
	append(&layer, ..polys[:])
	write_file(join(dst, "layer3.json"), layer_json(layer[:], .Spaced))
	write_file(join(dst, "floor3.json"), floor_json([]u8{3, 1, 0, 1}, .Spaced))
	f0_path := join(dst, "floor0.json")
	f0 := floor_bytes(json_parse(f0_path, read_file(f0_path)))
	f0[3] = 0x7
	write_file(f0_path, floor_json(f0))

	W :: 28
	D :: 34
	a1 := make([]u8, W * D)
	for &c in a1 {
		c = 0x10
	}
	for z in 30 ..< 34 {
		for x in 18 ..< 28 {
			a1[z * W + x] = 0
		}
	}
	for z in 31 ..< 34 {
		a1[z * W + 18] = 0xc7
	}
	write_file(join(dst, "attrs1.bin"), a1)
	a0_path := join(dst, "attrs0.bin")
	a0 := read_file(a0_path)
	for z in 31 ..< 34 {
		if a0[z * 50 + 17] != 0 {
			fail("attrs0.bin: cell (17, %d) is %#x, not floor: not map 1000's grid", z, a0[z * 50 + 17])
		}
		a0[z * 50 + 17] = 0xc1
	}
	write_file(a0_path, a0)
}
