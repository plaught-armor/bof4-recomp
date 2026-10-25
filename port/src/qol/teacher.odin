// The combo dog (not a game feature): a travelling dog who turns up in towns
// along the story and teaches the magic combos (combos.odin), a level at a
// time, and in four world map "?" scenes, where he teaches a character's
// special. With `[field] teacher`, talking to the dog at each stop marks his
// lesson's combos (or special) as known (names and recipes on the Combos
// page and in the Combos battle line).
//
// Talking to an NPC shows its message through MESSAGE_TEXT (a0 the id), so
// the dog's message id on a stop's map gets the lesson's text instead,
// built in RAM no map's text reaches.
//
// Sarai has a dog of its own. The other stops (towns and scenes) get one added when the map
// spawns its people: Sarai's dog sprite (sheet, CLUT and animation bank,
// read from AREAM000 on the disc) is appended to the map's sprite table and
// copied into VRAM the town leaves empty, then a spawn record of ours runs
// through the game's spawn list runner. His portrait (AREAM006 face 2) goes
// into a face cell and CLUT row no town's face sheet reaches.
package qol

import "core:fmt"
import "core:strings"

import "ps:psx"

import "ps:core"


// Free RAM: past the longest map text (bank 0 at 0x80010000, at most 0x5f6d
// bytes) and before bank 2's table at 0x80017000.
@(private = "file")
TEXT_AT :: 0x80016c00
@(private = "file")
TEXT_MAX :: 0x300

// Text codes: a line break, the next page, the speaker's face (face, CLUT
// byte), and the end.
@(private = "file")
LINE :: 0x01
@(private = "file")
PAGE :: 0x02
@(private = "file")
FACE :: 0x17
@(private = "file")
END :: 0x00

// The map's sprite table (area entry 0): a u32 count, then 8-byte entries
// {u16 sprite id, u8 slot, u8 0, u8 texture page x / 64, u8 v, u16 0}. An
// entry's index picks its animation bank in the table at ANIM_TABLE_PTR
// (u32 offsets from the table, area entry 1); its slot picks its CLUT, kept
// in RAM at SPRITE_CLUTS + slot * 32 and in VRAM row 496 + (slot + 16) / 16.
@(private = "file")
SPRITE_TABLE :: 0x8004e000
@(private = "file")
SPRITE_TABLE_PTR :: 0x8011a850 // u32, SPRITE_TABLE + 4
@(private = "file")
ANIM_TABLE :: 0x8003e000
@(private = "file")
ANIM_TABLE_PTR :: 0x8011a84c // u32, ANIM_TABLE
@(private = "file")
SPRITE_CLUTS :: 0x80038200
@(private = "file")
SPRITE_SLOTS :: 48
@(private = "file")
SPRITE_SHEETS :: 0x0c000e00 // type 3: 32x32-halfword tiles from VRAM (384, 0), 14 across
@(private = "file")
SHEET_TILE :: 32
@(private = "file")
RAM_TYPE :: 0
@(private = "file")
VRAM_TYPE :: 3
@(private = "file")
TABLE_MAX :: 64 // sprite table entries

// Free RAM in every stop's town (past the largest entry 1 and before the
// sprite table; past the sprite table): the animation table rebuilt with
// the dog's bank after it, and the dog's spawn list.
@(private = "file")
ANIM_AT :: 0x8004b000
@(private = "file")
BANK_AT :: ANIM_AT + TABLE_MAX * 4
@(private = "file")
BANK_MAX :: 0x800
@(private = "file")
RECORD_AT :: 0x8004e7f0
@(private = "file")
RECORD_SIZE :: 14
// The record's script byte indexes the map's script table (its header's
// +32), which in a scene may not hold the index or be there at all, so the
// dog's slot gets no script (a null pointer). The wander step (FLD
// 0x801db45c) leaves a slot alone with NPC_STAY set; Sarai's dog's script
// sets it. The slot's init (FLD 0x801e0598) runs after the spawn list and
// rewrites NPC_MODE, so dog_hold runs each field frame too.
@(private = "file")
NPC_SCRIPT :: 0xb0 // u32, the slot's script pointer
@(private = "file")
NPC_MESSAGE :: 0xc0 // u16, the slot's message id
@(private = "file")
NPC_MODE :: 0xc4 // u8: bit 0 talks (a message id set), bit 1 NPC_STAY
@(private = "file")
NPC_STAY :: 0x02
#assert(BANK_AT + BANK_MAX <= SPRITE_TABLE)

