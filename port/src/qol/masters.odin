// Master tracker: how far each master's requirements are met.
//
// Each of the 12 masters teaches a skill (Gyosil gives an item) once a
// counter in the save data reaches the next threshold of its table, when an
// apprentice visits. The game never shows these counters. The tracker reads
// them from RAM and lists every master on a panel drawn in the game's own
// window and font, with the party members apprenticed to it, and shows a
// notice when an apprentice's master has a new reward ready. The panel: a
// list of the masters on the left, those met first, and the chosen one in a
// box on the right: portrait (master_faces.odin), pupil, what it counts, every
// reward and what it needs, and what it adds to every level-up gain (the game
// shows that only for the master already chosen). A master not met yet is
// "???". The camp menu's Masters command (camp_menu.odin) shows the panel. Up and Down choose a master; Cross,
// Circle or Triangle hide it. The game sees no buttons while the panel is up.
//
// Character records (7, stride 0x98 from CHAR_RECORDS) hold the current
// master at +0x84; the party is a list of record indices. The tables below
// come from each master's predicate in its area overlay (it returns
// counter >= table[next reward]).
//
// A bit per master id is set once the party has met the master: the visit
// dispatcher (0x800f8a30) tests it to choose the first meeting's talk over a
// return visit's, and sets it when the first talk ends (0x800f8bc0).
//
// A byte per master holds the index of its next reward (0xff once all are
// given). On a visit the game first skips rewards that are skills the party
// already knows, so the tracker does the same with the known-skill bit set.
//
// A play time jump (a save loaded, a new game) takes the state as it is,
// without notices.
package qol

import "core:fmt"
import "core:math/bits"

import sdl "vendor:sdl2"

import cpu "ps:psx/cpu"
import host "ps:psx/host"
import render "ps:psx/render"

import "ps:core"

@(private = "file")
CHAR_NAME_LEN :: 8
@(private = "file")
CHAR_MASTER :: 0x84 // u8 master id, 0 = none
// Bit set per master id (byte id / 8, bit id % 8): met.
@(private = "file")
MET :: CHAR_RECORDS + 0xd54
// u8 per master id: index of the next reward, 0xff = all given.
@(private = "file")
PROGRESS :: CHAR_RECORDS + 0xd55
@(private = "file")
PROGRESS_DONE :: 0xff
// Bit (skill - SKILL_FIRST) set = the party knows the skill.
@(private = "file")
SKILL_BITS :: 0x8011b5c8
@(private = "file")
SKILL_FIRST :: 84

// Counters. Fishing points: 30 u16 per fish kind. Species: bit set of 8 u32.
// Faeries: 20 records whose byte at +0 is nonzero. Inventory: 4 lists of 128
// (item, count) byte pairs, a slot filled when both are nonzero.
@(private = "file")
MAX_COMBO_DAMAGE :: 0x8011b734 // u32
@(private = "file")
MAX_HIT_DAMAGE :: 0x8011b760 // u32
@(private = "file")
MAX_COMBO_HITS :: 0x8011b694 // u8
@(private = "file")
ENCOUNTERS :: 0x8011b67c // u32
@(private = "file")
BALL_RANK :: 0x8011b6e4 // u8, 5 = Tin, 10 = Platinum
@(private = "file")
RYU_LEVEL :: 0x8011a956 // u16
@(private = "file")
FISH_POINTS :: 0x8011b95c
@(private = "file")
FISH_KINDS :: 30
@(private = "file")
SPECIES :: 0x8011b61c
@(private = "file")
SPECIES_WORDS :: 8
@(private = "file")
FAERIES :: CHAR_RECORDS + 0x10b0
@(private = "file")
FAERIE_COUNT :: 20
@(private = "file")
FAERIE_STRIDE :: 0x28
@(private = "file")
INVENTORY :: 0x8011ad98
@(private = "file")
INVENTORY_LISTS :: 4
@(private = "file")
INVENTORY_SLOTS :: 128

// Ready notices on screen at once, and the real time each stays there.
@(private = "file")
TOASTS :: 3
@(private = "file")
TOAST_MS :: 6000

// Emulated vblanks between reads of the counters.
@(private = "file")
MASTERS_PERIOD :: 15

@(private = "file")
MAX_TIERS :: 4

@(private = "file")
Counter :: enum u8 {
	Combo_Hits,
	Hours,
	Encounters,
	Species,
	Faeries,
	Fish_Points,
	Inventory,
	Combo_Damage,
	Ryu_Level,
	Ball_Rank,
	Hit_Damage,
}

