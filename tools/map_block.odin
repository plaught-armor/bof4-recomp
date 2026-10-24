// Extract a field map's data block, take it apart for editing, put it back.
//
// The block is the EMI entry a map file loads at 0x80069800 (layout in
// docs/field.md, "Map geometry", "Floors" and "Edited maps"). The port loads
// an edited block from BOF4_MAPS=<dir>/<map>.blk in place of the disc's.
//
// Ground: a ground tile (flags bit 0) has four corner heights in units of 16
// (corners (x,z) (x+1,z) (x,z+1) (x+1,z+1)); GROUND and the drawn quad both
// follow them. Limits: the block must stay at most 0x1a000 bytes (the
// party's models load at 0x80083800). Cell kinds (high nibble): 0x0 floor,
// 0x1 wall, 0xa exit, 0xc stair; see docs/field.md "Collision grid".
package tools

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

MAP_BLOCK_USAGE :: `Usage:
  bof4tools map-block extract <disc BIN dir> <map> <out.blk>
      <map> in hex (0201); writes the disc's block.
  bof4tools map-block unpack <in.blk> <dir>
      writes the block's parts: header.bin, layer<n>.json (tile grid, ground
      heights, polygons), group<n>.bin (model groups), attrs<n>.bin
      (attribute grids), floor<n>.json (floor descriptors and their placed
      models), extra.bin (the +0x124 table, when there is one), colours.bin.
  bof4tools map-block pack <dir> <out.blk>
      builds a block from those parts, laying them out again; parts may
      change size. A missing part file leaves its table entry empty; a part
      numbered past the header's count (attrs1.bin in a block with one
      grid) raises the count.
  bof4tools map-block cells <in.blk> <floors.json> <out.blk>
      writes the "cells" rows of each floor of a BOF4_FLOORDUMP file into the
      floor's attribute grid. Floors that share a grid must agree.`

MAP_DATA :: 0x80069800
MAP_MAX_SIZE :: 0x83800 - 0x69800
MAP_HEADER :: 0x134

Map_Table :: struct {
	name:     string,
	count_at: int, // header byte holding the table's count
	table:    int,
	slots:    int,
	suffix:   string,
}

// The offset tables, then the single offsets after them: +0x124 (optional)
// and the colour table.
MAP_TABLES :: [4]Map_Table {
	{"layer", 0, 0x04, 8, ".json"},
	{"group", 1, 0x24, 32, ".bin"},
	{"attrs", 2, 0xa4, 8, ".bin"},
	{"floor", 3, 0xc4, 8, ".json"},
}
MAP_SINGLES :: [2]struct {
	name: string,
	word: int,
} {{"extra", 0x124}, {"colours", 0x128}}

Map_Part :: struct {
	name: string,
	data: []u8,
}

map_block_main :: proc(args: []string) {
	if len(args) == 0 {
		fail("%s", MAP_BLOCK_USAGE)
	}
	switch args[0] {
	case "extract":
		usage(args, MAP_BLOCK_USAGE, 4)
		map_extract(args[1], int(parse_hex(args[2])), args[3])
	case "unpack":
		usage(args, MAP_BLOCK_USAGE, 3)
		map_unpack(args[1], args[2])
	case "pack":
		usage(args, MAP_BLOCK_USAGE, 3)
		map_pack(args[1], args[2])
	case "cells":
		usage(args, MAP_BLOCK_USAGE, 4)
		map_cells(args[1], args[2], args[3])
	case:
		fail("%s", MAP_BLOCK_USAGE)
	}
}

map_emi_path :: proc(bin_dir: string, m: int) -> string {
	AREA :: [4]struct {
		bit:    int,
		letter: string,
	}{{0x1000, "M"}, {0x0200, "S"}, {0x0400, "D"}, {0x0800, "E"}}
	for a in AREA {
		if m & a.bit != 0 {
			return join(bin_dir, "WORLD", fmt.aprintf("AREA%s%03d.EMI", a.letter, m & 0xff))
		}
	}
	fail("map %04x: no area bit", m)
}

map_extract :: proc(bin_dir: string, m: int, out_path: string) {
	for e in emi_entries(read_file(map_emi_path(bin_dir, m))) {
		if e.addr == MAP_DATA {
			write_file(out_path, e.data)
			print("%s: %d bytes", out_path, len(e.data))
			return
		}
	}
	fail("map %04x: no block entry", m)
}

