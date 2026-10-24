// Draw the floors of a BOF4_FLOORDUMP map file as PNG pictures.
//
// The port writes <map>.json with BOF4_FLOORDUMP=<dir> (see docs/field.md,
// Floors). For each floor this writes <out>/<map>_f<floor>.png, one pixel
// block per attribute cell: grey by ground height (black lowest, white
// highest over the whole map), tinted by the cell's kind (high nibble): red
// walls (0x1x), blue exits (0xax), green stairs (0xcx), yellow anything else
// not plain floor.
package tools

import "core:fmt"
import "core:strconv"
import "core:strings"

import "../port/src/png"

FLOORS_PNG_USAGE :: "Usage: bof4tools floors-png <map>.json <out dir> [pixels per cell, 4]"

floors_png_main :: proc(args: []string) {
	usage(args, FLOORS_PNG_USAGE, 2, 3)
	m := json_load(args[0])
	out_dir := args[1]
	k := len(args) > 2 ? parse_int(args[2]) : 4
	make_dirs(out_dir)
	floors := json_list_at(m, "floors")
	lo, hi := max(int), min(int)
	for f in floors {
		for row in json_list_at(f, "ground") {
			for g in json_list(row) {
				lo, hi = min(lo, json_int(g)), max(hi, json_int(g))
			}
		}
	}
	span := f64(max(hi - lo, 1))
	for f in floors {
		width, depth := json_int_at(f, "width"), json_int_at(f, "depth")
		stride := width * k * 3
		pix := make([]u8, stride * depth * k)
		f_lo, f_hi := max(int), min(int)
		cells, ground := json_list_at(f, "cells"), json_list_at(f, "ground")
		for z in 0 ..< min(len(cells), len(ground), depth) {
			grow := json_list(ground[z])
			for cell, x in strings.fields(json_str(cells[z])) {
				if x >= min(len(grow), width) {
					break
				}
				a, ok := strconv.parse_u64_of_base(cell, 16)
				if !ok {
					fail("%s: bad cell %s", args[0], cell)
				}
				tint := [3]f64{1.0, 1.0, 1.0}
				switch a >> 4 {
				case 0x0:
				case 0x1:
					tint = {1.0, 0.35, 0.35}
				case 0xa:
					tint = {0.4, 0.5, 1.0}
				case 0xc:
					tint = {0.4, 1.0, 0.4}
				case:
					tint = {1.0, 1.0, 0.4}
				}
				v := 0.25 + 0.75 * f64(json_int(grow[x]) - lo) / span
				rgb: [3]u8
				for c, i in tint {
					rgb[i] = u8(min(255, int(255 * v * c)))
				}
				for dz in 0 ..< k {
					for dx in 0 ..< k {
						at := (z * k + dz) * stride + (x * k + dx) * 3
						copy(pix[at:at + 3], rgb[:])
					}
				}
			}
		}
		for row in ground {
			for g in json_list(row) {
				f_lo, f_hi = min(f_lo, json_int(g)), max(f_hi, json_int(g))
			}
		}
		path := join(out_dir, fmt.aprintf("%s_f%d.png", json_str(json_at(m, "map")), json_int_at(f, "floor")))
		if !png.write(path, pix, width * k, depth * k, 3) {
			fail("%s: cannot write", path)
		}
		print("%s ground %d..%d", path, f_lo, f_hi)
	}
}