// What each counter is, as the box names it (at most 16 characters).
@(private = "file")
COUNTER_NAMES := [Counter]string {
	.Combo_Hits   = "best combo hits",
	.Hours        = "hours played",
	.Encounters   = "battles fought",
	.Species      = "enemy species",
	.Faeries      = "faeries",
	.Fish_Points  = "fishing points",
	.Inventory    = "kinds of items",
	.Combo_Damage = "best combo dmg",
	.Ryu_Level    = "Ryu's level",
	.Ball_Rank    = "ball rank",
	.Hit_Damage   = "best hit dmg",
}

@(private = "file")
Master :: struct {
	name:    string,
	counter: Counter,
	tiers:   int,
	need:    [MAX_TIERS]u32,
	reward:  [MAX_TIERS]string,
	skill:   [MAX_TIERS]u8, // skill id of each reward, 0 = an item
}

// Indexed by master id - 1. Skill ids are from the reward table at
// 0x800f9684 that the visit dispatcher reads.
@(private = "file")
MASTERS := [?]Master {
	{"Rwolf", .Combo_Hits, 4, {5, 10, 15, 20}, {"Eddy", "Plateau", "Magic Ball", "Flame Pillar"}, {153, 155, 89, 159}},
	{"Momo", .Hours, 4, {25, 30, 40, 50}, {"Spray", "Clip", "Oracle", "Egghead"}, {128, 129, 127, 141}},
	{"Kryrik", .Combo_Hits, 4, {30, 40, 50, 70}, {"Megaphone", "SpiritBlast", "Cleave", "Disembowel"}, {92, 130, 131, 87}},
	{"Abbess", .Species, 3, {70, 85, 100, 0}, {"Concentrate", "Sanctuary", "Celerity", ""}, {105, 113, 110, 0}},
	{"Njomo", .Faeries, 4, {8, 12, 16, 20}, {"FaerieAttack", "FaerieBreath", "War Shout", "FaerieCharge"}, {147, 145, 146, 148}},
	{"Gyosil", .Fish_Points, 3, {4000, 6000, 9500, 0}, {"Ring of Ice", "Spanner", "Master's Rod", ""}, {0, 0, 0, 0}},
	{"Stoll", .Inventory, 2, {80, 120, 0, 0}, {"Steal", "Coward's Way", "", ""}, {120, 139, 0, 0}},
	{"Una", .Combo_Damage, 3, {1500, 3000, 10000, 0}, {"Pilfer", "Super Combo", "Blitz", ""}, {121, 88, 90, 0}},
	{"Bunyan", .Hit_Damage, 4, {3000, 5000, 8000, 12000}, {"Backhand", "Counter", "Shadowwalk", "Final Hope"}, {137, 107, 86, 111}},
	{"Lyta", .Ryu_Level, 4, {20, 25, 30, 35}, {"Supplication", "Holy Strike", "Resist", "Benediction"}, {108, 136, 106, 119}},
	{"Khan", .Encounters, 4, {300, 400, 500, 600}, {"Focus", "Shout", "Tiger Fist", "Flex"}, {104, 112, 157, 158}},
	{"Marlok", .Ball_Rank, 3, {6, 8, 10, 0}, {"Charm", "Monopolize", "Roulette", ""}, {123, 122, 150, 0}},
}

@(private = "file")
MASTER_COUNT :: len(MASTERS)

@(private = "file")
STATS :: 6 // HP, AP, Pwr, Def, Agl, Wis

// Added to each level-up gain of an apprentice, indexed by master id - 1:
// GAME.EMI's s8 table at 0x8019de28 (6 bytes per id, id 0 = no master), the
// numbers the Status screen shows as arrows.
@(private = "file")
MASTER_BONUS := [MASTER_COUNT][STATS]i8 {
	{0, 1, -1, 0, 0, 1},
	{8, 0, 0, 0, 0, 0},
	{25, -2, 3, 2, -2, -2},
	{0, 2, -2, -2, 0, 4},
	{-8, 1, 0, 0, 2, 0},
	{-8, 2, 0, 0, 0, 0},
	{0, 0, 0, 0, 1, 0},
	{12, -2, 2, 1, 0, -1},
	{-16, -3, 1, 1, 1, 1},
	{0, 1, 0, -1, 0, 1},
	{20, -4, 3, 0, 1, -3},
	{16, 3, -1, -1, -1, -1},
}

