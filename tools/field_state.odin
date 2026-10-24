// Print the field state held in a 2 MiB main RAM dump: the map and section,
// the collision tables, the current section's exits, the party objects and
// the NPC pool. Layouts are in docs/field.md.
//
// RAM dumps come from the port: BOF4_DUMP=<dir> BOF4_DUMP_RAM=<presents>
// writes <dir>/ram_*.bin, BOF4_RAMDUMP=<file> one at exit.
package tools

import "core:fmt"
import "core:strings"

FIELD_STATE_USAGE :: `Usage: bof4tools field-state <ram.bin> [--grid] [--layer=N]
  --grid also prints the leader's layer of the collision grid, one hex
  attribute byte per cell ('..' for 0); --layer=N prints layer N instead.`

MAP_ID :: 0x8011C944
SECTION :: 0x8011C946
MAP_BLOCK :: 0x8011C954
EXITS :: 0x80116BE8
OBJECTS :: 0x80116FB0
OBJECT_SIZE :: 0xFC
LEADER_INDEX :: 0x801172AF
NPCS :: 0x801172B0
NPC_SIZE :: 200
NPC_COUNT :: 32
CAM_YAW :: 0x8013818E

@(private = "file")
ram: []u8

@(private = "file")
r8 :: proc(a: u32) -> u32 {return u32(ram[a & 0x1FFFFF])}
@(private = "file")
r16 :: proc(a: u32) -> u32 {return u32(u16le(ram, int(a & 0x1FFFFF)))}
@(private = "file")
s16 :: proc(a: u32) -> i16 {return i16le(ram, int(a & 0x1FFFFF))}
@(private = "file")
r32 :: proc(a: u32) -> u32 {return u32le(ram, int(a & 0x1FFFFF))}
@(private = "file")
s32 :: proc(a: u32) -> i32 {return i32(r32(a))}

@(private = "file")
in_ram :: proc(p: u32) -> bool {
	return 0x80000000 <= p && p < 0x80200000
}

@(private = "file")
show :: proc(tag: string, b: u32) {
	pos := b + 12
	print("  %s id % 3d state % 3d/%d  cell % 7.2f % 7.2f  height % 6.2f  layer %d", tag, r8(b + 1), r8(b + 4), r8(b + 5), f64(s32(pos)) / 65536, f64(s32(pos + 8)) / 65536, f64(s32(pos + 4)) / 65536, r8(pos + 12))
}

field_state_main :: proc(args: []string) {
	files: [dynamic]string
	grid := false
	layer_arg := ""
	for a in args {
		switch {
		case !strings.has_prefix(a, "--"):
			append(&files, a)
		case a == "--grid":
			grid = true
		case strings.has_prefix(a, "--layer="):
			layer_arg = a[8:]
		}
	}
	usage(files[:], FIELD_STATE_USAGE, 1)
	ram = read_file(files[0])

	section := r8(SECTION)
	leader := OBJECTS + r8(LEADER_INDEX) * OBJECT_SIZE
	print("map %04x section %d camera yaw %d", r16(MAP_ID), section, r16(CAM_YAW))

	blk := r32(MAP_BLOCK)
	if in_ram(blk) {
		print("map block %08x: grids %d, attribute arrays %d, layers %d", blk, r8(blk), r8(blk + 2), r8(blk + 3))
	}

	base := r32(EXITS)
	if in_ram(base) && in_ram(r32(base)) {
		p := r32(r32(base) + 4 * section)
		print("exits of section %d:", section)
		for in_ram(p) && s16(p) != -1 {
			print("  to %04x.%d  cells (%d,%d) x%d along %s  arrive (%.1f,%.1f) facing %d", r16(p), r8(p + 2), r8(p + 4), r8(p + 5), r8(p + 10), r8(p + 3) & 1 != 0 ? "z" : "x", f64(s16(p + 6)) / 256, f64(s16(p + 8)) / 256, r8(p + 11) & 7)
			p += 12
		}
	}

	print("party objects:")
	for i in u32(0) ..< 4 {
		b := OBJECTS + i * OBJECT_SIZE
		if r8(b) != 0 {
			show(b == leader ? fmt.tprintf("P%d*", i) : fmt.tprintf("P%d ", i), b)
		}
	}
	print("NPCs:")
	for i in u32(0) ..< NPC_COUNT {
		b := NPCS + i * NPC_SIZE
		if r8(b) != 0 {
			show(fmt.tprintf("N%-2d", i), b)
		}
	}

	if grid && in_ram(blk) {
		layer := section + r8(leader + 24)
		if layer_arg != "" {
			layer = section + u32(parse_int(layer_arg))
		}
		desc := blk + r32(blk + 0xC4 + 4 * layer)
		cells := blk + r32(blk + 4 + 4 * r8(desc))
		attrs := blk + r32(blk + 0xA4 + 4 * r8(desc + 1))
		w, h := r16(cells) * 2, r16(cells + 2) * 2
		print("grid of layer %d: %dx%d cells", layer, w, h)
		for z in 0 ..< h {
			row := strings.builder_make()
			for x in 0 ..< w {
				v := r8(attrs + z * w + x)
				if v != 0 {
					fmt.sbprintf(&row, "%02x", v)
				} else {
					strings.write_string(&row, "..")
				}
			}
			print("%s", strings.to_string(row))
		}
	}
}
