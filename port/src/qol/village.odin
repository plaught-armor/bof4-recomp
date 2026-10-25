// Noritake's Town (not a game feature): a village map cut from the game
// (AREAM019, map 0x1013), left on the US disc with its Japanese text. It is
// a test town: villagers who only say "talk", a shop, a Manillo fish trader,
// a Dragon God statue, and two masters from an early draft, the fisherman
// Gyosil (his text only) and Beito, who wants his pupils to take life slow
// and rewards play time. Its exits lead to the Dengeki forest (map 0444),
// but nothing leads to it.
//
// With `[field] dengeki`, once the map's text (bank 0 at 0x80010000) has
// loaded and hashes to the disc's, it is replaced by this port's own
// literal English translation: the same 256 message ids, each pointing at
// the English for the Japanese message it pointed at, with the Japanese
// text codes kept (choices, colours, pupil and reward names). The forest
// gets a way in: its north dead end (cells 23..26 of row 5, where the
// village's west exit arrives) becomes an exit to the village's west gate.
package qol

import "core:hash"
import "ps:psx"

@(private = "file")
VILLAGE_MAP :: 0x1013
@(private = "file")
BANK :: 0x80010000
@(private = "file")
BANK_SIZE :: 0xb54
@(private = "file")
BANK_HASH :: 0x9db92e78 // FNV-1a of the disc's bank
@(private = "file")
BANK_IDS :: 256
// Room for the English: the longest map text (0x5f6d bytes) is loaded to
// the same address, and teacher.odin's text starts at 0x80016c00.
@(private = "file")
BANK_MAX :: 0x6c00

// The English for the Japanese message at each offset of the disc's bank.
// Text codes: 01 a line, 02 a page, 05 n .. 06 a colour, 07 02 the pupil's
// name, 07 01 the reward's name, 07 00 a value, 0b a pause, 14 i 0c n a
// choice (options split by 01), 1c 00 a shop or statue message, 04 the
// message goes on into the next. The Japanese has no faces; a speaker's
// name heads their first page, as the US release writes it.
@(private = "file")
Village_Line :: struct {
	disc: u16, // offset of the Japanese message in the disc's bank
	text: string,
}