@(private = "file")
TOAST_BYTES :: 64

@(private = "file")
masters: struct {
	// Reward index ready per master at the last read, -1 if none.
	ready:     [MASTER_COUNT]int,
	clock:     Play_Clock, // at the last read
	next_read: u64, // vblank of the next read
	// At the last read, for the panel.
	value:     [MASTER_COUNT]u32,
	next:      [MASTER_COUNT]int,
	pupils:    [MASTER_COUNT]string,
	selected:  int, // master index chosen in the list
	toasts:    [TOASTS]Toast,
	toast_count: int,
}

@(private = "file")
Toast :: struct {
	text:    [TOAST_BYTES]u8,
	len:     int,
	expires: u32, // SDL ticks
}

@(private)
masters_init :: proc() {
	#assert(len(MASTER_FACES) == MASTER_COUNT)
	// The journal and combos pages are always there; the masters page with
	// the tracker.
	host.osd_panel_pages = config.masters_tracker ? PANEL_MASTERS + 1 : PANEL_COMBOS + 1
}

// Whether the masters draw in the game's picture (menu_draw.odin).
@(private)
masters_draws :: proc() -> bool {
	return masters_active()
}

// Whether masters_vblank has anything to do.
@(private)
masters_active :: proc() -> bool {
	return config.masters_tracker || config.masters_alerts
}

@(private)
masters_vblank :: proc(pressed: u16) {
	if config.masters_tracker && host.osd_panel_shown && host.osd_panel_page == PANEL_MASTERS {
		masters_select(pressed)
	}
	now := cpu.vblanks()
	if now < masters.next_read {
		return
	}
	masters.next_read = now + MASTERS_PERIOD
	rebase := play_time_jumped(&masters.clock)
	pupils := masters_pupils()
	masters.pupils = pupils
	for m, i in MASTERS {
		value := counter_read(m.counter)
		next := master_next(i, m)
		ready := next < m.tiers && value >= m.need[next] ? next : -1
		was := masters.ready[i]
		masters.ready[i] = ready
		if config.masters_alerts && !rebase && ready >= 0 && ready != was && pupils[i] != "" {
			masters_alert(m, ready, pupils[i])
		}
		masters.value[i], masters.next[i] = value, next
	}
}

// Up and Down move the choice through the list's order.
@(private = "file")
masters_select :: proc(pressed: u16) {
	step := 0
	if pressed & host.PAD_UP != 0 {
		step -= 1
	}
	if pressed & host.PAD_DOWN != 0 {
		step += 1
	}
	if step == 0 {
		return
	}
	order, _ := masters_order()
	for m, row in order {
		if m == masters.selected {
			masters.selected = order[(row + step) %% MASTER_COUNT]
			return
		}
	}
}

// Whether the party has met master i. A master with a pupil has been met
// even if the bit says otherwise.
@(private = "file")
master_met :: proc(i: int) -> bool {
	id := u32(i + 1)
	return cpu.lbu(MET + id / 8) >> (id % 8) & 1 != 0 || masters.pupils[i] != ""
}

// The master's name, or "???" before the party has met it.
@(private = "file")
master_label :: proc(i: int) -> string {
	return master_met(i) ? MASTERS[i].name : "???"
}

// Master indices in list order: those met first, each group by id.
@(private = "file")
masters_order :: proc() -> (order: [MASTER_COUNT]int, met: int) {
	for i in 0 ..< MASTER_COUNT {
		if master_met(i) {
			order[met] = i
			met += 1
		}
	}
	rest := met
	for i in 0 ..< MASTER_COUNT {
		if !master_met(i) {
			order[rest] = i
			rest += 1
		}
	}
	return order, met
}

// Index of the master's next reward the party lacks (tiers once all are
// given): the progress byte, past skills the party already knows.
@(private = "file")
master_next :: proc(i: int, m: Master) -> int {
	progress := cpu.lbu(PROGRESS + u32(i + 1))
	if progress == PROGRESS_DONE {
		return m.tiers
	}
	next := min(int(progress), m.tiers)
	for next < m.tiers && m.skill[next] != 0 && skill_known(m.skill[next]) {
		next += 1
	}
	return next
}

@(private)
skill_known :: proc(skill: u8) -> bool {
	if skill < SKILL_FIRST {
		return false
	}
	bit := u32(skill - SKILL_FIRST)
	return cpu.lbu(SKILL_BITS + bit >> 3) & (1 << (bit & 7)) != 0
}