// The block's parts in block order.
map_parts :: proc(b: []u8) -> []Map_Part {
	Place :: struct {
		name: string,
		at:   int,
	}
	places: [dynamic]Place
	for t in MAP_TABLES {
		for i in 0 ..< min(int(b[t.count_at]), t.slots) {
			if at := int(u32le(b, t.table + 4 * i)); at != 0 {
				append(&places, Place{fmt.aprintf("%s%d%s", t.name, i, t.suffix), at})
			}
		}
	}
	for s in MAP_SINGLES {
		if at := int(u32le(b, s.word)); at != 0 {
			append(&places, Place{concat(s.name, ".bin"), at})
		}
	}
	if len(places) == 0 || places[0].at != MAP_HEADER {
		fail("parts out of order")
	}
	parts := make([]Map_Part, len(places))
	for p, i in places {
		end := i + 1 < len(places) ? places[i + 1].at : len(b)
		if end < p.at {
			fail("parts out of order")
		}
		parts[i] = {p.name, b[p.at:end]}
	}
	return parts
}

layer_json :: proc(d: []u8, style := Json_Style.Compact) -> []u8 {
	width, rows := int(u16le(d, 0)), int(u16le(d, 2))
	row_at, tile_at := int(u32le(d, 4)), int(u32le(d, 8))
	ref_at, poly_at := int(u32le(d, 12)), int(u32le(d, 16))
	if row_at != 0x14 || tile_at != row_at + 4 * rows {
		fail("layer: unexpected table offsets")
	}
	w := jw_make(style)
	jw_open(&w, '{')
	jw_field(&w, "width", width)
	jw_key(&w, "rows")
	jw_open(&w, '[')
	for i in 0 ..< rows {
		at := row_at + 4 * i
		jw_ints(&w, int(d[at]), int(d[at + 1]), int(u16le(d, at + 2)))
	}
	jw_close(&w, ']')
	jw_key(&w, "tiles")
	jw_open(&w, '[')
	for at := tile_at; at < ref_at; at += 16 {
		t := d[at:at + 16]
		jw_open(&w, '{')
		jw_key(&w, "heights")
		jw_ints(&w, int(i8(t[4])), int(i8(t[5])), int(i8(t[6])), int(i8(t[7])))
		jw_key(&w, "colors")
		jw_ints(&w, int(u16le(t, 8)), int(u16le(t, 10)), int(u16le(t, 12)), int(u16le(t, 14)))
		if t[0] & 1 != 0 {
			jw_field(&w, "flags", int(t[0]))
			jw_field(&w, "ref", int(t[1]))
			jw_field(&w, "page", int(t[2]))
			jw_field(&w, "cell", int(t[3]))
		} else {
			count2, first := int(u16le(t, 0)), int(u16le(t, 2))
			jw_key(&w, "polys")
			jw_ints(&w, first, count2 >> 1)
			jw_field(&w, "low", count2 & 1)
		}
		jw_close(&w, '}')
	}
	jw_close(&w, ']')
	jw_key(&w, "refs")
	jw_open(&w, '[')
	for at := ref_at; at < poly_at; at += 4 {
		jw_ints(&w, int(u16le(d, at)), int(u16le(d, at + 2)))
	}
	jw_close(&w, ']')
	jw_key(&w, "polys")
	jw_open(&w, '[')
	for at := poly_at; at + 32 <= len(d); at += 32 {
		p := d[at:at + 32]
		s :: proc(b: u8) -> int {return int(i8(b))}
		jw_open(&w, '{')
		jw_key(&w, "v")
		jw_open(&w, '[')
		for k in 0 ..< 4 {
			jw_ints(&w, s(p[4 * k]), s(p[4 * k + 1]), s(p[4 * k + 2]))
		}
		jw_close(&w, ']')
		jw_field(&w, "texture", s(p[3]))
		jw_field(&w, "flags", int(p[7]))
		jw_key(&w, "spare")
		jw_ints(&w, int(p[11]), int(p[15]))
		jw_key(&w, "uv")
		jw_open(&w, '[')
		for k in 0 ..< 4 {
			jw_ints(&w, int(p[16 + 2 * k]), int(p[17 + 2 * k]))
		}
		jw_close(&w, ']')
		jw_key(&w, "colors")
		jw_ints(&w, int(u16le(p, 24)), int(u16le(p, 26)), int(u16le(p, 28)), int(u16le(p, 30)))
		jw_close(&w, '}')
	}
	jw_close(&w, ']')
	jw_close(&w, '}')
	return jw_bytes(&w)
}

