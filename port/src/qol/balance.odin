// Rebalanced mode (`[battle] balance`): tougher enemies, magic worth its AP,
// less money late, and a few exploits capped.
//
// Tables: GAME.EMI's overlay 0x0e (at 0x8018d800, resident on the field and
// in battle) holds the item, skill, level-up growth and master bonus tables.
// No game table is copied into the port: the first time a region's live
// bytes hash to the vanilla FNV-1a value, they are captured and a patched
// copy is built from them by the rules below. Every vblank the overlay is
// resident, a region that still holds the copy the setting does not want is
// overwritten with the one it does (also after the overlay is read again
// from the disc), so turning the option off restores vanilla at once.
//
//   skills   attack spells 1-12 +20% power, +20% AP
//            rounded up; buffs 38-43 +2 AP;
//            debuffs/status spells costing 1-3 AP +3 AP; Heal, Rejuvenate,
//            Restore +25% AP; Purify, Remedy +2 AP
//   items    Healing Herb 30z (was 10); bombs 23-32 double power, +50% price
//   growth   HP gains x1.4; Cray +1 AP on even levels; Ershin +1 AP on
//            levels 1-30
//   masters  BALANCE_MASTER_BONUS (bigger bonuses, bigger trade-offs)
//
// Wisdom: STAT_REBUILD (a0 the character record) adds equipment to the
// after-equipment stats and caps them. Vanilla equipment never adds Wisdom;
// after it runs, staves add half their attack, robes (armor type 0x22) half
// their defence and rings a flat bonus to record + 0x48, capped at 999.
// The game rebuilds only on equipment changes and battle ends, so after the
// tables are written (setting turned on or off, or the overlay read again,
// as after loading a save) the next field tick runs RECOMPUTE for the party.
// So does a play time jump (a save loaded, a new game), since a save made
// with the option on holds the other setting's Wisdom while the tables
// themselves need no change.
//
// Enemies: ENEMY_SETUP (a0 the enemy slot 0..5, a1 the formation) copies a
// BWORLD record (0x108 bytes at ENEMY_RECORDS) into the enemy's combatant.
// After it, HP x1.5 (x2 from 10000; timed hits and the enemy AI carry the
// rest of the difficulty), EXP is cut to half the HP on enemies
// that give at least 1000 EXP and more EXP than HP (GoldGang, Gold Fly), and
// zenny past 500 is halved.
//
// Elsewhere: damage.odin caps a hit on an enemy at 9999 (the Kaiser/Cursed
// Sword/Last Resort combination hit for hundreds of thousands), and
// combo_menu.odin makes a chained spell cost the second member extra AP.
package qol

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"

import "../psx"

@(private = "file")
GAME_ID :: 0x0e

@(private = "file")
ITEMS :: 0x80199d9c // 8 bytes per item
@(private = "file")
ITEM_SIZE :: 8
@(private = "file")
ITEM_COUNT :: 119
@(private = "file")
ITEM_POWER :: 3 // u8
@(private = "file")
ITEM_PRICE :: 6 // u16, the sell price (buying costs double)
@(private = "file")
HEALING_HERB :: 1
@(private = "file")
HERB_PRICE :: 30
@(private = "file")
FIRST_BOMB :: 23 // Weather Vane
@(private = "file")
LAST_BOMB :: 32 // Taser

@(private = "file")
SKILL_SIZE :: 12
@(private = "file")
SKILL_COUNT :: 256
@(private = "file")
SKILL_POWER :: 3 // u8
@(private = "file")
SKILL_COST :: 4 // u8 AP
@(private = "file")
SKILL_KIND :: 9 // u8: 0x01 stat down, 0x08 status
@(private = "file")
KIND_DEBUFF :: 0x01 | 0x08
@(private = "file")
FIRST_ATTACK_SPELL :: 1 // Flare
@(private = "file")
LAST_ATTACK_SPELL :: 12 // Quake
@(private = "file")
FIRST_BUFF :: 38 // Might
@(private = "file")
LAST_BUFF :: 43 // Barrier
@(private = "file")
HEALS := [?]u32{44, 45, 46} // Heal, Rejuvenate, Restore
@(private = "file")
CURES := [?]u32{51, 52} // Purify, Remedy