@(private = "file")
masters_alert :: proc(m: Master, ready: int, pupil: string) {
	if masters.toast_count == TOASTS {
		copy(masters.toasts[:], masters.toasts[1:])
		masters.toast_count -= 1
	}
	t := &masters.toasts[masters.toast_count]
	t.len = len(fmt.bprintf(t.text[:], "%s has %s for %s", m.name, m.reward[ready], pupil))
	t.expires = sdl.GetTicks() + TOAST_MS
	masters.toast_count += 1
	if .Game in core.trace.active {
		core.tracef(.Game, "masters toast: %s", string(t.text[:t.len]))
	}
}

// Name of a party member apprenticed to each master ("" if none). Names are
// slices of game RAM, valid until the next read.
@(private = "file")
masters_pupils :: proc() -> (pupils: [MASTER_COUNT]string) {
	for slot in 0 ..< PARTY_SLOT_COUNT {
		index := cpu.lbu(PARTY_SLOTS + u32(slot))
		if index >= CHAR_COUNT {
			continue
		}
		record := char_record(index)
		id := cpu.lbu(record + CHAR_MASTER)
		if id == 0 || id > MASTER_COUNT || pupils[id - 1] != "" {
			continue
		}
		pupils[id - 1] = char_name(record)
	}
	return
}

@(private = "file")
char_name :: proc(record: u32) -> string {
	n := 0
	for n < CHAR_NAME_LEN && cpu.lbu(record + u32(n)) != 0 {
		n += 1
	}
	at := record & (cpu.RAM_SIZE - 1)
	return string(cpu.ram[at:at + u32(n)])
}

@(private = "file")
counter_read :: proc(c: Counter) -> (v: u32) {
	switch c {
	case .Combo_Hits:
		v = cpu.lbu(MAX_COMBO_HITS)
	case .Hours:
		v = cpu.lw(PLAY_HOURS)
	case .Encounters:
		v = cpu.lw(ENCOUNTERS)
	case .Combo_Damage:
		v = cpu.lw(MAX_COMBO_DAMAGE)
	case .Hit_Damage:
		v = cpu.lw(MAX_HIT_DAMAGE)
	case .Ryu_Level:
		v = cpu.lhu(RYU_LEVEL)
	case .Ball_Rank:
		v = cpu.lbu(BALL_RANK)
	case .Fish_Points:
		for k in 0 ..< u32(FISH_KINDS) {
			v += cpu.lhu(FISH_POINTS + k * 2)
		}
	case .Species:
		for k in 0 ..< u32(SPECIES_WORDS) {
			v += u32(bits.count_ones(cpu.lw(SPECIES + k * 4)))
		}
	case .Faeries:
		for k in 0 ..< u32(FAERIE_COUNT) {
			v += cpu.lbu(FAERIES + k * FAERIE_STRIDE) != 0 ? 1 : 0
		}
	case .Inventory:
		v = inventory_filled()
	}
	return
}

@(private = "file")
inventory_filled :: proc() -> (n: u32) {
	for list in 0 ..< u32(INVENTORY_LISTS) {
		for slot in 0 ..< u32(INVENTORY_SLOTS) {
			at := INVENTORY + list * 0x200 + slot * 2
			if cpu.lbu(at) != 0 && cpu.lbu(at + 1) != 0 {
				n += 1
			}
		}
	}
	return
}

// Panel layout, in the game's 320x240 screen space, inside PANEL.
@(private = "file")
COL_NAME :: 12
@(private = "file")
COL_STAT_STEP :: 28
@(private = "file")
ROW_HEAD :: 16
@(private = "file")
ROW_FOOT :: 34 + (MASTER_COUNT + 1) * MENU_LINE_H // under the list's last line
@(private = "file")
TOAST_H :: 24
// The panel: the list in a window on the left, the chosen master in a
// box filling the rest of the panel, its portrait top left, facts beside it,
// rewards and bonus below.
@(private = "file")
LIST :: [4]int{PANEL.x, PANEL.y, 68, PANEL.w} // x, y, width, height
@(private = "file")
BOX :: [4]int{LIST.x + LIST.z + 4, PANEL.y, PANEL.x + PANEL.z - (LIST.x + LIST.z + 4), PANEL.w}
@(private = "file")
COL_BOX :: BOX.x + 8
@(private = "file")
COL_BOX_END :: BOX.x + BOX.z - 8
@(private = "file")
FACE_AT :: [2]int{COL_BOX, ROW_HEAD}
@(private = "file")
COL_FACT :: COL_BOX + FACE_W + 8
@(private = "file")
COL_FACT_VALUE :: COL_FACT + 56
@(private = "file")
ROW_REWARDS :: ROW_HEAD + FACE_H + 18
@(private = "file")
COL_NEED_END :: COL_BOX + 40
@(private = "file")
COL_REWARD :: COL_NEED_END + 10
@(private = "file")
ROW_BONUS :: ROW_REWARDS + (MAX_TIERS + 2) * MENU_LINE_H
@(private = "file")
COL_BOX_STAT_END :: COL_BOX + 24 // first stat, right-aligned

