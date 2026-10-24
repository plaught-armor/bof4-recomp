// The Combo command (not a game feature): the magic combos the party can
// make this round, each picked like a spell from the Magic page of a
// member's Special list (Select at the command menu opens them as a list
// too); picking one sets both members' spells at once.
//
// The combos sit in the empty slots after the member's spells, where the
// game's cursor already goes (and its Confirm does nothing); they are drawn
// over them, and Confirm on one (LIST_STEP) does what the game's does on a
// spell: the member's own spell of the combo goes into its record and the
// game's target choice and commit follow. Once that commit lands the
// partner's spell is set, aimed at the same enemy.
//
// A combo needs two members casting in a row, the second spell's element
// following the first's (docs/battle.md, "Magic combos"). The list holds
// each pair with the current member in it, the first one acting before the
// second by the round's order (higher Agl first, BTLMOVE's 801b0504), the
// first spell the cheapest affordable one of its element and the second
// any affordable spell of the next element. Combos not yet seen (the
// config's [battle] combos) are listed too, named "???", so a combo can be
// found on purpose from the pair of spells instead of by chance. A partner that already chose an
// attack, guard or spell gets the second (or first) spell in its action
// record; one still to choose has its input made for it when its turn comes,
// through the game's own magic commit (801d0b00), so AP, cursors and the
// committed list stay the game's. When the round's order comes out, the
// second member is moved right behind the first (enemies acting between
// them would break the chain), so the combo's own roll decides.
//
// Training: each combo performed counts toward its mastery ([battle]
// combo_uses), five levels at 1, 3, 6, 10 and 15 uses; with combo_mastery
// each level adds 5 to the chain chance (801b25a8, rewritten here) and the
// fifth makes the chain sure. A combo never performed chains for sure too,
// so the first try works even when the combo dog taught it beforehand.
package qol

import "core:fmt"
import "core:strconv"
import "core:strings"

import "../psx"

@(private = "file")
COMMAND_ID :: 0x33 // BTLCOMD.EMI
@(private = "file")
ROUND_ID :: 0x32 // the battle overlay
@(private = "file")
MAIN_MENU :: 0x801ccc90 // the command menu's step, a0 = BATTLE_STATE
@(private = "file")
COMMAND_DRAW :: 0x801c49ec // the command menu's main page, in ROUND_ID
@(private = "file")
SPELL_INIT :: 0x801cfa20 // the Magic command's first step
@(private = "file")
TURN_ORDER :: 0x801b0504 // the round's order, once per round
@(private = "file")
CHAIN_ROLL :: 0x801b25a8 // a0 = earlier caster, a1 = the one chaining on; v0 = 1 chains
@(private = "file")
CHAIN :: 0x801b222c // v0 = 1 when the next turn chains onto the current one

@(private = "file")
INPUT_PHASE :: 0 // 1 while the party chooses
@(private = "file")
INPUT_STEP :: 1
@(private = "file")
INPUT_MENU :: 2 // 2 the command menu, 4 a command chosen
@(private = "file")
INPUT_SUB :: 3 // the chosen command's step
@(private = "file")
INPUT_SUBSTEP :: 4
@(private = "file")
INPUT_MODE :: 6
@(private = "file")
INPUT_COMMITTED :: 7 // members done choosing
@(private = "file")
INPUT_ACTOR :: 14 // signed
@(private = "file")
INPUT_COMMAND :: 15 // the command cursor, 1 Magic
@(private = "file")
INPUT_FLAGS :: 16 // u16
@(private = "file")
INPUT_ORDER :: 31 // the member of each committed slot
@(private = "file")
INPUT_CURSORS :: 36 // u16 per character: the spell cursor kept
@(private = "file")
MENU_STEP :: 2
@(private = "file")
MENU_CHOSEN :: 4
@(private = "file")
MODE_MENU :: 1
@(private = "file")
MODE_SPELL :: 4
@(private = "file")
FLAG_MENU :: 0x200
@(private = "file")
COMMAND_MAGIC :: 1
@(private = "file")
SUB_COMMIT :: 7
@(private = "file")
MENU_BUSY :: 0x8011dd88 // nonzero while the menu waits
// The spell window; bytes 12..14 hold the cursor the commit keeps.
@(private = "file")
SPELL_WINDOW :: 0x8011dddc
@(private = "file")
ACTION_PTR :: 0x8011e02c // the choosing member's action record

// Round order: combatant per turn, party 0..5, enemies 6 on.
@(private = "file")
ORDER :: 0x8011dfa4
@(private = "file")
ORDER_POS :: 0x8011df32 // the current turn
@(private = "file")
ORDER_COUNT :: 0x8011df33
@(private = "file")
BATTLE_KIND :: 0x8011df50 // 0 gives the chain 85, not 75; 2 opens level 4

