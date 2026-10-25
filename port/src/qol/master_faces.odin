// Master portraits for the Masters panel's per-master pages: each master's
// dialogue face, read from the disc in the area file the master lives in.
//
// An area file (BIN/WORLD/AREA*.EMI) starts with a header: a u32 entry count,
// then from 0x10 one 16-byte record per entry (size, load address, info,
// type in the low half), the data from 0x800 on, each entry 2 KiB aligned.
// The dialogue faces are the type-3 entry for VRAM (960, 256): a 4-bit sheet
// 256 texels wide stored as 128x32 tiles (0x800 bytes each), two to a row.
// Face k is 40x48 texels at (8 + 40 * (k % 6), 48 * (k / 6)). Its 16-colour
// palette is the 32 bytes at k * 32 of the type-0 entry loaded at
// 0x80037c00. A master's own lines in its area show face 0 (text code 0x17
// 00 00 is the speaker's face), Marlok's face 1 where Lyta's is 0.
//
// To draw one, the portrait borrows the texels of the game's own dialogue
// face 0 (VRAM x 962-971, y 256-303) and its CLUT (0, 254) while a master's
// page is up, and gives them back afterwards. If the game writes there in
// the meantime, what it wrote is kept instead.
package qol

import "core:fmt"

import cpu "ps:psx/cpu"
import render "ps:psx/render"
import spu "ps:psx/spu"

// u32 per game file: its first sector on the disc.
@(private)
FILE_TABLE :: 0x80172c10
@(private = "file")
EMI_ENTRY_AT :: 0x10
@(private = "file")
EMI_ENTRY_SIZE :: 16
@(private = "file")
EMI_DATA_AT :: 0x800
@(private = "file")
EMI_ALIGN :: 0x800
@(private = "file")
EMI_MAX_ENTRIES :: (EMI_DATA_AT - EMI_ENTRY_AT) / EMI_ENTRY_SIZE
@(private = "file")
SHEET_ADDR :: 0x1e080200 // type 3: VRAM (960, 256)
@(private = "file")
SHEET_TYPE :: 3
@(private = "file")
PALETTE_ADDR :: 0x80037c00
@(private = "file")
PALETTE_TYPE :: 0
@(private = "file")
TILE_W :: 128
@(private = "file")
TILE_H :: 32
@(private = "file")
TILE_BYTES :: TILE_W * TILE_H / 2
@(private = "file")
FACE_ROW :: 6 // faces across the sheet
@(private = "file")
FACE_X0 :: 8

FACE_W :: 40
FACE_H :: 48
@(private)
FACE_HALFWORDS :: FACE_W / 4
@(private)
COLOURS :: 16

// Where the portrait borrows VRAM: dialogue face 0 and its CLUT.
@(private = "file")
PAGE_X :: 960
@(private = "file")
PAGE_Y :: 256
@(private = "file")
CELL_X :: PAGE_X + FACE_X0 / 4
@(private = "file")
CLUT_X :: 0
@(private = "file")
CLUT_Y :: 254

// Flat textured quad (GP0 0x2c), neutral tint, 4-bit texels from
// texture page (960, 256).
@(private = "file")
QUAD_TAG :: 0x09000000
@(private = "file")
QUAD_CMD :: 0x2c808080
@(private = "file")
QUAD_CLUT :: CLUT_Y << 6 | CLUT_X / 16
@(private = "file")
QUAD_TPAGE :: PAGE_Y / 256 << 4 | PAGE_X / 64
@(private = "file")
QUAD_BYTES :: 0x28

// Indexed by master id - 1: the game file of the master's area, its face.
@(private)
MASTER_FACES := [?]struct {
	file: u32,
	face: u8,
} {
	{0x2a0, 0}, // Rwolf, AREAD086
	{0x385, 0}, // Momo, AREAS002
	{0x366, 0}, // Kryrik, AREAM027
	{0x3a7, 0}, // Abbess, AREAS036
	{0x3ba, 0}, // Njomo, AREAS055
	{0x35c, 0}, // Gyosil, AREAM017
	{0x2bc, 0}, // Stoll, AREAD114
	{0x397, 0}, // Una, AREAS020
	{0x2be, 0}, // Bunyan, AREAD116
	{0x38e, 0}, // Lyta, AREAS011
	{0x345, 0}, // Khan, AREAE075
	{0x38e, 1}, // Marlok, AREAS011
}