// FLD: a0 a spawn list (records, 0xff at the end), run as SPAWN runs the map's.
@(private = "file")
SPAWN_LIST :: 0x801dfde8

@(private = "file")
DOG_SPRITE :: 0x7c
@(private = "file")
DOG_FILE :: 0x34b // AREAM000, Sarai
@(private = "file")
DOG_ROWS :: 136 // of his sheet, 64 halfwords wide
@(private = "file")
DOG_HALFWORDS :: 64
@(private = "file")
DOG_FACE_FILE :: 0x351 // AREAM006
@(private = "file")
DOG_FACE_INDEX :: 2
// Face 24 of the sheet at (960, 256), past every town's sheet; the CLUT
// byte 0x1f puts its CLUT at (240, 255), a row the towns leave free.
@(private = "file")
DOG_FACE :: [2]u8{24, 0x1f}
@(private = "file")
FACE_CELL_X :: 960 + (8 + FACE_W * (24 % 6)) / 4
@(private = "file")
FACE_CELL_Y :: 256 + FACE_H * (24 / 6)
@(private = "file")
FACE_CLUT_X :: 240
@(private = "file")
FACE_CLUT_Y :: 255
@(private = "file")
DOG_MESSAGE :: 0x0fff // bank 0, past every map's messages

// A place the dog teaches in: the dog's message id (for the town's own dog,
// its spawn record's u16 +9), the face code of his portrait, and the combo
// level he teaches, or at a scene the special. An added dog stands at tile,
// his sheet at texture page x / 64 and v.
@(private = "file")
Stop :: struct {
	town:    string, // or the scene, as the Journal names it
	map_id:  u16,
	section: u8,
	message: u16,
	face:    [2]u8,
	level:   int, // 1..4, 0 at a scene
	special: int, // 0..3 (special(n)), at a scene
	added:   bool,
	tile:    [2]u8,
	page:    u8,
	v:       u8,
}

// Sarai's dog stands at tile 34,17 (record at 0x801f248d, "whine!"). The
// added dogs stand a few cells in from the world map exit, their sheets on
// texture pages the town's sprite sheet entry loads as zeros.
@(private = "file")
STOPS :: [?]Stop {
	{town = "Sarai", map_id = 0x1000, section = 0, message = 0x0012, face = {9, 6}, level = 1},
	{town = "Synesta", map_id = 0x1002, message = DOG_MESSAGE, face = DOG_FACE, level = 2, added = true, tile = {24, 23}, page = 5, v = 112}, // Synesta
	{town = "Wyndia", map_id = 0x1009, message = DOG_MESSAGE, face = DOG_FACE, level = 3, added = true, tile = {14, 13}, page = 0xb}, // Wyndia
	{town = "Shyde", map_id = 0x1021, message = DOG_MESSAGE, face = DOG_FACE, level = 4, added = true, tile = {18, 15}, page = 0xb}, // Shyde
	// World map "?" scenes, in story order (docs/story-and-maps.md), the dog
	// a few cells from where the party enters.
	{town = "a house in the woods", map_id = 0x0807, message = DOG_MESSAGE, face = DOG_FACE, special = 0, added = true, tile = {27, 13}, page = 0xb},
	{town = "a desert camp", map_id = 0x0832, message = DOG_MESSAGE, face = DOG_FACE, special = 1, added = true, tile = {16, 15}, page = 0xb},
	{town = "a forest path", map_id = 0x0830, message = DOG_MESSAGE, face = DOG_FACE, special = 2, added = true, tile = {9, 51}, page = 0xb},
	{town = "a beach", map_id = 0x084b, message = DOG_MESSAGE, face = DOG_FACE, special = 3, added = true, tile = {17, 82}, page = 0xb},
}