@(private = "file")
PARTY_COUNT :: 3
@(private = "file")
ENEMY_COUNT :: 6
@(private = "file")
FIRST_ENEMY :: 6
@(private = "file")
C_FLAGS :: 0x0 // bit 0 present
@(private = "file")
C_NAME :: 0x9c // 8 bytes, NUL-padded
@(private = "file")
C_NAME_LEN :: 8
@(private = "file")
C_CHAR :: 0xa4
@(private = "file")
C_AP :: 0xb4 // u16
@(private = "file")
C_SKILLS :: 0xba // skill ids
@(private = "file")
C_SKILL_COUNT :: 16
@(private = "file")
C_STATE :: 0xae // u16, 0x8000 down
@(private = "file")
C_DOWN :: 0x8000
@(private = "file")
C_AGL :: 0xe2 // u16
@(private = "file")
C_CHAIN :: 286 // CHAIN_TRAIT adds 10 to the chain
@(private = "file")
CHAIN_TRAIT :: 52
@(private = "file")
C_TARGET :: 312 // action record: target, type, skill (u16)
@(private = "file")
C_TYPE :: 313
@(private = "file")
C_SKILL :: 314
@(private = "file")
TYPE_ATTACK :: 1
@(private = "file")
TYPE_GUARD :: 2
@(private = "file")
TYPE_MAGIC :: 4
@(private = "file")
REC_TARGET :: 4 // the same fields from ACTION_PTR
@(private = "file")
REC_SKILL :: 6

@(private = "file")
SKILL_DATA_SIZE :: 12
@(private = "file")
SKILL_TARGETS :: 0 // byte
@(private = "file")
SKILL_AP :: 4
@(private = "file")
SKILL_ELEMENTS :: 8 // u16
@(private = "file")
ELEMENT_COUNT :: 4 // fire, wind, water, earth
// Targets byte: one enemy (0x60, bit 0 clear), or a group (bit 0 with
// bits 1..3 picking the target mask, no 0x40).
@(private = "file")
TARGETS_ONE :: 0x60
@(private = "file")
TARGETS_GROUP :: 0x01
@(private = "file")
SKILL_NAME_MAX :: 16

@(private = "file")
FIRST_COMBO :: 13
@(private = "file")
COMBO_COUNT :: 16
@(private = "file")
MASTERY_USES :: [5]int{1, 3, 6, 10, 15}
@(private = "file")
MASTERY_MAX :: len(MASTERY_USES)
@(private)
COMBO_USES_MAX :: 15
@(private = "file")
MASTERY_STEP :: 5
@(private = "file")
ROLL :: 100

// The Special list's step (a0 = BATTLE_STATE): reads the cursor and Confirm.
@(private = "file")
LIST_STEP :: 0x801cfcd8
@(private = "file")
STEP_LIST :: 3 // INPUT_STEP and INPUT_SUB while the list waits
@(private = "file")
SUB_LIST :: 1
// SPELL_WINDOW: +0 and +3 set while up, +8 x, +10 y (s16), +12 page
// (0 Magic), +13 the first slot shown, +14 the cursor's row of the six
// shown, 16 apart. A picked spell slides the window right to WINDOW_GONE,
// off screen, and the game clears +0 and +3 by the next command menu.
@(private = "file")
WINDOW_UP :: 0
@(private = "file")
WINDOW_ACTIVE :: 3
@(private = "file")
WINDOW_X :: 8
@(private = "file")
WINDOW_GONE :: 336
@(private = "file")
WINDOW_Y :: 10
@(private = "file")
WINDOW_PAGE :: 12
@(private = "file")
WINDOW_TOP :: 13
@(private = "file")
WINDOW_ROW :: 14
@(private = "file")
WINDOW_ROWS :: 6
@(private = "file")
SLOT_H :: 16
@(private = "file")
SLOT_X :: 18 // the names' x from the window's
// The game's skill icon (a0 x, a1 y, a2 skill), picked by the skill's
// element bits: two or more draw the many-element orb, as combo spells do.
@(private = "file")
SKILL_ICON :: 0x801953e4
@(private = "file")
SLOT_ICON_X :: 5 // the icons' x from the window's
@(private = "file")
SLOT_Y :: 6
@(private = "file")
SLOT_AP_X :: 126 // the AP cost's right edge from the window's x
// The help window's second line, clear of the enemy box over the first.
@(private = "file")
HELP_X :: 22
@(private = "file")
HELP_Y :: 40
@(private = "file")
HELP_RIGHT :: 292 // clear of the window's corner piece at 299
// The list step's Confirm on a spell: the cursor saved for the target
// step's way back, and its next substep, which slides the window away.
@(private = "file")
LIST_CURSOR :: 0x801d5c74
@(private = "file")
SUB_LIST_PICKED :: 1

@(private = "file")
OPTIONS_MAX :: 32
@(private = "file")
BOX_X :: 24
@(private = "file")
BOX_Y :: 24
@(private = "file")
BOX_W :: 272
@(private = "file")
BOX_PAD :: 8
@(private = "file")
VISIBLE :: 5 // options shown, two lines each

@(private = "file")
Combo_Option :: struct {
	members: [2]u8,
	skills:  [2]u16,
	combo:   int,
}

@(private = "file")
Combo_Plan :: struct {
	active:  bool,
	members: [2]u8,
	skills:  [2]u16,
	targets: [2]u8,
	pending: [2]bool, // its input still to be made
	auto:    int, // the plan member being committed, -1 none
	armed:   int, // picked at the Special list: the member whose commit sets the plan, -1 none
}

@(private = "file")
combo_menu: struct {
	main_menu, spell_init, turn_order: psx.Func_Proc,
	list_step, chain:                  psx.Func_Proc,
	shown, swallow:                    bool,
	last:                              u16,
	options:                           [OPTIONS_MAX]Combo_Option,
	count, row, top:                   int,
	enemy:                             int, // 0..5, the single target
	plan:                              Combo_Plan,
}