@(private)
Portrait :: struct {
	state:  enum u8 {Unread, Read, Failed},
	texels: [FACE_H][FACE_HALFWORDS]u16,
	clut:   [COLOURS]u16,
}

@(private = "file")
faces: struct {
	portraits: [len(MASTER_FACES)]Portrait,
	// Master whose portrait is in VRAM, -1 = none; what it covered.
	shown:     int,
	saved:     Portrait,
} = {
	shown = -1,
}

// Draw master i's portrait with its top-left at (x, y). Returns false, with
// nothing drawn, when its area file cannot be read.
@(private)
master_face_draw :: proc(i, x, y: int) -> bool {
	p := &faces.portraits[i]
	if p.state == .Unread {
		p.state = face_read(MASTER_FACES[i].file, int(MASTER_FACES[i].face), p) ? .Read : .Failed
	}
	if p.state != .Read {
		return false
	}
	if faces.shown < 0 || !vram_holds(&faces.portraits[faces.shown]) {
		vram_swap(&faces.saved, false)
	}
	vram_swap(p, true)
	faces.shown = i
	face_quad(x, y)
	return true
}

// Give the borrowed VRAM back, unless the game has written there since.
@(private)
master_face_release :: proc() {
	if faces.shown < 0 {
		return
	}
	if vram_holds(&faces.portraits[faces.shown]) {
		vram_swap(&faces.saved, true)
	}
	faces.shown = -1
}

// Copy the portrait into VRAM (put) or VRAM into it.
@(private = "file")
vram_swap :: proc(p: ^Portrait, put: bool) {
	for y in 0 ..< FACE_H {
		for h in 0 ..< FACE_HALFWORDS {
			at := render.vram_at(i32(CELL_X + h), i32(PAGE_Y + y))
			if put {
				at^ = p.texels[y][h]
			} else {
				p.texels[y][h] = at^
			}
		}
	}
	for c in 0 ..< COLOURS {
		at := render.vram_at(i32(CLUT_X + c), CLUT_Y)
		if put {
			at^ = p.clut[c]
		} else {
			p.clut[c] = at^
		}
	}
}

@(private = "file")
vram_holds :: proc(p: ^Portrait) -> bool {
	for y in 0 ..< FACE_H {
		for h in 0 ..< FACE_HALFWORDS {
			if render.vram_at(i32(CELL_X + h), i32(PAGE_Y + y))^ != p.texels[y][h] {
				return false
			}
		}
	}
	for c in 0 ..< COLOURS {
		if render.vram_at(i32(CLUT_X + c), CLUT_Y)^ != p.clut[c] {
			return false
		}
	}
	return true
}

@(private = "file")
face_quad :: proc(x, y: int) {
	U0 :: FACE_X0
	U1 :: FACE_X0 + FACE_W
	corners := [4][2]int{{x, y}, {x + FACE_W, y}, {x, y + FACE_H}, {x + FACE_W, y + FACE_H}}
	texels := [4][2]int{{U0, 0}, {U1, 0}, {U0, FACE_H}, {U1, FACE_H}}
	extra := [4]u32{QUAD_CLUT << 16, QUAD_TPAGE << 16, 0, 0}
	prim := cpu.lw(SPRITE_PACKETS)
	cpu.sw(prim, QUAD_TAG)
	cpu.sw(prim + 4, QUAD_CMD)
	for k in 0 ..< 4 {
		at := prim + 8 + u32(k) * 8
		cpu.sw(at, u32(corners[k].x) & 0xffff | u32(corners[k].y) << 16)
		cpu.sw(at + 4, extra[k] | u32(texels[k].y) << 8 | u32(texels[k].x))
	}
	game_routine(PRIM_COMMIT, {1, QUAD_BYTES, 0, 0, 0})
}