layer_bytes :: proc(l: json.Value) -> []u8 {
	rows := json_list_at(l, "rows")
	tiles := json_list_at(l, "tiles")
	refs := json_list_at(l, "refs")
	tile_at := 0x14 + 4 * len(rows)
	ref_at := tile_at + 16 * len(tiles)
	poly_at := ref_at + 4 * len(refs)
	out: [dynamic]u8
	append_u16 :: proc(out: ^[dynamic]u8, v: int) {append(out, u8(v), u8(v >> 8))}
	append_u16(&out, json_int_at(l, "width"))
	append_u16(&out, len(rows))
	append_u32(&out, 0x14)
	append_u32(&out, u32(tile_at))
	append_u32(&out, u32(ref_at))
	append_u32(&out, u32(poly_at))
	for r in rows {
		r := json_list(r)
		append(&out, u8(json_int(r[0])), u8(json_int(r[1])))
		append_u16(&out, json_int(r[2]))
	}
	for t in tiles {
		if polys, ok := json_get(t, "polys"); ok {
			polys := json_list(polys)
			low, has_low := json_get(t, "low")
			append_u16(&out, json_int(polys[1]) << 1 | (has_low ? json_int(low) : 0))
			append_u16(&out, json_int(polys[0]))
		} else {
			for k in ([]string{"flags", "ref", "page", "cell"}) {
				append(&out, u8(json_int_at(t, k)))
			}
		}
		for h in json_list_at(t, "heights") {
			append(&out, u8(json_int(h)))
		}
		for c in json_list_at(t, "colors") {
			append_u16(&out, json_int(c))
		}
	}
	for r in refs {
		r := json_list(r)
		append_u16(&out, json_int(r[0]))
		append_u16(&out, json_int(r[1]))
	}
	for p in json_list_at(l, "polys") {
		v := json_list_at(p, "v")
		spare := json_list_at(p, "spare")
		after := [4]int{json_int_at(p, "texture"), json_int_at(p, "flags"), json_int(spare[0]), json_int(spare[1])}
		for k in 0 ..< 4 {
			for c in json_list(v[k]) {
				append(&out, u8(json_int(c)))
			}
			append(&out, u8(after[k]))
		}
		for uv in json_list_at(p, "uv") {
			for c in json_list(uv) {
				append(&out, u8(json_int(c)))
			}
		}
		for c in json_list_at(p, "colors") {
			append_u16(&out, json_int(c))
		}
	}
	return out[:]
}

@(rodata)
MODEL_KEYS := [9]string{"group", "colours", "flags", "pad", "x", "y", "z", "pad2", "octants"}
// Byte offset of each model field in its 12 bytes; x, y and z are u16.
@(rodata)
MODEL_AT := [9]int{0, 1, 2, 3, 4, 6, 8, 10, 11}

floor_json :: proc(d: []u8, style := Json_Style.Indent1) -> []u8 {
	w := jw_make(style)
	jw_open(&w, '{')
	jw_field(&w, "layer", int(d[0]))
	jw_field(&w, "attrs", int(d[1]))
	jw_field(&w, "flags", int(d[3]))
	jw_key(&w, "models")
	jw_open(&w, '[')
	count := int(d[2])
	for i in 0 ..< count {
		m := d[4 + 12 * i:]
		jw_open(&w, '{')
		for key, k in MODEL_KEYS {
			at := MODEL_AT[k]
			jw_field(&w, key, at >= 4 && at < 10 ? int(u16le(m, at)) : int(m[at]))
		}
		jw_close(&w, '}')
	}
	jw_close(&w, ']')
	if len(d) > 4 + 12 * count {
		jw_key(&w, "tail")
		jw_string(&w, hex_string(d[4 + 12 * count:]))
	}
	jw_close(&w, '}')
	return jw_bytes(&w)
}

floor_bytes :: proc(f: json.Value) -> []u8 {
	models := json_list_at(f, "models")
	out: [dynamic]u8
	append(&out, u8(json_int_at(f, "layer")), u8(json_int_at(f, "attrs")), u8(len(models)), u8(json_int_at(f, "flags")))
	for m in models {
		for key, k in MODEL_KEYS {
			v := json_int_at(m, key)
			append(&out, u8(v))
			if at := MODEL_AT[k]; at >= 4 && at < 10 {
				append(&out, u8(v >> 8))
			}
		}
	}
	if tail, ok := json_get(f, "tail"); ok {
		s := json_str(tail)
		for i := 0; i + 2 <= len(s); i += 2 {
			v, hex_ok := strconv.parse_u64_of_base(s[i:i + 2], 16)
			if !hex_ok {
				fail("bad hex in tail: %s", s)
			}
			append(&out, u8(v))
		}
	}
	return out[:]
}