@(private)
combo_menu_init :: proc() -> bool {
	ok: bool
	hooks := [?]struct {
		addr, slot, id: u32,
		fn:             psx.Func_Proc,
		original:       ^psx.Func_Proc,
	} {
		{MAIN_MENU, SLOT_ENGINE, COMMAND_ID, main_menu, &combo_menu.main_menu},
		{SPELL_INIT, SLOT_ENGINE, COMMAND_ID, spell_init, &combo_menu.spell_init},
		{TURN_ORDER, SLOT_MENU, ROUND_ID, turn_order, &combo_menu.turn_order},
		{CHAIN_ROLL, SLOT_MENU, ROUND_ID, chain_roll, nil},
		{CHAIN, SLOT_MENU, ROUND_ID, chain, &combo_menu.chain},
		{LIST_STEP, SLOT_ENGINE, COMMAND_ID, list_step, &combo_menu.list_step},
	}
	for h in hooks {
		original: psx.Func_Proc
		if original, ok = psx.hook_overlay(h.addr, h.slot, h.id, h.fn); !ok {
			fmt.eprintf("qol: battle function %08x not found\n", h.addr)
			return false
		}
		if h.original != nil {
			h.original^ = original
		}
	}
	combo_menu.plan = {auto = -1, armed = -1}
	return true
}

// Out of battle nothing carries over.
@(private)
combo_menu_vblank :: proc() {
	if psx.lhu(GAME_MODE) != MODE_BATTLE {
		combo_menu.shown = false
		combo_menu.plan = {auto = -1, armed = -1}
		return
	}
	plan_settle()
}

// A combo performed by the party: one more use toward its mastery.
@(private)
combo_count_use :: proc(combo: int) {
	uses := &config.battle_combo_uses[combo]
	if uses^ >= COMBO_USES_MAX {
		return
	}
	uses^ += 1
	buf: [COMBO_COUNT * 3]u8
	b := strings.builder_from_bytes(buf[:])
	for u, k in config.battle_combo_uses {
		if k > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_int(&b, u)
	}
	config_write({{"battle", "combo_uses", strings.to_string(b)}})
}

// The config's combo_uses: up to COMBO_COUNT counts, comma-separated; the
// combos past the last count have none.
@(private)
parse_combo_uses :: proc(value: string, out: ^[COMBO_COUNT]int) -> bool {
	uses: [COMBO_COUNT]int
	rest := value
	for k in 0 ..< COMBO_COUNT {
		field, more := strings.split_iterator(&rest, ",")
		if !more {
			break
		}
		v, ok := strconv.parse_int(strings.trim_space(field), 10)
		if !ok || v < 0 || v > COMBO_USES_MAX {
			return false
		}
		uses[k] = v
	}
	if rest != "" {
		return false
	}
	out^ = uses
	return true
}

// The party has made this combo before (combo = skill - FIRST_COMBO).
@(private = "file")
combo_seen :: proc(combo: int) -> bool {
	return config.battle_combos & (1 << uint(combo)) != 0
}

@(private = "file")
mastery_level :: proc(combo: int) -> int {
	level := 0
	for uses in MASTERY_USES {
		if config.battle_combo_uses[combo] >= uses {
			level += 1
		}
	}
	return level
}

@(private = "file")
standing :: proc(p: u32) -> bool {
	return psx.lbu(p + C_FLAGS) & 1 != 0 && psx.lhu(p + C_STATE) & C_DOWN == 0
}

// A spell's element 0..3, -1 for none or another.
@(private = "file")
skill_element :: proc(skill: u16) -> int {
	elements := psx.lhu(SKILL_DATA + u32(skill) * SKILL_DATA_SIZE + SKILL_ELEMENTS)
	if elements == 0 {
		return -1
	}
	e := 0
	for elements > 1 {
		elements >>= 1
		e += 1
	}
	return e if e < ELEMENT_COUNT else -1
}

// A spell's combo level (BTLMOVE's table at 0x801e4e70), -1 for none.
@(private = "file")
skill_level :: proc(skill: u16) -> int {
	switch skill {
	case 1 ..= 12:
		return int(skill - 1) % 3
	case 152, 153:
		return 0
	case 154, 155:
		return 1
	case 159:
		return 2
	case 161 ..= 172:
		level := int(skill - 161) % 3
		if level == 2 && psx.lbu(BATTLE_KIND) == 2 {
			level = 3
		}
		return level
	}
	return -1
}

// The combo two spells make, first then second; -1 for none.
@(private = "file")
combo_of :: proc(first, second: u16) -> int {
	e1, e2, level := skill_element(first), skill_element(second), skill_level(second)
	if e1 < 0 || skill_level(first) < 0 || level < 0 || e2 != (e1 + 1) % ELEMENT_COUNT {
		return -1
	}
	return e1 * 4 + level
}

// The record target for a spell: 6 + enemy for one, a mask for a group; ok
// false for spells aimed some other way.
@(private = "file")
skill_target :: proc(skill: u16, enemy: int) -> (target: u8, ok: bool) {
	t := psx.lbu(SKILL_DATA + u32(skill) * SKILL_DATA_SIZE + SKILL_TARGETS)
	switch {
	case t & (TARGETS_ONE | 1) == TARGETS_ONE:
		return u8(FIRST_ENEMY + enemy), true
	case t & (0x40 | TARGETS_GROUP) == TARGETS_GROUP:
		mask: u8
		if t & 2 != 0 {
			mask |= 64
		}
		if t & 4 != 0 {
			mask |= 16
		}
		if t & 8 != 0 {
			mask |= 32
		}
		return mask, true
	}
	return 0, false
}