// Read face k of the game file into p, from the disc.
@(private)
face_read :: proc(file: u32, k: int, p: ^Portrait) -> bool {
	lba := cpu.lw(FILE_TABLE + file * 4)
	header: [spu.DISC_DATA]u8
	if !spu.disc_read(lba, header[:]) {
		fmt.eprintf("masters: cannot read game file %x at sector %d\n", file, lba)
		return false
	}
	sheet, sheet_size, sheet_ok := emi_entry(header[:], SHEET_TYPE, SHEET_ADDR)
	palette, palette_size, palette_ok := emi_entry(header[:], PALETTE_TYPE, PALETTE_ADDR)
	fx, fy := FACE_X0 + FACE_W * (k % FACE_ROW), FACE_H * (k / FACE_ROW)
	first_row, last_row := fy / TILE_H, (fy + FACE_H - 1) / TILE_H
	// The sheet may stop short of a full last row of tiles.
	tile_count := (sheet_size + TILE_BYTES - 1) / TILE_BYTES
	last_tile := last_row * 2 + (fx + FACE_W - 1) / TILE_W
	if !sheet_ok || !palette_ok || last_tile >= tile_count || (k + 1) * COLOURS * 2 > palette_size {
		fmt.eprintf("masters: game file %x has no face %d\n", file, k)
		return false
	}
	#assert(TILE_BYTES == spu.DISC_DATA)
	tiles: [4][TILE_BYTES]u8 // two tile rows: a face spans at most two
	read_tiles := min(last_row * 2 + 2, tile_count) - first_row * 2
	assert(read_tiles <= len(tiles))
	clut: [spu.DISC_DATA]u8
	palette_sector := k * COLOURS * 2 / spu.DISC_DATA
	if !spu.disc_read(lba + sheet + u32(first_row * 2), (cast([^]u8)&tiles)[:read_tiles * TILE_BYTES]) ||
	   !spu.disc_read(lba + palette + u32(palette_sector), clut[:]) {
		fmt.eprintf("masters: cannot read face %d of game file %x\n", k, file)
		return false
	}
	for y in 0 ..< FACE_H {
		sy := fy + y - first_row * TILE_H
		for h in 0 ..< FACE_HALFWORDS {
			sx := fx + h * 4
			tile := &tiles[sy / TILE_H * 2 + sx / TILE_W]
			at := sy % TILE_H * (TILE_W / 2) + sx % TILE_W / 2
			p.texels[y][h] = u16(tile[at]) | u16(tile[at + 1]) << 8
		}
	}
	base := k * COLOURS * 2 % spu.DISC_DATA
	for c in 0 ..< COLOURS {
		p.clut[c] = u16(clut[base + c * 2]) | u16(clut[base + c * 2 + 1]) << 8
	}
	return true
}

// The entry of an area file header with this type and load address: its
// first sector from the file's start, and its size in bytes.
@(private)
emi_entry :: proc(header: []u8, type: u32, addr: u32) -> (sector: u32, size: int, ok: bool) {
	word :: proc(b: []u8, at: int) -> u32 {
		return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24
	}
	count := int(word(header, 0))
	if count > EMI_MAX_ENTRIES {
		return
	}
	offset := u32(EMI_DATA_AT)
	for i in 0 ..< count {
		at := EMI_ENTRY_AT + i * EMI_ENTRY_SIZE
		entry_size := word(header, at)
		if word(header, at + 12) & 0xffff == type && word(header, at + 4) == addr {
			return offset / EMI_ALIGN, int(entry_size), true
		}
		offset += (entry_size + EMI_ALIGN - 1) &~ (EMI_ALIGN - 1)
	}
	return
}

// Read len(buf) bytes from offset into the entry of a game file's area
// header with this type and load address.
@(private)
emi_read :: proc(file, type, addr: u32, offset: int, buf: []u8) -> bool {
	READ_MAX :: 8 // sectors
	lba := cpu.lw(FILE_TABLE + file * 4)
	header: [spu.DISC_DATA]u8
	if !spu.disc_read(lba, header[:]) {
		return false
	}
	sector, size, ok := emi_entry(header[:], type, addr)
	first := offset / spu.DISC_DATA
	count := (offset + len(buf) + spu.DISC_DATA - 1) / spu.DISC_DATA - first
	if !ok || offset + len(buf) > size || count > READ_MAX {
		return false
	}
	data: [READ_MAX * spu.DISC_DATA]u8
	if !spu.disc_read(lba + sector + u32(first), data[:count * spu.DISC_DATA]) {
		return false
	}
	copy(buf, data[offset - first * spu.DISC_DATA:])
	return true
}