@(private = "file")
VILLAGE_TEXT :: [?]Village_Line {
	{0x200, "Noritake's Town"},
	{0x20a, "(talk)"},
	{0x20e, "\x1c\x00\"Want to buy something?\"\x14\x85\x0c\x93Buy\x01Sell\x01Never mind"},
	{0x22a, "\"Welcome!\"\x14\x85\x0c\x93Let's trade\x01Exchange prizes\x01Never mind"},
	{0x252, "\x1c\x00A Dragon God statue.\x14\x87\x0c\x93Rest\x01Save\x01Never mind"},
	// Gyosil.
	{0x26f, "Gyosil\x01\"Whoo-ee!\x01Ya like fishin', bub?\x02Fishin' is what a man\x01lives for! Don'tcha\x01think so too, bub?\x02If ya like, I could\x01teach ya my tricks...\x02Whaddaya say?\x01Interested?\"\x14\x82\x0c\x92Sure am\x01Nah, not me"},
	{0x2f2, "\"Yee-haw! Let's get\x01right to it! I'll teach\x01ya my trick.\x02It's called \x05\x04Mind's Eye\x06,\x01an' it never misses\x01its mark!\x02With \x05\x04Mind's Eye\x06 ya get\x01a cool head that sits\x01tight till the fish bite.\x02Ain't that somethin'?\x01So, which o' you fellers\x01wants to learn it?\""},
	{0x39c, "\"...Let's see... When\x01yer fishin' rank hits\x01\x05\x02\x07\x00\x06, tell me, bub.\x02I'll give ya a real\x01special present\x01o' mine.\""},
	{0x3e0, "\"Pfah! Ya ain't got\x01enough fishin' skill!\x02Ya need at least\x01\x05\x02Rod Man\x06-level skill,\x01or it's no good!\""},
	{0x414, "\"I'm always right here,\x01so come on back!\""},
	{0x42c, "Gyosil\x01\"Whoo-ee!\x01Nice day again today!\""},
	{0x44a, "\"Hoo-wee, bub! Looks\x01like ya done a whole\x01lotta fishin'!\x02All right, here ya go:\x01\x05\x03\x07\x01\x06!\""},
	{0x488, "\"Now then...\x0b\x01aim fer \x05\x02\x07\x00\x06 next!\x02If ya keep at it, I'll\x01give ya somethin' good\x01again.\x0b\""},
	{0x4c7, "\"Well I'll be...\x0b\x01bub, ya done mastered\x01fishin' at last...\x02Yer a fine fisherman\x01now, one everybody'd\x01look up to.\""},
	{0x50f, "\"Bub, ya got some\x01business with me?\"\x14\x82\x0c\x93I'll follow ya\x01Can't follow ya\x01Nothin'"},
	{0x54e, "\"Got any other\x01business with me?\"\x14\x82\x0c\x93I'll follow ya\x01Can't follow ya\x01Nothin'"},
	{0x588, "\"You fellers all know\x01my \x05\x04Mind's Eye\x06.\""},
	{0x5a9, "\"All right...\x0b\x0b\x01I'm trustin' \x07\x02 with\x01my \x05\x04Mind's Eye\x06!\""},
	{0x5c8, "\"All right...\x0b\x0b\x01I'm trustin' you all\x01with my \x05\x04Mind's Eye\x06!\""},
	{0x5ea, "\"Pfah! Ain't none o' ya\x01got eyes fer my\x01\x05\x04Mind's Eye\x06...?\""},
	{0x609, "\"None o' you fellers\x01knows \x05\x04Mind's Eye\x06.\""},
	{0x628, "\"Aw shucks, now\x01\x07\x02 can't use\x01\x05\x04Mind's Eye\x06 no more.\""},
	{0x649, "\"Aw shucks, now you\x01fellers can't use\x01\x05\x04Mind's Eye\x06 no more.\""},
	{0x66d, "\"Heh! Don't go scarin'\x01me like that, bub!\""},
	{0x67e, "\"Well then, come see\x01me when ya reach\x01\x05\x02\x07\x00\x06.\x02When ya do, I'll give\x01ya my special\x01present!\""},
	{0x6b5, "Gyosil\x01\"Nice day again today!\""},
	{0x6cd, "Rod Man+"},
	{0x6d4, "Rod Master"},
	{0x6dc, "The Fish"},
	{0x6e4, "Not used here"},
	{0x6f3, "Not used here"},
	{0x702, "Ring of Ice"},
	{0x709, "Blue Note"},
	{0x710, "Master's Rod"},
	{0x717, "Not used here"},
	{0x726, "Not used here"},
	// Beito.
	{0x735, "Beito\x01\"Oh, hello there.\x02I've always lived here,\x01taking it nice and slow.\x02Meeting like this must\x01be fate... Want to take\x01life slow with me?\"\x14\x82\x0c\x82Yes\x01No"},
	{0x791, "\"Then from now on, let's\x01take it slow together.\x02So, who's going to\x01follow someone like me?\""},
	{0x7c5, "\"Check your play time,\x01and when it's past\x01\x05\x02\x07\x00\x06, tell me.\x02To friends like you,\x01I'll give a special\x01present of mine.\""},
	{0x809, "\"I see...\x0b\x0b Oh well.\x01If it catches your\x01interest, call on me.\""},
	{0x82b, "\"I'm always right here,\x01so come visit again.\""},
	{0x846, "Beito\x01\"Oh, you came back?\x02When I watch people\x01rushing down the road,\x01I wonder if I'm wrong.\x02But it's not like I\x01can change how I live\x01overnight.\""},
	{0x8aa, "\"Oh?\x04"},
	{0x8d7, "\"Now then...\x0b\x01tell me when your play\x01time passes \x05\x02\x07\x00\x06.\x02I'll give you another\x01present.\""},
	{0x905, "\"Amazing...\x0b\x02I've lived slow too, but\x01I'm no match for you.\x02I've nothing more to\x01give, but let's keep\x01taking it slow!\""},
	{0x953, "\"By the way, is there\x01something you need?\"\x14\x82\x0c\x93I'll take it slow\x01Can't take it slow\x01Nothing"},
	{0x985, "\"Anything else?\"\x14\x82\x0c\x93I'll take it slow\x01Can't take it slow\x01Nothing"},
	{0x9ac, "\"Everyone's taking it\x01slow. Let's keep it up!\""},
	{0x9c7, "\"Good...\x0b\x0b\x01\x07\x02, let's take it\x01slow from today.\""},
	{0x9e1, "\"Good...\x0b\x0b\x01Let's all take it slow\x01from today.\""},
	{0x9fd, "\"Huh...?\x0b\x0b\x01Doesn't anyone want to\x01take it slow?\""},
	{0xa17, "\"Everyone's living in\x01such a hurry. Let's\x01take life slower!\""},
	{0xa37, "\"I see...\x0b Oh well.\x01\x07\x02 will go through\x01life in a hurry.\""},
	{0xa57, "\"I see...\x0b Oh well.\x01You'll all go through\x01life in a hurry, then.\""},
	{0xa78, "\"Oh?\x0b\x0b Looks like\x01nobody's quitting\x01after all.\""},
	{0xa92, "\"Then when you reach\x01\x05\x02\x07\x00\x06, come see me.\x02I've got a special\x01present for you.\""},
	{0xaba, "Beito\x01\"Nice weather today.\x01Best to take it slow.\x02What are you hurrying\x01for?\""},
	{0xaf1, "20 hours"},
	{0xaf8, "25 hours"},
	{0xaff, "30 hours"},
	{0xb06, "Not used here"},
	{0xb15, "Not used here"},
	{0xb24, "Withdraw"},
	{0xb2b, "Backhand"},
	{0xb30, "Megaphone"},
	{0xb35, "Not used here"},
	{0xb44, "Not used here"},
	{0xb53, ""}, // the ids past the last message
}