// Sarai's dog, read once from the disc.
@(private = "file")
Dog :: struct {
	state:     enum u8 {Unread, Read, Failed},
	sheet:     [DOG_ROWS][DOG_HALFWORDS]u16,
	clut:      [COLOURS]u16,
	bank:      [BANK_MAX]u8,
	bank_size: int,
	face:      Portrait,
}

@(private = "file")
teacher: struct {
	message_text: psx.Func_Proc,
	spawn:        psx.Func_Proc,
	field:        psx.Func_Proc,
	dog:          Dog,
}

@(private)
teacher_init :: proc() -> bool {
	teacher.message_text = psx.hook(MESSAGE_TEXT, message_text) or_return
	teacher.spawn = hook_field(SPAWN, spawn) or_return
	teacher.field = hook_game_mode(MODE_FIELD, field_tick) or_return
	return true
}

// The stop on this map and section, if it is one where the dog is added.
@(private = "file")
added_stop :: proc() -> (Stop, bool) {
	if config.field_teacher {
		for s in STOPS {
			if s.added && u32(s.map_id) == psx.lhu(MAP_ID) && u32(s.section) == psx.lbu(MAP_SECTION) {
				return s, true
			}
		}
	}
	return {}, false
}

@(private = "file")
spawn :: proc() {
	teacher.spawn()
	s, ok := added_stop()
	if !ok || !dog_read() {
		return
	}
	if !sprite_add(s) {
		if .Game in core.trace.active {
			core.tracef(.Game, "combo dog: no room for his sprite on map %04x", s.map_id)
		}
		return
	}
	// Sarai's dog's record with our tile and message, standing; script 0,
	// then none, and he stays put.
	record := [RECORD_SIZE]u8 {
		0, DOG_SPRITE, 0, s.tile.x, s.tile.y, 0, 0x80, 0, 0x01, 0x82,
		u8(DOG_MESSAGE & 0xff), u8(DOG_MESSAGE >> 8), 0, 0xff,
	}
	for b, i in record {
		psx.sb(RECORD_AT + u32(i), u32(b))
	}
	game_routine(SPAWN_LIST, {RECORD_AT, 0, 0, 0, 0})
	dog_hold()
	if .Game in core.trace.active {
		core.tracef(.Game, "combo dog added on map %04x at %d,%d", s.map_id, s.tile.x, s.tile.y)
	}
}

// The added dog's slot: no script, and he stays put.
@(private = "file")
dog_hold :: proc() {
	for i in u32(0) ..< NPC_COUNT {
		npc := NPCS + i * NPC_SIZE
		if psx.lbu(npc) != 0 && psx.lhu(npc + NPC_MESSAGE) == DOG_MESSAGE {
			psx.sw(npc + NPC_SCRIPT, 0)
			psx.sb(npc + NPC_MODE, psx.lbu(npc + NPC_MODE) | NPC_STAY)
		}
	}
}

// Read Sarai's dog from the disc, once.
@(private = "file")
dog_read :: proc() -> bool {
	d := &teacher.dog
	if d.state == .Unread {
		d.state = .Read if dog_read_disc(d) else .Failed
		if d.state == .Failed {
			fmt.eprintln("teacher: cannot read the dog's sprite from the disc")
		}
	}
	return d.state == .Read
}