@(private = "file")
single_target :: proc(skill: u16) -> bool {
	return psx.lbu(SKILL_DATA + u32(skill) * SKILL_DATA_SIZE + SKILL_TARGETS) & (TARGETS_ONE | 1) == TARGETS_ONE
}

@(private = "file")
affordable :: proc(p: u32, skill: u16) -> bool {
	return u32(psx.lbu(SKILL_DATA + u32(skill) * SKILL_DATA_SIZE + SKILL_AP)) <= psx.lhu(p + C_AP)
}

// The committed slot of a member, -1 while it still chooses.
@(private = "file")
committed_slot :: proc(member: u8) -> int {
	for k in 0 ..< int(psx.lbu(BATTLE_STATE + INPUT_COMMITTED)) {
		if psx.lbu(BATTLE_STATE + INPUT_ORDER + u32(k)) == u32(member) {
			return k
		}
	}
	return -1
}

// The round's order puts the higher Agl first, ties in party order.
@(private = "file")
acts_before :: proc(a, b: u8) -> bool {
	agl_a, agl_b := psx.lhu(party_combatant(u32(a)) + C_AGL), psx.lhu(party_combatant(u32(b)) + C_AGL)
	return agl_a > agl_b || agl_a == agl_b && a < b
}

@(private = "file")
enemy_standing :: proc(e: int) -> bool {
	return standing(enemy_combatant(u32(e)))
}

// The command menu is up for a member, waiting on a button.
@(private = "file")
at_command_menu :: proc() -> bool {
	actor := i8(psx.lbu(BATTLE_STATE + INPUT_ACTOR))
	return psx.lhu(GAME_MODE) == MODE_BATTLE && psx.lw(SLOT_ENGINE) == COMMAND_ID && psx.lbu(BATTLE_STATE + INPUT_PHASE) == 1 && psx.lbu(BATTLE_STATE + INPUT_STEP) == 0 && psx.lbu(BATTLE_STATE + INPUT_MENU) == MENU_STEP && psx.lbu(MENU_BUSY) == 0 && actor >= 0 && actor < PARTY_COUNT
}

// Every combo with the choosing member in it, castable now.
@(private = "file")
gather :: proc() {
	combo_menu.count = 0
	actor := u8(psx.lbu(BATTLE_STATE + INPUT_ACTOR))
	for a in u8(0) ..< PARTY_COUNT {
		for b in u8(0) ..< PARTY_COUNT {
			if a == b || a != actor && b != actor || !acts_before(a, b) || !able(a) || !able(b) {
				continue
			}
			pa, pb := party_combatant(u32(a)), party_combatant(u32(b))
			for e in 0 ..< ELEMENT_COUNT {
				first := cheapest(pa, e)
				if first == 0 {
					continue
				}
				for k in u32(0) ..< C_SKILL_COUNT {
					second := u16(psx.lbu(pb + C_SKILLS + k))
					combo := combo_of(first, second)
					if second == 0 || combo < 0 || !affordable(pb, second) {
						continue
					}
					if _, ok := skill_target(second, 0); !ok || combo_menu.count == OPTIONS_MAX {
						continue
					}
					combo_menu.options[combo_menu.count] = {{a, b}, {first, second}, combo}
					combo_menu.count += 1
				}
			}
		}
	}
}

// Standing, and free to cast: still choosing, or committed to an attack,
// guard or spell (other commands keep their own state).
@(private = "file")
able :: proc(member: u8) -> bool {
	p := party_combatant(u32(member))
	if !standing(p) {
		return false
	}
	if committed_slot(member) < 0 {
		return true
	}
	switch psx.lbu(p + C_TYPE) {
	case TYPE_ATTACK, TYPE_GUARD, TYPE_MAGIC:
		return true
	}
	return false
}

// The member's cheapest affordable combo spell of an element, 0 for none.
@(private = "file")
cheapest :: proc(p: u32, element: int) -> u16 {
	best, best_ap := u16(0), u32(0)
	for k in u32(0) ..< C_SKILL_COUNT {
		skill := u16(psx.lbu(p + C_SKILLS + k))
		if skill == 0 || skill_element(skill) != element || skill_level(skill) < 0 || !affordable(p, skill) {
			continue
		}
		if _, ok := skill_target(skill, 0); !ok {
			continue
		}
		ap := psx.lbu(SKILL_DATA + u32(skill) * SKILL_DATA_SIZE + SKILL_AP)
		if best == 0 || ap < best_ap {
			best, best_ap = skill, ap
		}
	}
	return best
}