// Frame end: the panel, or the notices, drawn with the game's window and font.
@(private)
masters_draw :: proc() {
	masters_toasts_expire()
	if host.osd_panel_shown && host.osd_panel_page == PANEL_MASTERS && config.masters_tracker {
		masters_draw_masters()
		// The panel shows a ready reward in green; notices would cover it.
		return
	}
	master_face_release()
	if host.osd_panel_shown {
		return // another page; notices would cover it
	}
	y := PANEL.y + PANEL.w - masters.toast_count * TOAST_H
	for i in 0 ..< masters.toast_count {
		text := string(masters.toasts[i].text[:masters.toasts[i].len])
		w := min(menu_text_width(text) + 16, PANEL.z)
		menu_window(PANEL.x, y, w, TOAST_H)
		menu_text(PANEL.x + 8, y + 6, text)
		y += TOAST_H
	}
}

@(private = "file")
masters_toasts_expire :: proc() {
	now := sdl.GetTicks()
	kept := 0
	for i in 0 ..< masters.toast_count {
		if i32(masters.toasts[i].expires - now) > 0 {
			masters.toasts[kept] = masters.toasts[i]
			kept += 1
		}
	}
	masters.toast_count = kept
}

// The stat heads as the Status screen draws them. Pwr, Def, Agl and Wis are
// 12x12 icons in the font's texture page, always in VRAM. HP and AP are 16x8
// labels in the menu sheet (texture page 13), which battles replace; while
// it is not there they are text.
@(private = "file")
STAT_ICON :: [4]int{0, 232, 12, 12} // u of Pwr (12 per stat), v, w, h
@(private = "file")
STAT_ICON_PAGE :: 15 // VRAM (960, 0)
@(private = "file")
STAT_ICON_CLUT :: [2]int{192, 240}
@(private = "file")
STAT_LABEL :: [4]int{80, 16, 16, 8} // u of HP (16 per stat), v, w, h
@(private = "file")
STAT_LABEL_PAGE :: 13 // VRAM (832, 0)
@(private = "file")
STAT_LABEL_CLUT :: [2]int{112, 241}
@(private = "file")
STAT_LABELS :: 2
// FNV-1a of the labels' texels and CLUT (halfwords, the mask bit cleared)
// as the game loads them.
@(private = "file")
STAT_LABELS_HASH :: 0xb4a0ef2e

@(private = "file")
bonus_heads :: proc(x0, y: int) {
	HEADS :: [STATS]string{"HP", "AP", "Pwr", "Def", "Agl", "Wis"}
	labels := stat_labels_loaded()
	for head, s in HEADS {
		x := x0 + s * COL_STAT_STEP
		switch {
		case s >= STAT_LABELS:
			icon, clut := STAT_ICON, STAT_ICON_CLUT
			u := icon.x + (s - STAT_LABELS) * icon.z
			menu_sprite(x - icon.z, y, icon.z, icon.w, u, icon.y, STAT_ICON_PAGE, clut.x, clut.y)
		case labels:
			label, clut := STAT_LABEL, STAT_LABEL_CLUT
			menu_sprite(x - label.z, y + 2, label.z, label.w, label.x + s * label.z, label.y, STAT_LABEL_PAGE, clut.x, clut.y)
		case:
			menu_text_right(x, y, head)
		}
	}
}

@(private = "file")
stat_labels_loaded :: proc() -> bool {
	label, clut := STAT_LABEL, STAT_LABEL_CLUT
	h := u32(0x811c9dc5)
	add :: proc(h: ^u32, v: u16) {
		for b in ([2]u16{v & 0xff, (v >> 8) & 0x7f}) {
			h^ = (h^ ~ u32(b)) * 0x01000193
		}
	}
	x0 := STAT_LABEL_PAGE * 64 + label.x / 4
	for y in label.y ..< label.y + label.w {
		for x in x0 ..< x0 + STAT_LABELS * label.z / 4 {
			add(&h, render.vram_at(i32(x), i32(y))^)
		}
	}
	for c in 0 ..< 16 {
		add(&h, render.vram_at(i32(clut.x + c), i32(clut.y))^)
	}
	return h == STAT_LABELS_HASH
}

