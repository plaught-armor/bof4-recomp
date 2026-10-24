// Edited maps. In the maps directory (BOF4_MAPS, else `maps` in the working
// directory), a file `<map>.blk` (map id in four hex digits) replaces that
// map's data block as the disc moves it into RAM, and `<map>.edit`, written
// by the in-game map editor (map_editor.odin), patches it and the map's code
// overlay byte by byte.
//
// The block is EMI entry 4 of the map's file (WORLD/AREA*.EMI), loaded raw at
// MAP_DATA. Every chunk the disc's DMA moves into the block is written over
// with the edited bytes at the same offsets, and the first chunk writes the
// whole edited block, so it may be longer than the disc's. It must end by
// MAP_DATA_END: the party's models (PL*.EMI) load there on every map.
// `bof4tools map-block` extracts blocks and writes edited floors back.
//
// The overlay (the map's exit lists among its code) loads raw at OVERLAY;
// minigames load theirs there too, so its patch carries the vanilla bytes and
// goes in only when every one of them is what landed. A `.edit` file is text,
// one run per line ('#' starts a comment), offsets from the part's start:
//
//   block <offset> <edited bytes>
//   overlay <offset> <vanilla bytes> <edited bytes>
package qol

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../psx"

@(private = "file")
MAP_DATA :: 0x80069800
@(private = "file")
MAP_DATA_END :: 0x80083800
@(private = "file")
MAP_REQUESTED :: 0x80116bc4 // u16, the map being loaded
@(private = "file")
MAP_HEADER :: 0x134 // the block's header; its first part follows
@(private = "file")
OVERLAY :: 0x801f0800 // the map's code overlay (EMI entry 13)
@(private = "file")
OVERLAY_END :: 0x80200000
// A chunk this far past the overlay's loaded end still belongs to its load.
@(private = "file")
SECTOR :: 0x800

// One edited byte of a map: its vanilla value is known for overlay bytes only.
Map_Edit :: struct {
	vanilla, edited: u8,
}

// A map's byte edits by part, offset: edited value.
@(private = "file")
Map_Patch :: struct {
	block:   map[u32]u8,
	overlay: map[u32]Map_Edit,
}

@(private = "file")
map_mods: struct {
	dir:          string,
	blocks:       map[u16][]u8, // map: edited block, nil when it has none
	patches:      map[u16]^Map_Patch, // map: its .edit file, nil when it has none
	active:       []u8, // the block of the map loading
	patch:        ^Map_Patch, // the patch of the map loading
	overlay_end:  u32, // where the overlay load reached
	overlay_done: bool, // its patch went in or was refused
	next:         proc(addr, size: u32), // the DMA hook before this one
}

map_mods_init :: proc() -> bool {
	map_mods.dir = os.get_env("BOF4_MAPS", context.allocator)
	if map_mods.dir == "" {
		map_mods.dir = "maps"
	}
	map_mods.next = psx.dma_cdrom_hook
	psx.dma_cdrom_hook = map_mods_dma
	return true
}

// The edited block of map `id`, read once per process (a background room
// load runs in a fork() copy, preload.odin, and reads its own).
@(private = "file")
map_mods_block :: proc(id: u16) -> []u8 {
	if blk, seen := map_mods.blocks[id]; seen {
		return blk
	}
	path := fmt.tprintf("%s/%04x.blk", map_mods.dir, id)
	blk, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		blk = nil
	} else if len(blk) > MAP_DATA_END - MAP_DATA || len(blk) < MAP_HEADER {
		fmt.eprintfln("maps: %s is %d bytes, must be %d to %d", path, len(blk), MAP_HEADER, MAP_DATA_END - MAP_DATA)
		delete(blk)
		blk = nil
	} else {
		fmt.eprintfln("maps: %04x from %s", id, path)
	}
	map_mods.blocks[id] = blk
	return blk
}

