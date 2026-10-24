// List where the map overlays set, clear and test story progress bits.
//
// Story progress is a u32 per area (chapter) at 0x8011b7d0 + area * 4. Map
// scripts change it through resident routines (set 0x801917d4, clear
// 0x801917fc, test 0x80191828; a0 = the word's address, a1 = bit). This
// scans every overlay for calls to them, tracking a0/a1 through
// lui/addiu/ori within straight-line code, and prints per overlay the bits
// it touches:
//   set4:[0, 12]  = sets area 4 bits 0 and 12
package tools

import "core:fmt"
import "core:slice"
import "core:strings"

STORY_FLAGS_USAGE :: "Usage: bof4tools story-flags <overlays dir>"

STORY_LO :: 0x8011b7d0
STORY_HI :: 0x8011b878

Story_Use :: struct {
	fn:   string,
	area: i64,
}

story_fn :: proc(target: u32) -> (string, bool) {
	switch target {
	case 0x801917d4:
		return "set", true
	case 0x801917fc:
		return "clr", true
	case 0x80191828:
		return "tst", true
	}
	return "", false
}

story_flags_main :: proc(args: []string) {
	usage(args, STORY_FLAGS_USAGE, 1)
	dir := args[0]
	src: map[string]string
	for line in manifest_rows(dir) {
		src[line[0]] = len(line) > 5 ? line[5] : ""
	}
	for name in overlay_files(dir) {
		d := read_file(join(dir, name))
		w := make([]u32, len(d) / 4)
		for &x, i in w {
			x = u32le(d, i * 4)
		}
		// Known register values; regs absent from the map are unknown.
		reg: map[u32]Maybe(i64)
		res: map[Story_Use]map[i64]bool
		for x, k in w {
			op, rt, rs, rd := x >> 26, (x >> 16) & 31, (x >> 21) & 31, (x >> 11) & 31
			imm := i64(x & 0xffff)
			simm := imm & 0x8000 != 0 ? imm - 0x10000 : imm
			switch {
			case op == 15:
				reg[rt] = imm << 16
			case op == 9:
				v: Maybe(i64) = 0
				if rs != 0 {
					v = reg[rs] or_else nil
				}
				if base, ok := v.?; ok {
					reg[rt] = (base + simm) & 0xffffffff
				} else {
					reg[rt] = nil
				}
			case op == 13 && rs == 0:
				reg[rt] = imm
			case op == 0 && (x & 63 == 33 || x & 63 == 37) && rt == 0:
				reg[rd] = reg[rs] or_else nil
			case op == 3:
				t := (x & 0x3ffffff) << 2 | 0x80000000
				fn, is_fn := story_fn(t)
				if is_fn && k + 1 < len(w) {
					y := w[k + 1] // delay slot
					if y >> 26 == 9 && (y >> 21) & 31 == 0 {
						reg[(y >> 16) & 31] = i64(y & 0xffff)
					}
					a0, a0_ok := (reg[4] or_else nil).?
					a1, a1_ok := (reg[5] or_else nil).?
					if a0_ok && STORY_LO <= a0 && a0 < STORY_HI && a1_ok {
						use := Story_Use{fn, (a0 - STORY_LO) / 4}
						bits := res[use]
						bits[a1 + (a0 - STORY_LO) % 4 * 8] = true
						res[use] = bits
					}
				}
				for r in ([?]u32{2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 24, 25}) {
					delete_key(&reg, r)
				}
			case op == 35 || op == 36 || op == 37 || op == 32 || op == 33:
				reg[rt] = nil
			}
			if x == 0x03e00008 {
				clear(&reg)
			}
		}
		if len(res) == 0 {
			continue
		}
		uses, _ := slice.map_keys(res)
		slice.sort_by(uses, proc(a, b: Story_Use) -> bool {
			return a.fn != b.fn ? a.fn < b.fn : a.area < b.area
		})
		line := strings.builder_make()
		s := src[name] or_else ""
		s = s[strings.last_index_byte(s, '/') + 1:]
		fmt.sbprintf(&line, "%s %s ", name[3:], s[:min(len(s), 24)])
		for use, i in uses {
			bits, _ := slice.map_keys(res[use])
			slice.sort(bits)
			fmt.sbprintf(&line, "%s%s%d:[", i > 0 ? " " : "", use.fn, use.area)
			for b, j in bits {
				fmt.sbprintf(&line, "%s%d", j > 0 ? ", " : "", b)
			}
			strings.write_byte(&line, ']')
		}
		print("%s", strings.to_string(line))
	}
}