// psx.pad_hook in battle: Select at the command menu opens the list; the
// game sees no buttons while it is up, nor the ones closing it.
@(private)
combo_menu_buttons :: proc(held: u16) -> u16 {
	down := held &~ combo_menu.last
	combo_menu.last = held
	if combo_menu.swallow {
		combo_menu.swallow = held != 0
		return 0
	}
	if !combo_menu.shown {
		if config.battle_combo_command && down & psx.PAD_SELECT != 0 && at_command_menu() && combo_menu.plan.auto < 0 {
			list_open()
			return 0
		}
		return held
	}
	close := !at_command_menu() || down & (psx.PAD_SELECT | action_mask(.Cancel)) != 0
	if !close && combo_menu.count > 0 {
		switch {
		case down & psx.PAD_UP != 0:
			combo_menu.row = (combo_menu.row + combo_menu.count - 1) % combo_menu.count
		case down & psx.PAD_DOWN != 0:
			combo_menu.row = (combo_menu.row + 1) % combo_menu.count
		case down & psx.PAD_LEFT != 0:
			combo_menu.enemy = next_enemy(combo_menu.enemy, -1)
		case down & psx.PAD_RIGHT != 0:
			combo_menu.enemy = next_enemy(combo_menu.enemy, 1)
		case down & action_mask(.Confirm) != 0:
			plan_combo(combo_menu.options[combo_menu.row])
			close = true
		}
		combo_menu.top = clamp(combo_menu.top, combo_menu.row - VISIBLE + 1, combo_menu.row)
	}
	if close {
		combo_menu.shown = false
		combo_menu.swallow = held != 0
	}
	return 0
}

@(private = "file")
list_open :: proc() {
	gather()
	combo_menu.shown = true
	combo_menu.row, combo_menu.top = 0, 0
	combo_menu.enemy = next_enemy(-1, 1)
}

// The next standing enemy from `from` in `step`'s direction, wrapping.
@(private = "file")
next_enemy :: proc(from, step: int) -> int {
	e := from
	for _ in 0 ..< ENEMY_COUNT {
		e = (e + step + ENEMY_COUNT) % ENEMY_COUNT
		if enemy_standing(e) {
			return e
		}
	}
	return max(from, 0)
}

// Both spells set: a committed member's record now, the others' inputs as
// their turns come.
@(private = "file")
plan_combo :: proc(o: Combo_Option) {
	plan := Combo_Plan {
		active  = true,
		members = o.members,
		skills  = o.skills,
		auto    = -1,
		armed   = -1,
	}
	for k in 0 ..< 2 {
		plan.pending[k] = committed_slot(o.members[k]) < 0
	}
	combo_menu.plan = plan
	plan_aim(combo_menu.enemy, -1)
	if .Qol in psx.trace.active {
		psx.tracef(.Qol, "combo plan: %d skill %d, then %d skill %d", o.members[0], o.skills[0], o.members[1], o.skills[1])
	}
}

// Both spells aimed at an enemy, and written into the records of the plan
// members already committed, but for `own`, which committed by itself.
@(private = "file")
plan_aim :: proc(enemy, own: int) {
	plan := &combo_menu.plan
	for k in 0 ..< 2 {
		plan.targets[k], _ = skill_target(plan.skills[k], enemy)
		if plan.pending[k] || k == own {
			continue
		}
		p := party_combatant(u32(plan.members[k]))
		psx.sb(p + C_TARGET, u32(plan.targets[k]))
		psx.sb(p + C_TYPE, TYPE_MAGIC)
		psx.sh(p + C_SKILL, u32(plan.skills[k]))
	}
}

// A combo picked at the Special list waits on its member's commit: once
// it lands with the member's spell, the partner's spell is aimed at the
// enemy the member chose and the plan goes on as one picked from the list.
@(private = "file")
plan_settle :: proc() {
	plan := &combo_menu.plan
	k := plan.armed
	if k < 0 || committed_slot(plan.members[k]) < 0 {
		return
	}
	plan.armed = -1
	p := party_combatant(u32(plan.members[k]))
	if psx.lbu(p + C_TYPE) != TYPE_MAGIC || u16(psx.lhu(p + C_SKILL)) != plan.skills[k] {
		plan^ = {auto = -1, armed = -1}
		return
	}
	plan.pending[k] = false
	target := int(psx.lbu(p + C_TARGET))
	enemy := target - FIRST_ENEMY if target >= FIRST_ENEMY && target < FIRST_ENEMY + ENEMY_COUNT else next_enemy(-1, 1)
	plan_aim(enemy, k)
	if .Qol in psx.trace.active {
		psx.tracef(.Qol, "combo plan settled on enemy %d", enemy)
	}
}

// The command menu: a planned member still to choose picks Magic at once.
// Back at a planned member that already chose, the plan is dropped.
@(private = "file")
main_menu :: proc() {
	plan := &combo_menu.plan
	actor := u8(psx.lbu(BATTLE_STATE + INPUT_ACTOR))
	// Back out of a combo picked at the Special list before its commit.
	plan_settle()
	if plan.armed >= 0 {
		plan^ = {auto = -1, armed = -1}
	}
	for k in 0 ..< 2 {
		if !plan.active || plan.members[k] != actor {
			continue
		}
		if !plan.pending[k] {
			plan^ = {auto = -1, armed = -1}
			break
		}
		if psx.lbu(MENU_BUSY) != 0 {
			break
		}
		psx.sb(BATTLE_STATE + INPUT_MODE, MODE_MENU)
		psx.sh(BATTLE_STATE + INPUT_FLAGS, psx.lhu(BATTLE_STATE + INPUT_FLAGS) | FLAG_MENU)
		psx.sb(BATTLE_STATE + INPUT_COMMAND, COMMAND_MAGIC)
		psx.sb(BATTLE_STATE + INPUT_MENU, MENU_CHOSEN)
		plan.auto = k
		return
	}
	combo_menu.main_menu()
}