@(private = "file")
dog_read_disc :: proc(d: ^Dog) -> bool {
	word :: proc(b: []u8, at: int) -> u32 {
		return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24
	}
	count: [4]u8
	emi_read(DOG_FILE, RAM_TYPE, SPRITE_TABLE, 0, count[:]) or_return
	n := int(word(count[:], 0))
	if n > TABLE_MAX {
		return false
	}
	table: [TABLE_MAX * 8]u8
	offsets: [TABLE_MAX * 4]u8
	emi_read(DOG_FILE, RAM_TYPE, SPRITE_TABLE, 4, table[:n * 8]) or_return
	emi_read(DOG_FILE, RAM_TYPE, ANIM_TABLE, 0, offsets[:n * 4]) or_return
	index := -1
	for i in 0 ..< n {
		if u32(table[i * 8]) | u32(table[i * 8 + 1]) << 8 == DOG_SPRITE {
			index = i
		}
	}
	if index < 0 {
		return false
	}
	slot, page, v := int(table[index * 8 + 2]), int(table[index * 8 + 4]), int(table[index * 8 + 5])
	// His bank runs to the next bank up.
	start := word(offsets[:], index * 4)
	end := max(u32)
	for i in 0 ..< n {
		at := word(offsets[:], i * 4)
		if at > start && at < end {
			end = at
		}
	}
	if end == max(u32) || end - start > BANK_MAX {
		return false
	}
	d.bank_size = int(end - start)
	emi_read(DOG_FILE, RAM_TYPE, ANIM_TABLE, int(start), d.bank[:d.bank_size]) or_return
	clut: [COLOURS * 2]u8
	emi_read(DOG_FILE, RAM_TYPE, SPRITE_CLUTS, slot * len(clut), clut[:]) or_return
	for c in 0 ..< COLOURS {
		d.clut[c] = u16(clut[c * 2]) | u16(clut[c * 2 + 1]) << 8
	}
	// Two tiles across, a band of tile rows at a time.
	x := page * 64 - (SPRITE_SHEETS >> 24) * SHEET_TILE
	across := (SPRITE_SHEETS >> 8) & 0xff
	if x < 0 || x % SHEET_TILE != 0 {
		return false
	}
	tiles: [2 * SHEET_TILE * SHEET_TILE * 2]u8
	for band in v / SHEET_TILE ..= (v + DOG_ROWS - 1) / SHEET_TILE {
		tile := band * across + x / SHEET_TILE
		emi_read(DOG_FILE, VRAM_TYPE, SPRITE_SHEETS, tile * len(tiles) / 2, tiles[:]) or_return
		for y in max(band * SHEET_TILE, v) ..< min(band * SHEET_TILE + SHEET_TILE, v + DOG_ROWS) {
			for h in 0 ..< DOG_HALFWORDS {
				at := h / SHEET_TILE * len(tiles) / 2 + y % SHEET_TILE * SHEET_TILE * 2 + h % SHEET_TILE * 2
				d.sheet[y - v][h] = u16(tiles[at]) | u16(tiles[at + 1]) << 8
			}
		}
	}
	return face_read(DOG_FACE_FILE, DOG_FACE_INDEX, &d.face)
}

// Give the map's sprite table the dog and put his sheet and CLUT in VRAM;
// false, with nothing changed, when there is no room. A table that already
// holds him (the town's own, or ours from an earlier spawn) is kept. His
// sheet's place is the stop's, checked free in the town beforehand: when
// the map spawns, VRAM may still hold the last map's.
@(private = "file")
sprite_add :: proc(s: Stop) -> bool {
	n := psx.lw(SPRITE_TABLE)
	if psx.lw(SPRITE_TABLE_PTR) != SPRITE_TABLE + 4 || n >= TABLE_MAX {
		return false
	}
	slot := u32(0)
	for i in 0 ..< n {
		entry := SPRITE_TABLE + 4 + i * 8
		if psx.lhu(entry) == DOG_SPRITE {
			return true
		}
		slot = max(slot, psx.lbu(entry + 2) + 1)
	}
	if slot >= SPRITE_SLOTS || psx.lw(ANIM_TABLE_PTR) != ANIM_TABLE {
		return false
	}
	// A slot past the town's CLUTs, which the map's load leaves zero (VRAM
	// may still hold the last map's until the game uploads them).
	for c in u32(0) ..< COLOURS {
		if psx.lhu(SPRITE_CLUTS + slot * 32 + c * 2) != 0 {
			return false
		}
	}
	sheet_put(s, slot)
	for i in 0 ..< n {
		psx.sw(ANIM_AT + i * 4, psx.lw(ANIM_TABLE + i * 4) + ANIM_TABLE - ANIM_AT)
	}
	psx.sw(ANIM_AT + n * 4, BANK_AT - ANIM_AT)
	for b, i in teacher.dog.bank[:teacher.dog.bank_size] {
		psx.sb(BANK_AT + u32(i), u32(b))
	}
	psx.sw(ANIM_TABLE_PTR, ANIM_AT)
	entry := SPRITE_TABLE + 4 + n * 8
	psx.sh(entry, DOG_SPRITE)
	psx.sh(entry + 2, slot)
	psx.sh(entry + 4, u32(s.page) | u32(s.v) << 8)
	psx.sh(entry + 6, 0)
	psx.sw(SPRITE_TABLE, n + 1)
	return true
}