// The patch of map `id`, read once per process; nil when it has none and
// `make` is false.
@(private = "file")
map_mods_patch :: proc(id: u16, make_new := false) -> ^Map_Patch {
	p, seen := map_mods.patches[id]
	if !seen {
		path := fmt.tprintf("%s/%04x.edit", map_mods.dir, id)
		if text, err := os.read_entire_file(path, context.allocator); err == nil {
			p = new(Map_Patch)
			if patch_parse(p, string(text)) {
				fmt.eprintfln("maps: %04x patched from %s", id, path)
			} else {
				fmt.eprintfln("maps: %s does not read, left out", path)
				free(p)
				p = nil
			}
			delete(text)
		}
		map_mods.patches[id] = p
	}
	if p == nil && make_new {
		p = new(Map_Patch)
		map_mods.patches[id] = p
	}
	return p
}

@(private = "file")
patch_parse :: proc(p: ^Map_Patch, text: string) -> bool {
	text := text
	for line in strings.split_lines_iterator(&text) {
		line := line
		if i := strings.index_byte(line, '#'); i >= 0 {
			line = line[:i]
		}
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) == 0 {
			continue
		}
		at, ok := strconv.parse_uint(fields[1] if len(fields) > 1 else "", 16)
		if !ok {
			return false
		}
		switch {
		case fields[0] == "block" && len(fields) == 3:
			edited := hex_bytes(fields[2]) or_return
			for b, k in edited {
				p.block[u32(at) + u32(k)] = b
			}
		case fields[0] == "overlay" && len(fields) == 4:
			vanilla := hex_bytes(fields[2]) or_return
			edited := hex_bytes(fields[3]) or_return
			if len(vanilla) != len(edited) {
				return false
			}
			for b, k in edited {
				p.overlay[u32(at) + u32(k)] = {vanilla[k], b}
			}
		case:
			return false
		}
	}
	return true
}

@(private = "file")
hex_bytes :: proc(s: string) -> (out: []u8, ok: bool) {
	if len(s) == 0 || len(s) % 2 != 0 {
		return
	}
	out = make([]u8, len(s) / 2, context.temp_allocator)
	for &b, i in out {
		v := strconv.parse_uint(s[2 * i:2 * i + 2], 16) or_return
		b = u8(v)
	}
	return out, true
}

@(private = "file")
map_mods_dma :: proc(addr, size: u32) {
	if addr == MAP_DATA {
		id := psx.r16(MAP_REQUESTED)
		map_mods.active = map_mods_block(id)
		map_mods.patch = map_mods_patch(id)
	}
	if addr == OVERLAY {
		map_mods.patch = map_mods_patch(psx.r16(MAP_REQUESTED))
		map_mods.overlay_end, map_mods.overlay_done = addr + size, false
	} else if addr > OVERLAY && addr < OVERLAY_END && addr <= map_mods.overlay_end + SECTOR {
		map_mods.overlay_end = max(map_mods.overlay_end, addr + size)
	}
	blk := map_mods.active
	if blk != nil && addr + size > MAP_DATA && addr < MAP_DATA + u32(len(blk)) {
		if addr == MAP_DATA {
			copy(psx.mem_slice(MAP_DATA, u32(len(blk))), blk)
		} else {
			from := max(addr, MAP_DATA)
			to := min(addr + size, MAP_DATA + u32(len(blk)))
			copy(psx.mem_slice(from, to - from), blk[from - MAP_DATA:to - MAP_DATA])
		}
	}
	if p := map_mods.patch; p != nil {
		if addr + size > MAP_DATA && addr < MAP_DATA_END {
			for at, b in p.block {
				if MAP_DATA + at >= addr && MAP_DATA + at < addr + size {
					psx.sb(MAP_DATA + at, u32(b))
				}
			}
		}
		if addr >= OVERLAY && addr < OVERLAY_END && !map_mods.overlay_done {
			overlay_patch(p)
		}
	}
	if map_mods.next != nil {
		map_mods.next(addr, size)
		// Interiors keeps the block up to where its load ended: the edited
		// block's end, though the disc's was shorter.
		if addr == MAP_DATA && u32(len(blk)) > size {
			map_mods.next(MAP_DATA + size, u32(len(blk)) - size)
		}
	}
}