// The Special list: Confirm on a combo picks the member's own spell of it,
// as the game's Confirm on a spell does, and arms the plan.
@(private = "file")
list_step :: proc() {
	plan := &combo_menu.plan
	if plan.armed >= 0 { // back from the target choice
		plan^ = {auto = -1, armed = -1}
	}
	line := chosen_line()
	if line < 0 || u16(psx.lhu(PAD_PRESSED)) & u16(psx.lhu(CONFIRM_MASK)) == 0 {
		combo_menu.list_step()
		return
	}
	o := combo_menu.options[line]
	actor := u8(psx.lbu(BATTLE_STATE + INPUT_ACTOR))
	own := 0 if o.members[0] == actor else 1
	combo_menu.enemy = next_enemy(-1, 1)
	plan_combo(o)
	plan.armed = own
	psx.sh(psx.lw(ACTION_PTR) + REC_SKILL, u32(o.skills[own]))
	game_routine(SOUND, {SOUND_CONFIRM, 0, 0, 0, 0})
	psx.sb(SPELL_WINDOW + WINDOW_ACTIVE, 0)
	psx.sb(BATTLE_STATE + INPUT_SUBSTEP, SUB_LIST_PICKED)
	psx.sw(LIST_CURSOR, psx.lbu(SPELL_WINDOW + WINDOW_PAGE) << 16 | psx.lbu(SPELL_WINDOW + WINDOW_TOP) << 8 | psx.lbu(SPELL_WINDOW + WINDOW_ROW))
}

// The Special list is up for a member, waiting on a button.
@(private = "file")
at_spell_list :: proc() -> bool {
	actor := i8(psx.lbu(BATTLE_STATE + INPUT_ACTOR))
	return config.battle_combo_command && psx.lhu(GAME_MODE) == MODE_BATTLE && psx.lw(SLOT_ENGINE) == COMMAND_ID && psx.lbu(BATTLE_STATE + INPUT_PHASE) == 1 && psx.lbu(BATTLE_STATE + INPUT_STEP) == STEP_LIST && psx.lbu(BATTLE_STATE + INPUT_SUB) == SUB_LIST && psx.lbu(BATTLE_STATE + INPUT_MODE) == MODE_SPELL && psx.lbu(MENU_BUSY) == 0 && psx.lbu(SPELL_WINDOW + WINDOW_UP) != 0 && actor >= 0 && actor < PARTY_COUNT
}

// The first combo's slot on the Magic page: the first empty one, -1 when
// the member's spells fill the page.
@(private = "file")
combos_slot :: proc() -> int {
	p := party_combatant(u32(psx.lbu(BATTLE_STATE + INPUT_ACTOR)))
	for k in u32(0) ..< C_SKILL_COUNT {
		if psx.lbu(p + C_SKILLS + k) == 0 {
			return int(k)
		}
	}
	return -1
}

// The combos shown on the Magic page: those that fit the empty slots.
@(private = "file")
combo_lines :: proc() -> int {
	slot := combos_slot()
	return 0 if slot < 0 else min(combo_menu.count, C_SKILL_COUNT - slot)
}

// The combo under the game's cursor (gathered afresh), -1 for none.
@(private = "file")
chosen_line :: proc() -> int {
	if !at_spell_list() || psx.lbu(SPELL_WINDOW + WINDOW_PAGE) != 0 {
		return -1
	}
	gather()
	line := int(psx.lbu(SPELL_WINDOW + WINDOW_TOP) + psx.lbu(SPELL_WINDOW + WINDOW_ROW)) - combos_slot()
	return line if combos_slot() >= 0 && line >= 0 && line < combo_lines() else -1
}

// The Magic command for a planned member: straight to the game's commit,
// with the planned spell and target and the member's spell cursor kept.
@(private = "file")
spell_init :: proc() {
	plan := &combo_menu.plan
	k := plan.auto
	if k < 0 || !plan.active || u32(plan.members[k]) != psx.lbu(BATTLE_STATE + INPUT_ACTOR) {
		combo_menu.spell_init()
		return
	}
	commit_planned(k)
}

// The planned spell into the choosing member's record, and on to the game's
// commit (step 7) with the member's spell cursor kept.
@(private = "file")
commit_planned :: proc(k: int) {
	plan := &combo_menu.plan
	rec := psx.lw(ACTION_PTR)
	psx.sb(rec + REC_TARGET, u32(plan.targets[k]))
	psx.sh(rec + REC_SKILL, u32(plan.skills[k]))
	character := psx.lbu(party_combatant(u32(plan.members[k])) + C_CHAR)
	cursor := psx.lhu(BATTLE_STATE + INPUT_CURSORS + character * 2)
	psx.sb(SPELL_WINDOW + 12, cursor & 7)
	psx.sb(SPELL_WINDOW + 13, cursor >> 8)
	psx.sb(SPELL_WINDOW + 14, cursor >> 3 & 0x1f)
	psx.sb(BATTLE_STATE + INPUT_MODE, MODE_SPELL)
	psx.sb(BATTLE_STATE + INPUT_SUB, SUB_COMMIT)
	psx.sb(BATTLE_STATE + INPUT_SUBSTEP, 0)
	plan.pending[k] = false
	plan.auto = -1
}