// Master i's level-up bonus, one stat per column.
@(private = "file")
bonus_cells :: proc(i, x0, y: int) {
	bonus := config.battle_balance ? BALANCE_MASTER_BONUS[i] : MASTER_BONUS[i]
	for b, s in bonus {
		buf: [4]u8
		x := x0 + s * COL_STAT_STEP
		switch {
		case b > 0:
			menu_text_right(x, y, fmt.bprintf(buf[:], "+%d", b), MENU_GREEN)
		case b < 0:
			menu_text_right(x, y, fmt.bprint(buf[:], b), MENU_RED)
		case:
			menu_text_right(x, y, "-", MENU_GREY)
		}
	}
}

// The panel: the list, the chosen master highlighted, and its box.
@(private = "file")
masters_draw_masters :: proc() {
	list, box := LIST, BOX
	menu_window(list.x, list.y, list.z, list.w)
	menu_window(box.x, box.y, box.z, box.w)
	order, _ := masters_order()
	for i, row in order {
		colour := i == masters.selected ? MENU_YELLOW : MENU_WHITE
		if !master_met(i) && i != masters.selected {
			colour = MENU_GREY
		}
		menu_text(COL_NAME, ROW_HEAD + row * MENU_LINE_H, master_label(i), colour)
	}
	menu_text(COL_NAME, ROW_FOOT, "Up/Down", MENU_GREY)
	if !master_met(masters.selected) {
		master_face_release()
		menu_text(COL_BOX, ROW_HEAD, "???", MENU_YELLOW)
		menu_text(COL_BOX, ROW_HEAD + MENU_LINE_H, "Not met yet.", MENU_GREY)
		return
	}
	masters_draw_master(masters.selected)
}

// Master i's box: portrait, pupil, counter, each reward with what it needs
// (given ones grey, met ones green; the rest have no status, as Have shows
// how far off they are) and the level-up bonus.
@(private = "file")
masters_draw_master :: proc(i: int) {
	m := MASTERS[i]
	value, next := masters.value[i], masters.next[i]
	buf: [24]u8
	master_face_draw(i, FACE_AT.x, FACE_AT.y)
	menu_text(COL_FACT, ROW_HEAD, m.name, MENU_YELLOW)
	menu_text(COL_FACT, ROW_HEAD + MENU_LINE_H, "Pupil")
	pupil := masters.pupils[i]
	menu_text(COL_FACT_VALUE, ROW_HEAD + MENU_LINE_H, pupil == "" ? "none" : pupil, pupil == "" ? MENU_GREY : MENU_WHITE)
	menu_text(COL_FACT, ROW_HEAD + 2 * MENU_LINE_H, "Counts")
	menu_text(COL_FACT_VALUE, ROW_HEAD + 2 * MENU_LINE_H, COUNTER_NAMES[m.counter])
	menu_text(COL_FACT, ROW_HEAD + 3 * MENU_LINE_H, "Have")
	menu_text(COL_FACT_VALUE, ROW_HEAD + 3 * MENU_LINE_H, fmt.bprint(buf[:], value))
	menu_text_right(COL_NEED_END, ROW_REWARDS, "Need")
	menu_text(COL_REWARD, ROW_REWARDS, "Reward")
	for t in 0 ..< m.tiers {
		y := ROW_REWARDS + (t + 1) * MENU_LINE_H
		colour, status := MENU_WHITE, ""
		switch {
		case t < next:
			colour, status = MENU_GREY, "given"
		case value >= m.need[t]:
			colour, status = MENU_GREEN, t == next ? "ready" : "met"
		}
		need: [12]u8
		menu_text_right(COL_NEED_END, y, fmt.bprint(need[:], m.need[t]), colour)
		menu_text(COL_REWARD, y, m.reward[t], colour)
		menu_text_right(COL_BOX_END, y, status, colour)
	}
	menu_text(COL_BOX, ROW_BONUS, "Level-up bonus")
	bonus_heads(COL_BOX_STAT_END, ROW_BONUS + MENU_LINE_H)
	bonus_cells(i, COL_BOX_STAT_END, ROW_BONUS + 2 * MENU_LINE_H)
}