// Whether VRAM holds the dog's sheet and CLUT.
@(private = "file")
sheet_holds :: proc(s: Stop, slot: u32) -> bool {
	d := &teacher.dog
	x, y, cx, cy := sheet_at(s, slot)
	for row in 0 ..< DOG_ROWS {
		for h in 0 ..< DOG_HALFWORDS {
			if psx.vram_at(x + i32(h), y + i32(row))^ != d.sheet[row][h] {
				return false
			}
		}
	}
	for c in 0 ..< COLOURS {
		if psx.vram_at(cx + i32(c), cy)^ != d.clut[c] {
			return false
		}
	}
	return true
}

@(private = "file")
sheet_put :: proc(s: Stop, slot: u32) {
	d := &teacher.dog
	x, y, cx, cy := sheet_at(s, slot)
	for row in 0 ..< DOG_ROWS {
		for h in 0 ..< DOG_HALFWORDS {
			psx.vram_put(x + i32(h), y + i32(row), d.sheet[row][h])
		}
	}
	for c in 0 ..< COLOURS {
		psx.vram_put(cx + i32(c), cy, d.clut[c])
		psx.sh(SPRITE_CLUTS + slot * 32 + u32(c) * 2, u32(d.clut[c]))
	}
}

// The VRAM of the dog's sheet and of his CLUT.
@(private = "file")
sheet_at :: proc(s: Stop, slot: u32) -> (x, y, clut_x, clut_y: i32) {
	clut := i32(slot) + 16
	return i32(s.page) * 64, i32(s.v), clut % 16 * 16, 496 + clut / 16
}

// On an added stop, hold the dog still and keep his sheet, CLUT and
// portrait in VRAM: a menu or the game may have written over them since he
// was added.
@(private = "file")
field_tick :: proc() {
	teacher.field()
	s, ok := added_stop()
	if !ok || psx.lhu(GAME_MODE) != GAME_MODE_FIELD || teacher.dog.state != .Read {
		return
	}
	dog_hold()
	face := &teacher.dog.face
	for y in 0 ..< FACE_H {
		for h in 0 ..< FACE_HALFWORDS {
			vx, vy := i32(FACE_CELL_X + h), i32(FACE_CELL_Y + y)
			if psx.vram_at(vx, vy)^ != face.texels[y][h] {
				psx.vram_put(vx, vy, face.texels[y][h])
			}
		}
	}
	for c in 0 ..< COLOURS {
		if psx.vram_at(i32(FACE_CLUT_X + c), FACE_CLUT_Y)^ != face.clut[c] {
			psx.vram_put(i32(FACE_CLUT_X + c), FACE_CLUT_Y, face.clut[c])
		}
	}
	for i in 0 ..< min(psx.lw(SPRITE_TABLE), TABLE_MAX) {
		entry := SPRITE_TABLE + 4 + i * 8
		if psx.lhu(entry) == DOG_SPRITE && psx.lhu(entry + 4) == u32(s.page) | u32(s.v) << 8 {
			slot := psx.lbu(entry + 2)
			if !sheet_holds(s, slot) {
				sheet_put(s, slot)
			}
		}
	}
}

@(private = "file")
message_text :: proc() {
	if config.field_teacher {
		stops := STOPS
		for s, i in stops {
			if u32(s.message) == psx.cpu.r[4] & 0xffff && u32(s.map_id) == psx.lhu(MAP_ID) &&
			   u32(s.section) == psx.lbu(MAP_SECTION) {
				if .Game in core.trace.active {
					core.tracef(.Game, "combo dog talks at stop %d", i)
				}
				psx.cpu.r[2] = lesson_text(s)
				return
			}
		}
	}
	teacher.message_text()
}

// The stop's lesson: the combo bits of its level, one per family, or its
// special's bit.
@(private = "file")
lesson_bits :: proc(s: Stop) -> (bits: int) {
	if s.level == 0 {
		_, _, bits = special(s.special)
		return
	}
	for family in 0 ..< 4 {
		bits |= 1 << uint(family * 4 + s.level - 1)
	}
	return
}