// The round's order: the plan's second member moved right behind the first
// while both still cast the planned spells.
@(private = "file")
turn_order :: proc() {
	plan_settle()
	combo_menu.turn_order()
	plan := combo_menu.plan
	combo_menu.plan = {auto = -1, armed = -1}
	if !plan.active || plan.pending[0] || plan.pending[1] {
		return
	}
	for k in 0 ..< 2 {
		p := party_combatant(u32(plan.members[k]))
		if psx.lbu(p + C_TYPE) != TYPE_MAGIC || psx.lhu(p + C_SKILL) != u32(plan.skills[k]) {
			return
		}
	}
	count := min(int(psx.lbu(ORDER_COUNT)), 16)
	order: [16]u8
	at := [2]int{-1, -1}
	for i in 0 ..< count {
		order[i] = u8(psx.lbu(ORDER + u32(i)))
		for k in 0 ..< 2 {
			if order[i] == plan.members[k] {
				at[k] = i
			}
		}
	}
	if at[0] < 0 || at[1] < 0 || at[1] == at[0] + 1 {
		return
	}
	// Take the second out, then put it back behind the first.
	copy(order[at[1]:count - 1], order[at[1] + 1:count])
	first := at[0] - (1 if at[1] < at[0] else 0)
	copy(order[first + 2:count], order[first + 1:count - 1])
	order[first + 1] = plan.members[1]
	for i in 0 ..< count {
		psx.sb(ORDER + u32(i), u32(order[i]))
	}
	if .Qol in psx.trace.active {
		psx.tracef(.Qol, "combo order: %d behind %d", plan.members[1], plan.members[0])
	}
}

// Rebalanced mode (`[battle] balance`): chaining onto a party turn costs the
// member chaining on a surcharge of half the two spells' AP (rounded up),
// taken when the chain is made; a member short of it plus their own spell's
// AP does not chain.
@(private = "file")
chain :: proc() {
	if !config.battle_balance {
		combo_menu.chain()
		return
	}
	c := &psx.cpu
	turn := psx.lbu(ORDER_POS)
	first, second := psx.lbu(ORDER + turn), psx.lbu(ORDER + turn + 1)
	if turn + 1 >= psx.lbu(ORDER_COUNT) || first >= 6 || second >= 6 {
		combo_menu.chain()
		return
	}
	p1, p2 := party_combatant(first), party_combatant(second)
	ap_1 := u32(psx.lbu(SKILL_DATA + psx.lhu(p1 + C_SKILL) * SKILL_DATA_SIZE + SKILL_AP))
	ap_2 := u32(psx.lbu(SKILL_DATA + psx.lhu(p2 + C_SKILL) * SKILL_DATA_SIZE + SKILL_AP))
	surcharge := (ap_1 + ap_2 + 1) / 2
	ap := psx.lhu(p2 + C_AP)
	if ap < ap_2 + surcharge {
		c.r[2] = 0
		return
	}
	combo_menu.chain()
	if c.r[2] & 0xff == 0 {
		return
	}
	psx.sh(p2 + C_AP, ap - surcharge)
	if .Qol in psx.trace.active {
		psx.tracef(.Qol, "combo surcharge: member %d pays %d AP chaining onto %d", second, surcharge, first)
	}
}

// The chain roll (801b25a8), with mastery: 75 (85 when BATTLE_KIND is 0),
// +10 per CHAIN_TRAIT member of the two, +5 when the spells share an
// element, +5 when either is quicker than the standing enemies' mean Agl,
// then +5 per mastery level, sure at the top one or for a combo never performed.
@(private = "file")
chain_roll :: proc() {
	c := &psx.cpu
	// The earlier caster, then the one that would chain onto it.
	first, second := c.r[4] & 0xff, c.r[5] & 0xff
	p1, p2 := party_combatant(first), party_combatant(second)
	chance := 85 if psx.lbu(BATTLE_KIND) == 0 else 75
	if psx.lbu(p1 + C_CHAIN) == CHAIN_TRAIT {
		chance += 10
	}
	if psx.lbu(p2 + C_CHAIN) == CHAIN_TRAIT {
		chance += 10
	}
	skill_1, skill_2 := u16(psx.lhu(p1 + C_SKILL)), u16(psx.lhu(p2 + C_SKILL))
	elements := psx.lhu(SKILL_DATA + u32(skill_1) * SKILL_DATA_SIZE + SKILL_ELEMENTS)
	if elements & psx.lhu(SKILL_DATA + u32(skill_2) * SKILL_DATA_SIZE + SKILL_ELEMENTS) != 0 {
		chance += 5
	}
	sum, count := u32(0), u32(0)
	for e in 0 ..< ENEMY_COUNT {
		if enemy_standing(e) {
			sum += psx.lhu(enemy_combatant(u32(e)) + C_AGL)
			count += 1
		}
	}
	// The game divides by zero with no enemy standing: MIPS gives -1.
	mean := i32(sum & 0xffff) / i32(count) if count > 0 else -1
	if mean + 1 < i32(psx.lhu(p1 + C_AGL)) || mean + 1 < i32(psx.lhu(p2 + C_AGL)) {
		chance += 5
	}
	if combo := combo_of(skill_1, skill_2); config.battle_combo_mastery && first < 6 && second < 6 && combo >= 0 {
		level := mastery_level(combo)
		chance = ROLL if level == MASTERY_MAX || config.battle_combo_uses[combo] == 0 else chance + MASTERY_STEP * level
	}
	ra := c.r[31]
	psx.call(RAND)
	c.r[31] = ra
	c.r[2] = u32(i32(c.r[2]) % ROLL - i32(chance & 0xff)) >> 31
}

@(private)
combo_menu_draws :: proc() -> bool {
	return combo_menu.shown || at_spell_list() && psx.lbu(SPELL_WINDOW + WINDOW_PAGE) == 0
}

