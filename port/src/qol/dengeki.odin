// The Dengeki store, cut from the US release: a forest with a house
// (AREAD068, map 0x0444) and the store inside (AREAS052, map 0x0234), where
// one Manillo sells weapons and items and another runs a lottery. Its text is
// still Japanese. The maps are on the US disc; only the world map hides them.
//
// The world map node (node 34, "?", south-west of Mt. Glom) shows while bit
// 0xa5 of the world map word (area 0x2a, 0x8011b878) is set, and its road to
// Mt. Glom (edge 0x27) needs that bit and Mt. Glom's own, bit 0x5a. Bit 0x8d
// of the same word opens the place: without it the forest's overlay
// (AREAD068 #11) disables the house door (object 0x2b) and the store's
// (AREAS052 #12) disables object 0x16. Nothing in the US game sets either
// bit; the fan patch's memory card patcher sets them in a save. With
// `[field] dengeki` both are set once Mt. Glom is on the map, and cleared
// again when the option is off, so saves made either way load clean.
//
// The fan translation (Dengeki Store Restoration v1.0, by Navarchos, Ratty
// and FlamePurge) is not shipped. tools/dengeki_patch.py builds its two files
// from the user's copy of the patch and disc into dengeki/ in the working
// directory. When they are there and the option is on, the game's file table
// points those two files at sectors past the disc's end, where
// psx.sector_hook serves them. The patched files are longer than the disc's,
// so they cannot take the disc's place; the game sizes reads from the EMI
// header, not from the table.
package qol

import "core:fmt"
import "core:os"
import "../psx"

@(private = "file")
WORLD_FLAGS :: 0x8011b878
@(private = "file")
MT_GLOM_BIT :: 0x5a
@(private = "file")
DENGEKI_BITS :: [?]u32{0xa5, 0x8d}
@(private = "file")
DENGEKI_DIR :: "dengeki"
@(private = "file")
ADDED_LBA :: 400_000 // past the disc's end, still within 99 minutes
@(private = "file")
ADDED_SPAN :: 2048 // sectors per added file

@(private = "file")
Dengeki_File :: struct {
	index: u32, // in FILE_TABLE
	name:  string,
	lba:   u32, // the disc's
	data:  []u8, // the translated file, nil when not built
}

@(private = "file")
dengeki := [?]Dengeki_File{{index = 0x28e, name = "AREAD068.EMI"}, {index = 0x3b7, name = "AREAS052.EMI"}}

@(private)
dengeki_init :: proc() -> bool {
	found := false
	for &f in dengeki {
		f.lba = psx.lw(FILE_TABLE + f.index * 4)
		path := fmt.tprintf("%s/%s", DENGEKI_DIR, f.name)
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			continue
		}
		if len(data) > ADDED_SPAN * psx.DISC_DATA {
			fmt.eprintfln("dengeki: %s is too long", path)
			delete(data)
			continue
		}
		f.data = data
		found = true
	}
	if found {
		psx.sector_hook = dengeki_sector
	}
	return true
}

@(private = "file")
dengeki_sector :: proc(lba: u32) -> []u8 {
	if lba < ADDED_LBA {
		return nil
	}
	i := (lba - ADDED_LBA) / ADDED_SPAN
	if i >= len(dengeki) || dengeki[i].data == nil {
		return nil
	}
	at := int(lba - ADDED_LBA - i * ADDED_SPAN) * psx.DISC_DATA
	@(static) sector: [psx.DISC_DATA]u8
	sector = {}
	if at < len(dengeki[i].data) {
		copy(sector[:], dengeki[i].data[at:])
	}
	return sector[:]
}

@(private)
dengeki_vblank :: proc() {
	glom := psx.lbu(WORLD_FLAGS + MT_GLOM_BIT >> 3) & (1 << (MT_GLOM_BIT & 7)) != 0
	open := config.field_dengeki && glom
	for bit in DENGEKI_BITS {
		addr := WORLD_FLAGS + bit >> 3
		old := psx.lbu(addr)
		mask := u32(1) << (bit & 7)
		now := open ? old | mask : old &~ mask
		if now != old {
			psx.sb(addr, now)
		}
	}
	for f, i in dengeki {
		lba := config.field_dengeki && f.data != nil ? ADDED_LBA + u32(i) * ADDED_SPAN : f.lba
		if psx.lw(FILE_TABLE + f.index * 4) != lba {
			psx.sw(FILE_TABLE + f.index * 4, lba)
		}
	}
}