@(private = "file")
GROWTH :: 0x8019bbf8 // 7 characters x 100 levels x 8 bytes
@(private = "file")
GROWTH_ROW :: 8
@(private = "file")
GROWTH_LEVELS :: 100
@(private = "file")
GROWTH_CHARACTERS :: 7
@(private = "file")
GROWTH_HP :: 2 // u8
@(private = "file")
GROWTH_AP :: 3 // high nibble
@(private = "file")
CRAY :: 2
@(private = "file")
ERSHIN :: 5
@(private = "file")
ERSHIN_AP_LEVELS :: 30

@(private = "file")
MASTER_TABLE :: 0x8019de28 // s8 HP, AP, Pwr, Def, Agl, Wis per master id
@(private = "file")
MASTER_IDS :: 13 // id 0 = no master

// Level-up bonus per master id - 1 in rebalanced mode (HP, AP, Pwr, Def,
// Agl, Wis): each master's lean doubled, paid for in the other stats.
@(private)
BALANCE_MASTER_BONUS := [MASTER_IDS - 1][6]i8 {
	{-6, 2, -1, 0, 0, 2},
	{16, 0, 1, 0, -1, 0},
	{40, -3, 4, 3, -3, -3},
	{-8, 3, -2, -2, 0, 6},
	{-10, 1, 0, -1, 4, 0},
	{-10, 4, 0, 0, 0, 1},
	{-4, 0, 0, 0, 3, 0},
	{20, -2, 3, 2, -1, -2},
	{-16, -2, 2, 2, 2, 2},
	{0, 2, 0, -1, 0, 2},
	{30, -5, 5, 0, 1, -4},
	{24, 4, -1, -1, -2, -1},
}

@(private = "file")
Region :: enum {
	Items,
	Skills,
	Growth,
	Masters,
}

@(private = "file")
REGION_ADDR := [Region]u32 {
	.Items   = ITEMS,
	.Skills  = SKILL_DATA,
	.Growth  = GROWTH,
	.Masters = MASTER_TABLE,
}
@(private = "file")
REGION_SIZE := [Region]u32 {
	.Items   = ITEM_COUNT * ITEM_SIZE,
	.Skills  = SKILL_COUNT * SKILL_SIZE,
	.Growth  = GROWTH_CHARACTERS * GROWTH_LEVELS * GROWTH_ROW,
	.Masters = MASTER_IDS * 6,
}
// FNV-1a (core:hash fnv32a) of each region in the USA release.
@(private = "file")
REGION_HASH := [Region]u32 {
	.Items   = 0x1d140778,
	.Skills  = 0x6241bb9d,
	.Growth  = 0x6b00e5eb,
	.Masters = 0xf47ff88c,
}
@(private = "file")
REGION_MAX :: GROWTH_CHARACTERS * GROWTH_LEVELS * GROWTH_ROW

@(private = "file")
STAT_REBUILD :: 0x80196324
@(private = "file")
RECORD_WIS :: 0x48 // u16, after equipment
@(private = "file")
RECORD_WEAPON :: 0x80 // u8 ids, 0 none
@(private = "file")
RECORD_ARMOR :: 0x81
@(private = "file")
RECORD_ACCESSORY :: 0x82
@(private = "file")
WEAPONS :: 0x8019a154 // 14 bytes per weapon
@(private = "file")
WEAPON_SIZE :: 14
@(private = "file")
WEAPON_ATTACK :: 8 // u16
@(private = "file")
ARMORS :: 0x8019a624 // 12 bytes per armor
@(private = "file")
ARMOR_SIZE :: 12
@(private = "file")
ARMOR_DEFENCE :: 6 // u16
@(private = "file")
EQUIP_TYPE :: 2 // u8, weapons and armor
@(private = "file")
TYPE_STAFF :: 0x31
@(private = "file")
TYPE_ROBE :: 0x22
@(private = "file")
WISDOM_RING :: 13
@(private = "file")
WISDOM_RING_WIS :: 25
@(private = "file")
RING_WIS :: 10
// Hawk's, Dream, Balance, the four element rings, Aura, Barrier, Diamond,
// Healing, Shaman's, Soul, Spirit and Harmonic rings.
@(private = "file")
RINGS := [?]u32{15, 19, 21, 26, 27, 28, 29, 30, 31, 35, 38, 40, 41, 42, 52}
@(private = "file")
STAT_MAX :: 999