@(private)
combo_menu_draw :: proc() {
	if at_spell_list() {
		combo_lines_draw()
	}
	if combo_menu.shown {
		combo_list_draw()
	}
}

// The combos in their slots of the Magic page, named with the member's own
// spell's AP, and the chosen one's pair of spells in the help window.
@(private = "file")
combo_lines_draw :: proc() {
	chosen := chosen_line()
	if psx.lbu(SPELL_WINDOW + WINDOW_PAGE) != 0 {
		return
	}
	actor := u8(psx.lbu(BATTLE_STATE + INPUT_ACTOR))
	wx := int(i16(psx.lhu(SPELL_WINDOW + WINDOW_X)))
	top := int(psx.lbu(SPELL_WINDOW + WINDOW_TOP))
	for &o, i in combo_menu.options[:combo_lines()] {
		row := combos_slot() + i - top
		if row < 0 || row >= WINDOW_ROWS {
			continue
		}
		y := int(i16(psx.lhu(SPELL_WINDOW + WINDOW_Y))) + SLOT_Y + row * SLOT_H
		game_routine(SKILL_ICON, {u32(wx + SLOT_ICON_X), u32(y), u32(FIRST_COMBO + o.combo), 0, 0})
		menu_text(wx + SLOT_X, y, combo_seen(o.combo) ? combo_name(o.combo) : "???")
		own := o.skills[0] if o.members[0] == actor else o.skills[1]
		buf: [4]u8
		menu_text_right(wx + SLOT_AP_X, y, strconv.write_int(buf[:], i64(psx.lbu(SKILL_DATA + u32(own) * SKILL_DATA_SIZE + SKILL_AP)), 10))
	}
	if chosen < 0 {
		return
	}
	o := combo_menu.options[chosen]
	names: [2][C_NAME_LEN]u8
	spells: [2][SKILL_NAME_MAX]u8
	line: [64]u8
	text := fmt.bprintf(line[:], "%s: %s, then %s: %s", c_name(party_combatant(u32(o.members[0])), names[0][:]), skill_name(u8(o.skills[0]), spells[0][:]), c_name(party_combatant(u32(o.members[1])), names[1][:]), skill_name(u8(o.skills[1]), spells[1][:]))
	right := HELP_RIGHT
	if config.battle_combo_mastery {
		buf: [8]u8
		mastery := fmt.bprintf(buf[:], "%d/%d", mastery_level(o.combo), MASTERY_MAX)
		menu_text_right(right, HELP_Y, mastery, MENU_GREY)
		right -= menu_text_width(mastery) + 8
	}
	menu_text(HELP_X, HELP_Y, menu_text_fit(text, right - HELP_X))
}

@(private = "file")
combo_list_draw :: proc() {
	rows := 1 + 2 * min(max(combo_menu.count, 1), VISIBLE) + 1
	menu_window(BOX_X, BOX_Y, BOX_W, 2 * BOX_PAD + rows * MENU_LINE_H)
	x, right := BOX_X + BOX_PAD, BOX_X + BOX_W - BOX_PAD
	y := BOX_Y + BOX_PAD
	menu_text(x, y, "Combo", MENU_YELLOW)
	targeted := combo_menu.count > 0 && single_target(combo_menu.options[combo_menu.row].skills[0])
	if targeted {
		name: [C_NAME_LEN]u8
		menu_text_right(right, y, c_name(enemy_combatant(u32(combo_menu.enemy)), name[:]))
	}
	y += MENU_LINE_H
	if combo_menu.count == 0 {
		menu_text(x, y, "No combo is ready.", MENU_GREY)
		y += 2 * MENU_LINE_H
	}
	for &o, i in combo_menu.options[combo_menu.top:min(combo_menu.count, combo_menu.top + VISIBLE)] {
		chosen := combo_menu.top + i == combo_menu.row
		menu_text(x, y, combo_seen(o.combo) ? combo_name(o.combo) : "???", MENU_YELLOW if chosen else MENU_WHITE)
		if config.battle_combo_mastery {
			buf: [16]u8
			menu_text_right(right, y, fmt.bprintf(buf[:], "Mastery %d/%d", mastery_level(o.combo), MASTERY_MAX), MENU_GREY)
		}
		names: [2][C_NAME_LEN]u8
		spells: [2][SKILL_NAME_MAX]u8
		line: [64]u8
		text := fmt.bprintf(line[:], "%s: %s, then %s: %s", c_name(party_combatant(u32(o.members[0])), names[0][:]), skill_name(u8(o.skills[0]), spells[0][:]), c_name(party_combatant(u32(o.members[1])), names[1][:]), skill_name(u8(o.skills[1]), spells[1][:]))
		menu_text(x + 8, y + MENU_LINE_H, menu_text_fit(text, right - x - 8), MENU_GREY)
		y += 2 * MENU_LINE_H
	}
	foot := "Up/Down  Left/Right: target" if targeted else "Up/Down"
	menu_text(x, y, foot, MENU_GREY)
}

// A combatant's name, copied into buf.
@(private = "file")
c_name :: proc(p: u32, buf: []u8) -> string {
	n := 0
	for n < len(buf) {
		ch := u8(psx.lbu(p + C_NAME + u32(n)))
		if ch == 0 {
			break
		}
		buf[n] = ch
		n += 1
	}
	return string(buf[:n])
}
