// Debug warp: BOF4_WARP=map[.section][:x,z] makes every save the game loads
// resume on another field map. `map` is the map id in hex as the game stores
// it (one high-byte bit picks the area: 0x10 AREAM, 0x02 AREAS, 0x04 AREAD,
// 0x08 AREAE; low byte is the file number, so 0824 = AREAE036). `section` is the
// map's section index in decimal (0x8011c946 in RAM, default 0); the saved one
// belongs to the old map, and a section the new map lacks sends the exit
// check through garbage until the game hangs. `x,z` are the leader's tile
// coordinates in decimal; without them the saved tile is kept, which may be
// inside a wall on the new map.
//
// The save stores the resume map and tile in its game region. The patch is
// made to RAM as the game reads the file (psx.card_read_hook), with the save's
// XOR checksum corrected to match, so the card image is never changed.
package qol

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "../psx"

import "ps:core"

@(private = "file")
SAVE_PREFIX :: "BASLUS-01324BOF4"
// File offset of the resume section (u8), map id (u16), then tile x (u16)
// and z (u16): header 0x180 + game region offset 0xe75.
@(private = "file")
WARP_OFFSET :: 0x180 + 0xe75
@(private = "file")
WARP_MAX :: 7
@(private = "file")
WARP_CHECKSUM :: 0x184f // u8, XOR of the bytes before it

@(private = "file")
warp: struct {
	bytes: [WARP_MAX]u8,
	count: u32, // 3 (section and map) or 7 (and tile)
	// Of the current file read: patched bytes so far, and the XOR of
	// original ^ patched over them, to correct the checksum.
	done:  u32,
	delta: u8,
}

@(private)
warp_init :: proc() -> bool {
	spec := os.get_env("BOF4_WARP", context.temp_allocator)
	if spec == "" {
		return true
	}
	if !parse_warp(spec) {
		fmt.eprintln("BOF4_WARP: expected map[.section][:x,z], map in hex, the rest in decimal; got", spec)
		return false
	}
	psx.card_read_hook = warp_read
	return true
}

@(private = "file")
parse_warp :: proc(spec: string) -> bool {
	head, _, pos := strings.partition(spec, ":")
	map_s, dot, section_s := strings.partition(head, ".")
	m, ok := strconv.parse_uint(map_s, 16)
	if !ok || m > 0xffff {
		return false
	}
	section: uint
	if dot != "" {
		section, ok = strconv.parse_uint(section_s, 10)
		if !ok || section > 0xff {
			return false
		}
	}
	warp.bytes[0] = u8(section)
	vals := [3]u64{u64(m), 0, 0}
	warp.count = 3
	if pos != "" {
		x_s, _, z_s := strings.partition(pos, ",")
		x, x_ok := strconv.parse_uint(x_s, 10)
		z, z_ok := strconv.parse_uint(z_s, 10)
		if !x_ok || !z_ok || x > 0xffff || z > 0xffff {
			return false
		}
		vals[1], vals[2] = u64(x), u64(z)
		warp.count = WARP_MAX
	}
	for v, i in vals {
		warp.bytes[1 + i * 2], warp.bytes[2 + i * 2] = u8(v), u8(v >> 8)
	}
	return true
}

@(private = "file")
warp_read :: proc(name: string, file_pos: u32, buf: u32, length: u32) {
	if !strings.has_prefix(name, SAVE_PREFIX) {
		return
	}
	if file_pos == 0 {
		warp.done, warp.delta = 0, 0
	}
	for i in 0 ..< warp.count {
		off := u32(WARP_OFFSET) + i
		if off >= file_pos && off < file_pos + length {
			orig := u8(psx.lbu(buf + off - file_pos))
			psx.sb(buf + off - file_pos, u32(warp.bytes[i]))
			warp.delta ~= orig ~ warp.bytes[i]
			warp.done += 1
		}
	}
	if WARP_CHECKSUM < file_pos || WARP_CHECKSUM >= file_pos + length {
		return
	}
	if warp.done != warp.count {
		fmt.eprintfln("BOF4_WARP: %s checksum read before the resume position; not warped", name)
		return
	}
	at := buf + WARP_CHECKSUM - file_pos
	psx.sb(at, psx.lbu(at) ~ u32(warp.delta))
	if .Game in core.trace.active {
		core.tracef(.Game, "warp: %s resumes on map %02x%02x.%d", name, warp.bytes[2], warp.bytes[1], warp.bytes[0])
	}
}
