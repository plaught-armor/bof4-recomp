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
// and FlamePurge) is not shipped. `bof4tools dengeki-patch` builds its two files
// from the user's copy of the patch and disc into dengeki/ in the working
// directory. When they are there and the option is on, the game's file table
// points those two files at sectors past the disc's end, where
// disc.read_hook serves them. The patched files are longer than the disc's,
// so they cannot take the disc's place; the game sizes reads from the EMI
// header, not from the table.
package qol

import "core:fmt"
import "core:os"
import disc "ps:core/disc"
import cpu "ps:psx/cpu"
import spu "ps:psx/spu"

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
		f.lba = cpu.lw(FILE_TABLE + f.index * 4)
		path := fmt.tprintf("%s/%s", DENGEKI_DIR, f.name)
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			continue
		}
		if len(data) > ADDED_SPAN * spu.DISC_DATA {
			fmt.eprintfln("dengeki: %s is too long", path)
			delete(data)
			continue
		}
		f.data = data
		found = true
	}
	if found {
		disc.read_hook = dengeki_read
	}
	return true
}

// disc.read_hook: fill each sector of buf that falls in an added file's
// span (past its end, zeros). The rest keeps what the image gave; the read
// is valid if the image held it or every sector was filled.
@(private = "file")
dengeki_read :: proc(d: ^disc.Disc, lba: u32, buf: []u8, ok: bool) -> bool {
	all := true
	for s in 0 ..< len(buf) / disc.DATA {
		at := lba + u32(s)
		sector := buf[s * disc.DATA:][:disc.DATA]
		i := (at - ADDED_LBA) / ADDED_SPAN
		if at < ADDED_LBA || i >= u32(len(dengeki)) || dengeki[i].data == nil {
			all = false
			continue
		}
		from := int(at - ADDED_LBA - i * ADDED_SPAN) * disc.DATA
		n := 0
		if from < len(dengeki[i].data) {
			n = copy(sector, dengeki[i].data[from:])
		}
		for &b in sector[n:] {
			b = 0
		}
	}
	return ok || all
}

@(private)
dengeki_vblank :: proc() {
	glom := cpu.lbu(WORLD_FLAGS + MT_GLOM_BIT >> 3) & (1 << (MT_GLOM_BIT & 7)) != 0
	open := config.field_dengeki && glom
	for bit in DENGEKI_BITS {
		addr := WORLD_FLAGS + bit >> 3
		old := cpu.lbu(addr)
		mask := u32(1) << (bit & 7)
		now := open ? old | mask : old &~ mask
		if now != old {
			cpu.sb(addr, now)
		}
	}
	for f, i in dengeki {
		lba := config.field_dengeki && f.data != nil ? ADDED_LBA + u32(i) * ADDED_SPAN : f.lba
		if cpu.lw(FILE_TABLE + f.index * 4) != lba {
			cpu.sw(FILE_TABLE + f.index * 4, lba)
		}
	}
}