// The forest's section 0: its exit list, hashed with the 0xffff that ends
// it, and the new exit, written past it to free RAM (past teacher.odin's
// text, before bank 2's table at 0x80017000) since the list sits in the
// map overlay's data with nothing free after it.
@(private = "file")
FOREST_MAP :: 0x0444
@(private = "file")
FOREST_EXITS :: 3
@(private = "file")
FOREST_HASH :: 0xaf68d17c
@(private = "file")
FOREST_LIST :: 0x80016f00
@(private = "file")
EXITS :: 0x80116be8 // u32 -> u32 -> per-section exit lists
@(private = "file")
EXIT_SIZE :: 12
// Along x from cell 23, 5, four cells, to the village's section 0, arriving
// at 5, 17 (256 a cell) facing north (0): the facing is also the way
// through, so walking north into the dead end takes it.
@(private = "file")
FOREST_X :: 23
@(private = "file")
FOREST_Z :: 5
@(private = "file")
FOREST_CELLS :: 4
@(private = "file")
FOREST_ENTRY :: [EXIT_SIZE]u8{0x13, 0x10, 0, 0, FOREST_X, FOREST_Z, 0x00, 0x05, 0x00, 0x11, FOREST_CELLS, 0}
@(private = "file")
EXIT_ATTR :: 0xa0

@(private)
village_vblank :: proc() {
	if !config.field_dengeki {
		return
	}
	if psx.lhu(MAP_ID) == FOREST_MAP && psx.r8(MAP_SECTION) == 0 {
		forest_entry()
	}
	if psx.lhu(MAP_ID) != VILLAGE_MAP {
		return
	}
	disc := psx.ram[BANK & (psx.RAM_SIZE - 1):][:BANK_SIZE]
	if hash.fnv32a(disc) != BANK_HASH {
		return
	}
	// Each message's new offset, then the table pointing each id at the
	// English for its Japanese message.
	lines := VILLAGE_TEXT
	at: [len(lines)]u32
	next := u32(BANK_IDS * 2)
	for l, i in lines {
		at[i] = next
		next += u32(len(l.text)) + 1
	}
	assert(next <= BANK_MAX, "village text too long")
	table: [BANK_IDS]u32
	for id in 0 ..< BANK_IDS {
		offset := u16(disc[id * 2]) | u16(disc[id * 2 + 1]) << 8
		found := false
		for l, i in lines {
			if l.disc == offset {
				table[id] = at[i]
				found = true
				break
			}
		}
		assert(found, "village message without English")
	}
	out := psx.mem_slice(BANK, next)
	for t, id in table {
		out[id * 2] = u8(t)
		out[id * 2 + 1] = u8(t >> 8)
	}
	for l, i in lines {
		copy(out[at[i]:], l.text)
		out[at[i] + u32(len(l.text))] = 0
	}
}

// Points the forest's section 0 at a copy of its exits with the village's
// added, and marks the new exit's cells on its first layer.
@(private = "file")
forest_entry :: proc() {
	base := psx.lw(EXITS)
	if !in_ram(base) || !in_ram(psx.lw(base)) {
		return
	}
	slot := psx.lw(base)
	list := psx.lw(slot)
	if list != FOREST_LIST {
		size := u32(FOREST_EXITS * EXIT_SIZE + 2)
		if !in_ram(list) || hash.fnv32a(psx.mem_slice(list, size)) != FOREST_HASH {
			return
		}
		out := psx.mem_slice(FOREST_LIST, size + EXIT_SIZE)
		copy(out, psx.mem_slice(list, FOREST_EXITS * EXIT_SIZE))
		entry := FOREST_ENTRY
		copy(out[FOREST_EXITS * EXIT_SIZE:], entry[:])
		out[size + EXIT_SIZE - 2] = 0xff
		out[size + EXIT_SIZE - 1] = 0xff
		psx.sw(slot, FOREST_LIST)
	}
	block := psx.lw(MAP_BLOCK)
	if !in_ram(block) {
		return
	}
	desc := block + psx.lw(block + 0xc4)
	grid := block + psx.lw(block + 4 + 4 * u32(psx.r8(desc)))
	attrs := block + psx.lw(block + 0xa4 + 4 * u32(psx.r8(desc + 1)))
	row := attrs + FOREST_Z * u32(psx.r16(grid)) * 2
	for x in u32(FOREST_X) ..< FOREST_X + FOREST_CELLS {
		psx.w8(row + x, EXIT_ATTR)
	}
}
