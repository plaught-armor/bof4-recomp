// EMI containers, the game's packed files. Layout (little-endian):
//   0x00 u32 entry count
//   0x04 u32 (always 1)
//   0x08 "MATH_TBL"
//   0x10 entries, 16 bytes each:
//        u32 size
//        u32 load address (>= 0x80000000) or data kind (< 0x80000000)
//        u32 info: global overlay id for code entries
//        u16 type, then ".." padding
//   0x800 entry data, each entry padded to a 2 KiB boundary
package tools

import "core:os"
import "core:slice"
import "core:strings"

Emi_Entry :: struct {
	addr: u32,
	info: u32,
	data: []u8,
}

emi_entries :: proc(d: []u8) -> []Emi_Entry {
	count := int(u32le(d, 0))
	entries := make([]Emi_Entry, count)
	off := 0x800
	for &e, i in entries {
		size := int(u32le(d, 0x10 + i * 16))
		e = {u32le(d, 0x14 + i * 16), u32le(d, 0x18 + i * 16), d[min(off, len(d)):min(off + size, len(d))]}
		off = (off + size + 0x7ff) &~ 0x7ff
	}
	return entries
}

// The rows of <overlays dir>/manifest.tsv after its header, split at tabs.
manifest_rows :: proc(dir: string) -> [][]string {
	text := string(read_file(join(dir, "manifest.tsv")))
	rows: [dynamic][]string
	for line, i in strings.split_lines(text) {
		if i > 0 && line != "" {
			append(&rows, strings.split(line, "\t"))
		}
	}
	return rows[:]
}

// The overlay files (ov_*.bin) in <overlays dir>, in name order.
overlay_files :: proc(dir: string) -> []string {
	infos, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		fail("%s: %v", dir, err)
	}
	names: [dynamic]string
	for fi in infos {
		if strings.has_prefix(fi.name, "ov_") && strings.has_suffix(fi.name, ".bin") {
			append(&names, fi.name)
		}
	}
	slice.sort(names[:])
	return names[:]
}