// Whether the party knows every combo of the stop's level.
@(private = "file")
lesson_known :: proc(s: Stop) -> bool {
	return config.battle_combos & lesson_bits(s) == lesson_bits(s)
}

// The journal's line on the dog: where he was last seen, from the lessons
// the party knows (the last town whose lesson is known), and where he went;
// then, once he has taught in a town, the first scene whose special is
// still to learn.
@(private)
teacher_journal :: proc() -> string {
	stops := STOPS
	towns: [len(stops)]Stop
	n := 0
	scene := ""
	for s in stops {
		if s.level > 0 {
			towns[n] = s
			n += 1
		} else if scene == "" && !lesson_known(s) {
			scene = s.town
		}
	}
	last := -1
	for s, i in towns[:n] {
		if lesson_known(s) {
			last = i
		}
	}
	line: string
	switch {
	case last < 0:
		return fmt.tprintf("A dog in %s is said to teach magic combos.", towns[0].town)
	case last == n - 1:
		line = fmt.tprintf("Last seen in %s. He has taught every combo he knows.", towns[last].town)
	case:
		line = fmt.tprintf("Last seen in %s. He is moving on to %s.", towns[last].town, towns[last + 1].town)
	}
	if scene != "" {
		line = fmt.tprintf("%s He roams the wilds too: try %s.", line, scene)
	}
	return line
}

// Write the dog's words at this stop and give its lesson; returns the text.
@(private = "file")
lesson_text :: proc(s: Stop) -> u32 {
	at := u32(TEXT_AT)
	put :: proc(at: ^u32, bytes: ..u8) {
		for b in bytes {
			assert(at^ < TEXT_AT + TEXT_MAX, "combo dog text too long")
			psx.sb(at^, u32(b))
			at^ += 1
		}
	}
	say :: proc(at: ^u32, text: string) {
		for i in 0 ..< len(text) {
			put(at, text[i])
		}
	}
	put(&at, FACE, s.face[0], s.face[1])
	say(&at, "\"")
	if lesson_known(s) {
		say(&at, "Arf! Keep at it.")
		put(&at, LINE)
		say(&at, "Find me again")
		put(&at, LINE)
		say(&at, "down the road.")
	} else if s.level == 0 {
		// The recipe reads "Who, after First then Second".
		name, recipe, bits := special(s.special)
		who, _, after := strings.partition(recipe, ", after ")
		first, _, second := strings.partition(after, " then ")
		say(&at, "Arf! I know a trick")
		put(&at, LINE)
		say(&at, fmt.tprintf("for %s:", who))
		put(&at, LINE)
		say(&at, fmt.tprintf("%s.", name))
		put(&at, PAGE)
		say(&at, fmt.tprintf("%s can make it", who))
		put(&at, LINE)
		say(&at, fmt.tprintf("after %s then", first))
		put(&at, LINE)
		say(&at, fmt.tprintf("%s.", second))
		combos_add(bits)
	} else {
		say(&at, "Arf! I teach magic")
		put(&at, LINE)
		say(&at, "combos to travelers.")
		put(&at, PAGE)
		say(&at, "Cast two spells in")
		put(&at, LINE)
		say(&at, "a row and they may")
		put(&at, LINE)
		say(&at, "join into one.")
		put(&at, PAGE)
		say(&at, "The second element")
		put(&at, LINE)
		say(&at, "follows the first:")
		put(&at, LINE)
		say(&at, "Fire, Wind, Water,")
		put(&at, PAGE)
		say(&at, "Earth, then Fire.")
		put(&at, LINE)
		say(&at, fmt.tprintf("Level %d spells make", s.level))
		put(&at, LINE)
		say(&at, "these combos:")
		// Two names to a page: the longest pair still fits a line each.
		for family in 0 ..< 4 {
			put(&at, PAGE if family % 2 == 0 else LINE)
			say(&at, combo_name(family * 4 + s.level - 1))
		}
		combos_add(lesson_bits(s))
	}
	say(&at, "\"")
	put(&at, END)
	return TEXT_AT
}