@(private = "file")
ENEMY_SETUP :: 0x801b9b18
@(private = "file")
ENEMY_RECORDS :: 0x801f58a0
@(private = "file")
ENEMY_RECORD_SIZE :: 0x108
@(private = "file")
ENEMY_RECORD_HP :: 0x28 // u32
@(private = "file")
ENEMY_RECORD_ZENNY :: 0x10 // u16
@(private = "file")
ENEMY_RECORD_EXP :: 0x12 // u16
@(private = "file")
COMBATANT_HP_BASE :: 0xf8 // u32, setup copies the record HP here too; the battle reads COMBATANT_HP_MAX
@(private = "file")
COMBATANT_EXP :: 0xa8 // u32
@(private = "file")
COMBATANT_ZENNY :: 0x11e // u16
@(private = "file")
FORMATION_SLOT_SIZE :: 3 // byte 0 the record index
@(private = "file")
ENEMY_HP_MAX :: 9_999_999
@(private = "file")
BIG_HP :: 10_000
// HP_APPLY (0x801d8ecc) leaves a target with exactly this HP alone: the
// scripted fights (Scias in BOSS010, Ight in BOSS017, Fou-lu in BOSS032).
@(private = "file")
INVINCIBLE_HP :: 1_000_000
@(private = "file")
FARM_EXP :: 1000
@(private = "file")
ZENNY_KEEP :: 500


@(private = "file")
balance: struct {
	rebuild:   psx.Func_Proc,
	setup:     psx.Func_Proc,
	field:     psx.Func_Proc,
	// Tables written since the party's stats were last rebuilt.
	stale:     bool,
	clock:     Play_Clock, // at the last field tick
	captured:  [Region]bool,
	vanilla:   [Region][REGION_MAX]u8,
	patched:   [Region][REGION_MAX]u8,
	// Test knob BOF4_ENEMY_STATS=<hp>,<exp>,<zenny>: every enemy record is
	// given these before the setup copies it, to drive each scaling branch.
	stats:     [3]u32,
	stats_on:  bool,
}

@(private)
balance_init :: proc() -> bool {
	rebuild, rebuild_ok := psx.hook_overlay(STAT_REBUILD, SLOT_GAME, GAME_ID, stat_rebuild)
	setup, setup_ok := psx.hook_overlay(ENEMY_SETUP, SLOT_MENU, BATTLE_ID, enemy_setup)
	if !rebuild_ok || !setup_ok {
		fmt.eprintf("qol: balance function %08x / %08x not found\n", STAT_REBUILD, ENEMY_SETUP)
		return false
	}
	balance.rebuild = rebuild
	balance.setup = setup
	balance.field = hook_game_mode(MODE_FIELD, field_tick) or_return
	return stats_knob()
}

@(private = "file")
stats_knob :: proc() -> bool {
	spec := os.get_env("BOF4_ENEMY_STATS", context.temp_allocator)
	if spec == "" {
		return true
	}
	parts := strings.split(spec, ",", context.temp_allocator)
	ok := len(parts) == 3
	for i in 0 ..< min(len(parts), 3) {
		n, n_ok := strconv.parse_uint(parts[i], 10)
		ok &&= n_ok && n <= (i == 0 ? ENEMY_HP_MAX : 0xffff)
		balance.stats[i] = u32(n)
	}
	if !ok {
		fmt.eprintln("BOF4_ENEMY_STATS: expected <hp>,<exp>,<zenny> in decimal; got", spec)
		return false
	}
	balance.stats_on = true
	return true
}