// The overlay patch, once the load has reached its last byte: all of it
// when every vanilla byte matches, else none.
@(private = "file")
overlay_patch :: proc(p: ^Map_Patch) {
	if len(p.overlay) == 0 {
		map_mods.overlay_done = true
		return
	}
	last: u32
	for at in p.overlay {
		last = max(last, at)
	}
	if OVERLAY + last >= map_mods.overlay_end {
		return
	}
	map_mods.overlay_done = true
	for at, e in p.overlay {
		if u8(psx.lbu(OVERLAY + at)) != e.vanilla {
			fmt.eprintfln("maps: %04x overlay at +%x is %02x, the patch's vanilla %02x: overlay patch left out", psx.r16(MAP_REQUESTED), at, psx.lbu(OVERLAY + at), e.vanilla)
			return
		}
	}
	for at, e in p.overlay {
		psx.sb(OVERLAY + at, u32(e.edited))
	}
}

// ---------------------------------------------------------------- editing

// Change one byte of the loaded map (MAP_ID) at RAM address `addr`, in its
// block (at MAP_DATA) or its overlay, and note it for map_mods_save. False
// for an address in neither.
@(private)
map_mods_edit :: proc(addr: u32, value: u8) -> bool {
	p := map_mods_patch(psx.r16(MAP_ID), true)
	switch {
	case addr >= MAP_DATA && addr < MAP_DATA_END:
		p.block[addr - MAP_DATA] = value
	case addr >= OVERLAY && addr < OVERLAY_END:
		at := addr - OVERLAY
		e, seen := p.overlay[at]
		if !seen {
			e.vanilla = u8(psx.lbu(addr))
		}
		e.edited = value
		if e.edited == e.vanilla {
			delete_key(&p.overlay, at)
		} else {
			p.overlay[at] = e
		}
	case:
		return false
	}
	psx.sb(addr, u32(value))
	return true
}

// Write the loaded map's patch to `<dir>/<map>.edit`; returns the path.
@(private)
map_mods_save :: proc() -> (path: string, ok: bool) {
	id := psx.r16(MAP_ID)
	p := map_mods_patch(id, true)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "# Map %04x, written by the map editor (F4).", id)
	keys, _ := slice.map_keys(p.block, context.temp_allocator)
	slice.sort(keys)
	for i := 0; i < len(keys); {
		j := run_end(keys, i)
		fmt.sbprintf(&b, "block %x ", keys[i])
		for at in keys[i:j] {
			fmt.sbprintf(&b, "%02x", p.block[at])
		}
		strings.write_byte(&b, '\n')
		i = j
	}
	keys, _ = slice.map_keys(p.overlay, context.temp_allocator)
	slice.sort(keys)
	for i := 0; i < len(keys); {
		j := run_end(keys, i)
		fmt.sbprintf(&b, "overlay %x ", keys[i])
		for at in keys[i:j] {
			fmt.sbprintf(&b, "%02x", p.overlay[at].vanilla)
		}
		strings.write_byte(&b, ' ')
		for at in keys[i:j] {
			fmt.sbprintf(&b, "%02x", p.overlay[at].edited)
		}
		strings.write_byte(&b, '\n')
		i = j
	}
	if !os.exists(map_mods.dir) {
		if err := os.make_directory(map_mods.dir); err != nil {
			fmt.eprintfln("maps: cannot make %s: %v", map_mods.dir, err)
			return
		}
	}
	path = fmt.tprintf("%s/%04x.edit", map_mods.dir, id)
	if err := os.write_entire_file(path, transmute([]u8)strings.to_string(b)); err != nil {
		fmt.eprintfln("maps: cannot write %s: %v", path, err)
		return
	}
	return path, true
}

// The end of the run of consecutive offsets from keys[i], at most 32 long.
@(private = "file")
run_end :: proc(keys: []u32, i: int) -> int {
	j := i + 1
	for j < len(keys) && keys[j] == keys[j - 1] + 1 && j - i < 32 {
		j += 1
	}
	return j
}
