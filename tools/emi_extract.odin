// Extract the unique MIPS code overlays from the EMI containers under the
// disc's BIN directory: <out_dir>/ov_<slot>_<id>.bin and
// <out_dir>/manifest.tsv, plus <out_dir>/save_icons.bin (see
// extract_save_icons).
package tools

import "core:fmt"
import "core:slice"
import "core:strings"

EMI_EXTRACT_USAGE :: "Usage: bof4tools emi-extract <disc/BIN> <out_dir>"

JR_RA :: 0x03e00008
// Entries with fewer `jr ra` are treated as data...
MIN_RETURNS :: 4
// ...unless they open with an overlay header, see is_code.
MAX_ID :: 0x10000

// Small overlays (map event code at 801f0800, battle scripts) may hold only
// one or two functions. They still open with their own id word, followed by
// either an entry table pointing into the overlay or the first instruction
// (a leaf function may start with any instruction, even its own `jr ra`).
// Data blobs sharing the id word (offset tables at 8003e000, 69800) follow
// it with a small offset whose high half is zero.
is_code :: proc(info: u32, blob: []u8) -> bool {
	returns := 0
	for i := 0; i + 4 <= len(blob); i += 1 {
		if u32le(blob, i) == JR_RA {
			returns += 1
			i += 3
		}
	}
	if returns >= MIN_RETURNS {
		return true
	}
	if returns == 0 || info >= MAX_ID || len(blob) < 8 {
		return false
	}
	return u32le(blob, 0) == info && u32le(blob, 4) >> 16 != 0
}

// Memory card icons of the 15 save numbers. The save screen uploads entry 3
// of SYSTEM/SAVE.EMI, a 4-bit texture with 64-byte rows, and the save
// builder copies save k's 16x16 icon from VRAM; in the file, icons 0..7 sit
// side by side from ICON_BASE and icons 8..14 the same way ICON_BAND bytes
// further on.
ICON_ENTRY :: 3
ICON_BASE :: 0x7400
ICON_BAND :: 0x800
ICON_STRIDE :: 64
ICON_ROW :: 8
ICON_ROWS :: 16
ICONS_PER_BAND :: 8
SAVE_ICONS :: 15

// Writes the icons as save headers hold them: 128 bytes each, in order.
extract_save_icons :: proc(root, out_dir: string) {
	tex := emi_entries(read_file(join(root, "SYSTEM", "SAVE.EMI")))[ICON_ENTRY].data
	icons: [dynamic]u8
	for k in 0 ..< SAVE_ICONS {
		base := ICON_BASE + (k / ICONS_PER_BAND) * ICON_BAND + (k % ICONS_PER_BAND) * ICON_ROW
		for r in 0 ..< ICON_ROWS {
			append(&icons, ..tex[base + r * ICON_STRIDE:][:ICON_ROW])
		}
	}
	write_file(join(out_dir, "save_icons.bin"), icons[:])
}

Overlay :: struct {
	sha1:    string,
	addr:    u32,
	ids:     [dynamic]u32,
	sources: [dynamic]string,
	blob:    []u8,
}

emi_extract_main :: proc(args: []string) {
	usage(args, EMI_EXTRACT_USAGE, 2)
	print("%d unique overlays", emi_extract(args[0], args[1]))
}

emi_extract :: proc(root, out_dir: string) -> int {
	make_dirs(out_dir)
	seen: [dynamic]Overlay // in order of first appearance
	index: map[string]int
	for rel in walk_sorted(root) {
		if !strings.has_suffix(rel, ".EMI") {
			continue
		}
		for e, i in emi_entries(read_file(join(root, rel))) {
			if e.addr < 0x80000000 || !is_code(e.info, e.data) {
				continue
			}
			h := sha1_hex(e.data)
			k, found := index[h]
			if !found {
				k = len(seen)
				index[h] = k
				append(&seen, Overlay{sha1 = h, addr = e.addr, blob = e.data})
			}
			ov := &seen[k]
			if ov.addr != e.addr {
				fail("%s#%d: overlay at %08x, also seen at %08x", rel, i, e.addr, ov.addr)
			}
			if !slice.contains(ov.ids[:], e.info) {
				append(&ov.ids, e.info)
			}
			append(&ov.sources, fmt.aprintf("%s#%d", rel, i))
		}
	}
	m := strings.builder_make()
	strings.write_string(&m, "file\tslot\tsize\tids\tsha1\tsources\n")
	for &ov in seen {
		slice.sort(ov.ids[:])
		name := fmt.aprintf("ov_%08x_%03d.bin", ov.addr, ov.ids[0])
		write_file(join(out_dir, name), ov.blob)
		fmt.sbprintf(&m, "%s\t%08x\t%d\t", name, ov.addr, len(ov.blob))
		for id, j in ov.ids {
			fmt.sbprintf(&m, "%s%d", j > 0 ? "," : "", id)
		}
		fmt.sbprintf(&m, "\t%s\t%s\n", ov.sha1, strings.join(ov.sources[:], " "))
	}
	write_file(join(out_dir, "manifest.tsv"), m.buf[:])
	extract_save_icons(root, out_dir)
	return len(seen)
}