map_unpack :: proc(src, out_dir: string) {
	b := read_file(src)
	make_dirs(out_dir)
	write_file(join(out_dir, "header.bin"), b[:MAP_HEADER])
	parts := map_parts(b)
	for p in parts {
		data := p.data
		if strings.has_prefix(p.name, "layer") {
			data = layer_json(data)
		} else if strings.has_prefix(p.name, "floor") {
			data = floor_json(data)
		}
		write_file(join(out_dir, p.name), data)
	}
	print("%s: %d parts", out_dir, len(parts))
}

// The part file `name` in `dir`, decoded to block bytes; nil when missing.
map_part :: proc(dir, name: string) -> ([]u8, bool) {
	path := join(dir, name)
	if !os.exists(path) {
		return nil, false
	}
	data := read_file(path)
	if strings.has_prefix(name, "layer") {
		return layer_bytes(json_parse(path, data)), true
	}
	if strings.has_prefix(name, "floor") {
		return floor_bytes(json_parse(path, data)), true
	}
	return data, true
}

// A block from its header and the part files in `dir`.
map_build :: proc(header: []u8, dir: string) -> []u8 {
	h := make([]u8, MAP_HEADER)
	copy(h, header)
	out: [dynamic]u8
	append(&out, ..h)
	add :: proc(out: ^[dynamic]u8, h: []u8, word: int, data: []u8, ok: bool) {
		put_u32(h, word, ok ? u32(len(out)) : 0)
		if ok {
			append(out, ..data)
			for len(out) % 4 != 0 {
				append(out, 0)
			}
		}
	}
	for t in MAP_TABLES {
		// A part past the header's count (an added floor or grid) raises it.
		for i in int(h[t.count_at]) ..< t.slots {
			if _, ok := map_part(dir, fmt.aprintf("%s%d%s", t.name, i, t.suffix)); ok {
				h[t.count_at] = u8(i + 1)
			}
		}
		for i in 0 ..< t.slots {
			data: []u8
			ok := false
			if i < int(h[t.count_at]) {
				data, ok = map_part(dir, fmt.aprintf("%s%d%s", t.name, i, t.suffix))
			}
			add(&out, h, t.table + 4 * i, data, ok)
		}
	}
	for s in MAP_SINGLES {
		data, ok := map_part(dir, concat(s.name, ".bin"))
		add(&out, h, s.word, data, ok)
	}
	copy(out[:MAP_HEADER], h)
	return out[:]
}

map_write :: proc(out_path: string, b: []u8) {
	if len(b) > MAP_MAX_SIZE {
		fail("block is %d bytes, at most %d", len(b), MAP_MAX_SIZE)
	}
	write_file(out_path, b)
}

map_pack :: proc(src_dir, out_path: string) {
	b := map_build(read_file(join(src_dir, "header.bin")), src_dir)
	map_write(out_path, b)
	print("%s: %d bytes", out_path, len(b))
}

map_cells :: proc(src, floors_path, out_path: string) {
	b := read_file(src)
	written: map[int][]u8
	for f in json_list_at(json_load(floors_path), "floors") {
		i := json_int_at(f, "floor")
		if i >= int(b[3]) {
			fail("floor %d: block has %d", i, b[3])
		}
		desc := int(u32le(b, 0xc4 + 4 * i))
		layer, attrs := int(b[desc]), int(b[desc + 1])
		grid := int(u32le(b, 0x04 + 4 * layer))
		across, down := 2 * int(u16le(b, grid)), 2 * int(u16le(b, grid + 2))
		rows := json_list_at(f, "cells")
		data: [dynamic]u8
		ok := len(rows) == down
		for r in rows {
			n := 0
			for c in strings.fields(json_str(r)) {
				v, hex_ok := strconv.parse_u64_of_base(c, 16)
				if !hex_ok || v > 0xff {
					fail("floor %d: bad cell %s", i, c)
				}
				append(&data, u8(v))
				n += 1
			}
			ok &&= n == across
		}
		if !ok {
			fail("floor %d: cells must be %dx%d", i, across, down)
		}
		if prev, seen := written[attrs]; seen && string(prev) != string(data[:]) {
			fail("floor %d: grid %d shared with another floor, cells differ", i, attrs)
		}
		written[attrs] = data[:]
		at := int(u32le(b, 0xa4 + 4 * attrs))
		copy(b[at:at + len(data)], data[:])
	}
	map_write(out_path, b)
	print("%s: %d grids written", out_path, len(written))
}
