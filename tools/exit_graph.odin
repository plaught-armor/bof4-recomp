// Print the field map connection graph from the map overlays.
//
// Each map's overlay (slot 0x801f0800) holds its exit table: a pointer to
// per-section list pointers, each list 12-byte entries ended by s16 -1
// (layout in docs/field.md). The table is found by its shape, so a map whose
// table is not found prints "none".
//
// Output per map: the EMI files carrying the overlay, then one line per exit:
//   s<section> -> <map>.<section> at (<x>,<z>) len <cells> flags <+3> to (<x>,<z>)
package tools

import "core:slice"
import "core:strings"

EXIT_GRAPH_USAGE :: "Usage: bof4tools exit-graph <overlays dir>"

EXIT_BASE :: 0x801f0800

Exit_Table :: struct {
	exits: int,
	base:  int,
	table: int,
	secs:  [][][]u8,
}

// One section's exit list at p, or nil when p holds no list.
exit_list :: proc(d: []u8, p: int) -> (list: [][]u8, ok: bool) {
	end := EXIT_BASE + len(d)
	out: [dynamic][]u8
	p := p
	for _ in 0 ..< 80 {
		if p + 12 > end {
			return nil, false
		}
		e := d[p - EXIT_BASE:][:12]
		dest := i16le(e, 0)
		if dest == -1 {
			return out[:], true
		}
		hi, lo := u16(dest) & 0xfe00, u16(dest) & 0x1ff
		area := hi == 0x200 || hi == 0x400 || hi == 0x800 || hi == 0x1000
		if !(dest == -2 || 0 <= dest && dest < 3 || area && lo < 200 || hi == 0) {
			return nil, false
		}
		if e[2] > 16 {
			return nil, false
		}
		append(&out, e)
		p += 12
	}
	return nil, false
}

exit_table :: proc(d: []u8) -> (best: Exit_Table, found: bool) {
	end := EXIT_BASE + len(d)
	inb :: proc(p, end: int) -> bool {
		return EXIT_BASE <= p && p < end - 3
	}
	w :: proc(d: []u8, p: int) -> int {
		return int(u32le(d, p - EXIT_BASE))
	}
	for o := EXIT_BASE; o < end - 3; o += 4 {
		t := w(d, o)
		if !inb(t, end) || t & 3 != 0 {
			continue
		}
		secs: [dynamic][][]u8
		for q := t; inb(q, end) && len(secs) < 32; q += 4 {
			p := w(d, q)
			if p == 0 {
				append(&secs, nil)
				continue
			}
			if !inb(p, end) {
				break
			}
			l, ok := exit_list(d, p)
			if !ok {
				break
			}
			append(&secs, l)
		}
		n := 0
		for s in secs {
			n += len(s)
		}
		if n > 0 && (!found || n > best.exits) {
			best, found = {n, o, t, secs[:]}, true
		}
	}
	return
}

exit_graph_main :: proc(args: []string) {
	usage(args, EXIT_GRAPH_USAGE, 1)
	dir := args[0]
	Map :: struct {
		file:  string,
		names: []string,
	}
	maps: [dynamic]Map
	for row in manifest_rows(dir) {
		if strings.has_prefix(row[0], "ov_801f0800_") {
			append(&maps, Map{row[0], strings.fields(row[5])})
		}
	}
	slice.stable_sort_by(maps[:], proc(a, b: Map) -> bool {
		return a.names[0] < b.names[0]
	})
	for m in maps {
		b, found := exit_table(read_file(join(dir, m.file)))
		if !found {
			print("%s none", m.names[0])
			continue
		}
		line := strings.builder_make()
		for name in m.names {
			x := name[strings.last_index_byte(name, '/') + 1:]
			if dot := strings.index_byte(x, '.'); dot >= 0 {
				x = x[:dot]
			}
			strings.write_string(&line, x)
			strings.write_byte(&line, ' ')
		}
		print("%sbase %x tab %x", strings.to_string(line), b.base, b.table)
		for s, i in b.secs {
			for e in s {
				print("  s%d -> %04x.%d at (%d,%d) len %d flags %02x to (%d,%d)", i, u16le(e, 0), e[2], e[4], e[5], e[10], e[3], i16le(e, 6) >> 8, i16le(e, 8) >> 8)
			}
		}
	}
}