@(private)
balance_vblank :: proc() {
	if psx.r32(SLOT_GAME) != GAME_ID {
		return
	}
	for region in Region {
		size := REGION_SIZE[region]
		addr := REGION_ADDR[region]
		live := psx.ram[addr & (psx.RAM_SIZE - 1):][:size]
		if !balance.captured[region] {
			if hash.fnv32a(live) != REGION_HASH[region] {
				continue
			}
			copy(balance.vanilla[region][:size], live)
			copy(balance.patched[region][:size], live)
			patch_region(region, balance.patched[region][:size])
			balance.captured[region] = true
		}
		want, other := balance.patched[region][:size], balance.vanilla[region][:size]
		if !config.battle_balance {
			want, other = other, want
		}
		if mem.compare(live, other) == 0 {
			copy(psx.mem_slice(addr, size), want)
			balance.stale = true
		}
	}
}

@(private = "file")
field_tick :: proc() {
	balance.field()
	if psx.lhu(GAME_MODE) != GAME_MODE_FIELD {
		return
	}
	if play_time_jumped(&balance.clock) {
		balance.stale = true
	}
	if !balance.stale {
		return
	}
	balance.stale = false
	regs, hi, lo := psx.cpu.r, psx.cpu.hi, psx.cpu.lo
	psx.call(RECOMPUTE)
	psx.cpu.r, psx.cpu.hi, psx.cpu.lo = regs, hi, lo
	if .Qol in psx.trace.active {
		psx.tracef(.Qol, "balance: party stats rebuilt (balance %v)", config.battle_balance)
	}
}

@(private = "file")
patch_region :: proc(region: Region, t: []u8) {
	switch region {
	case .Items:
		patch_items(t)
	case .Skills:
		patch_skills(t)
	case .Growth:
		patch_growth(t)
	case .Masters:
		for bonus, i in BALANCE_MASTER_BONUS {
			for b, s in bonus {
				t[(i + 1) * 6 + s] = u8(b)
			}
		}
	}
}

@(private = "file")
patch_items :: proc(t: []u8) {
	set_price(t[HEALING_HERB * ITEM_SIZE:], HERB_PRICE)
	for id in FIRST_BOMB ..= LAST_BOMB {
		item := t[id * ITEM_SIZE:]
		item[ITEM_POWER] = u8(min(int(item[ITEM_POWER]) * 2, 255))
		price := int(item[ITEM_PRICE]) | int(item[ITEM_PRICE + 1]) << 8
		set_price(item, min(price * 3 / 2, 0xffff))
	}
}

@(private = "file")
set_price :: proc(item: []u8, price: int) {
	item[ITEM_PRICE] = u8(price)
	item[ITEM_PRICE + 1] = u8(price >> 8)
}

@(private = "file")
patch_skills :: proc(t: []u8) {
	for id in 0 ..< u32(SKILL_COUNT) {
		skill := t[id * SKILL_SIZE:]
		cost := int(skill[SKILL_COST])
		switch {
		case id >= FIRST_ATTACK_SPELL && id <= LAST_ATTACK_SPELL:
			power := int(skill[SKILL_POWER])
			skill[SKILL_POWER] = u8(min(power + power / 5, 255))
			cost += (cost + 4) / 5 // rounded up, so 3-AP spells cost 4
		case id >= FIRST_BUFF && id <= LAST_BUFF:
			cost += 2
		case skill[SKILL_KIND] & KIND_DEBUFF != 0 && cost >= 1 && cost <= 3:
			cost += 3
		case is_one_of(id, HEALS[:]):
			cost += cost / 4
		case is_one_of(id, CURES[:]):
			cost += 2
		}
		skill[SKILL_COST] = u8(cost)
	}
}

@(private = "file")
is_one_of :: proc(id: u32, ids: []u32) -> bool {
	for x in ids {
		if x == id {
			return true
		}
	}
	return false
}

@(private = "file")
patch_growth :: proc(t: []u8) {
	for c in 0 ..< GROWTH_CHARACTERS {
		for level in 1 ..< GROWTH_LEVELS {
			row := t[(c * GROWTH_LEVELS + level) * GROWTH_ROW:]
			row[GROWTH_HP] = u8(min(int(row[GROWTH_HP]) * 7 / 5, 255))
			add := 0
			switch c {
			case CRAY:
				add = level % 2 == 0 ? 1 : 0
			case ERSHIN:
				add = level <= ERSHIN_AP_LEVELS ? 1 : 0
			}
			ap := min(int(row[GROWTH_AP] >> 4) + add, 15)
			row[GROWTH_AP] = u8(ap << 4) | row[GROWTH_AP] & 0xf
		}
	}
}

@(private = "file")
stat_rebuild :: proc() {
	record := psx.cpu.r[4]
	balance.rebuild()
	if !config.battle_balance {
		return
	}
	wis := 0
	if weapon := u32(psx.lbu(record + RECORD_WEAPON)); weapon != 0 {
		data := WEAPONS + weapon * WEAPON_SIZE
		if psx.lbu(data + EQUIP_TYPE) == TYPE_STAFF {
			wis += int(psx.lhu(data + WEAPON_ATTACK)) / 2
		}
	}
	if armor := u32(psx.lbu(record + RECORD_ARMOR)); armor != 0 {
		data := ARMORS + armor * ARMOR_SIZE
		if psx.lbu(data + EQUIP_TYPE) == TYPE_ROBE {
			wis += int(psx.lhu(data + ARMOR_DEFENCE)) / 2
		}
	}
	accessory := psx.lbu(record + RECORD_ACCESSORY)
	if accessory == WISDOM_RING {
		wis += WISDOM_RING_WIS
	}
	for ring in RINGS {
		if accessory == ring {
			wis += RING_WIS
		}
	}
	if wis > 0 {
		psx.sh(record + RECORD_WIS, u32(min(int(psx.lhu(record + RECORD_WIS)) + wis, STAT_MAX)))
	}
}

@(private = "file")
enemy_setup :: proc() {
	slot := psx.cpu.r[4] & 0xff
	formation := psx.cpu.r[5]
	index := u32(psx.lbu(formation + slot * FORMATION_SLOT_SIZE))
	record := ENEMY_RECORDS + index * ENEMY_RECORD_SIZE
	if balance.stats_on {
		psx.sw(record + ENEMY_RECORD_HP, balance.stats[0])
		psx.sh(record + ENEMY_RECORD_EXP, balance.stats[1])
		psx.sh(record + ENEMY_RECORD_ZENNY, balance.stats[2])
	}
	balance.setup()
	if !config.battle_balance {
		return
	}
	who := enemy_combatant(slot)
	hp := psx.lw(record + ENEMY_RECORD_HP)
	if hp > 1 && hp != INVINCIBLE_HP {
		scaled := hp >= BIG_HP ? u64(hp) * 2 : u64(hp) * 3 / 2
		hp_max := u32(min(scaled, ENEMY_HP_MAX))
		psx.sw(who + COMBATANT_HP, hp_max)
		psx.sw(who + COMBATANT_HP_MAX, hp_max)
		psx.sw(who + COMBATANT_HP_BASE, hp_max)
	}
	exp := u32(psx.lhu(record + ENEMY_RECORD_EXP))
	if exp >= FARM_EXP && exp > hp {
		psx.sw(who + COMBATANT_EXP, hp / 2)
	}
	zenny := u32(psx.lhu(who + COMBATANT_ZENNY))
	if zenny > ZENNY_KEEP {
		psx.sh(who + COMBATANT_ZENNY, ZENNY_KEEP + (zenny - ZENNY_KEEP) / 2)
	}
	if .Qol in psx.trace.active {
		psx.tracef(.Qol, "balance: enemy %d record %d hp %d -> %d exp %d zenny %d", slot, index, hp, psx.lw(who + COMBATANT_HP_MAX), psx.lw(who + COMBATANT_EXP), psx.lhu(who + COMBATANT_ZENNY))
	}
}
