// Smarter enemies, in seven tiers.
//
// An enemy decides its action as its turn comes up in the round (BTLMOVE.EMI,
// overlay 0x34 at 0x801cc800): 0x801d6238 runs the enemy's own script, rolls
// one of the four 2-bit actions in its pattern byte (0x801c65a8 indexed by
// enemy +0x11c; 0 attack, 1 kind 2 with flag 0x100 of +0xac, 2 kind 3 with
// 0x200, 3 a random one of the 8 skills with SKILL_USER, else an attack),
// then picks the target. A party target is either the lowest-HP member (0x801d7388, for
// enemies with flag 0x800 of +0xac) or, for nearly every enemy, a random
// standing front member: RANDOM_MEMBER. Confused enemies (+0xae bit 0x10)
// call it too. `enemy_ai` replaces that random pick and looks the rolled
// action over afterwards (DECIDE, hooked after the original); the enemy's
// skill list and script stay its own, so every fight stays recognisable and
// enemies still use the skills the party can learn. A learnable skill the
// party does not know yet is never swapped out. Each tier adds to the one
// before (PLANS):
//
//   aware       the game's random target; no skill it lacks the AP for
//               (castable: a plain attack instead); no wasted heals (a heal with every
//               ally above HEAL_WASTE becomes another skill); a damage skill
//               is not aimed at a member it cannot hurt (immune or absorbing
//               its element) when another can be hurt
//   smart       the member with the least HP for its max HP, 2 picks in 3;
//               an ally below a quarter of its max HP gets a heal from the
//               list, aimed at it
//   clever      heals below a third; a damage skill is swapped for one in the
//               list that hits the target's element harder
//   tactical    focus fire (the same member until it falls, then a healer,
//               a caster, the weakest: threats); heals below a half; 2 in 6
//               casts a buff on an ally the enemies have not given it yet
//   cunning     answers a buffed member (the debuff for that stat) or a
//               dragon form with a hindrance, no roll; 2 in 6 casts a debuff
//               or status on the healthiest member it has not hit with it
//               yet; a rolled one goes to such a member, and with nobody left
//               becomes a damage skill or, as a rolled buff with nobody left
//               does, a plain attack
//   ruthless    always the member with the least HP (more AP on a tie), no
//               threats; the damage skill with the most power x element rate
//   mastermind  threats again; 3 in 6 for buffs and hindrances; damage goes
//               to the member with the least HP for the skill's element rate
//               on it
//
// The element rate is the game's (0x801d4910): the average, over the
// skill's element bits (skill data +6: fire, wind, water, earth, holy), of
// ELEMENT_RATES at the target's level for that element (combatant +0xea, a
// byte each; 2 normal, 1 weak, 6 immune, 7 absorbs). Who was buffed or
// hindered is what the enemies cast this battle (marks), cleared out of
// battle; a status counts as long as the member still has a status, a
// debuff until the member is buffed in that stat again (PARTY_BUFFS), and
// a member's marks go when it takes or leaves a dragon form. A healer or
// caster is a member who knows such a skill (COMBATANT_SKILLS) and has the AP.
package qol

import "core:fmt"

import "../psx"

import "ps:core"

@(private)
Enemy_AI :: enum u8 {
	Original,
	Aware,
	Smart,
	Clever,
	Tactical,
	Cunning,
	Ruthless,
	Mastermind,
}

// As bof4.ini and the Extras menu name the tiers.
@(private)
ENEMY_AI_KEYS := [Enemy_AI]string {
	.Original   = "original",
	.Aware      = "aware",
	.Smart      = "smart",
	.Clever     = "clever",
	.Tactical   = "tactical",
	.Cunning    = "cunning",
	.Ruthless   = "ruthless",
	.Mastermind = "mastermind",
}
@(private)
ENEMY_AI_TEXT := [Enemy_AI]string {
	.Original   = "Original",
	.Aware      = "Aware",
	.Smart      = "Smart",
	.Clever     = "Clever",
	.Tactical   = "Tactical",
	.Cunning    = "Cunning",
	.Ruthless   = "Ruthless",
	.Mastermind = "Mastermind",
}

@(private = "file")
Pick :: enum u8 {
	Random, // the game's own
	Mostly, // the weakest for its max HP, SMART_PICKS in SMART_OF
	Focus,  // the same member until it falls, then the weakest
	Lowest, // the least HP in points, more AP on a tie
}

@(private = "file")
Elements :: enum u8 {
	Ignore,
	Avoid,     // retarget (or swap) a damage skill the target is immune to
	Weakness,  // and swap it for a list skill with a higher rate on the target
	Strongest, // the list skill with the most power x rate on the target
}

@(private = "file")
Plan :: struct {
	pick:     Pick,
	heal_low: u32, // twelfths of max HP below which an ally gets a heal, 0 never
	elements: Elements,
	softest:  bool, // damage to the member with the least HP for its rate
	threats:  bool, // a new target is a healer, then a caster, before the rest
	buffs:    u32, // in CHANCE_OF
	hinders:  u32, // in CHANCE_OF
	all_out:  bool, // a rolled attack becomes a damage skill
}

@(private = "file")
PLANS := [Enemy_AI]Plan {
	.Original   = {},
	.Aware      = {pick = .Random, elements = .Avoid},
	.Smart      = {pick = .Mostly, heal_low = 3, elements = .Avoid},
	.Clever     = {pick = .Mostly, heal_low = 4, elements = .Weakness},
	.Tactical   = {pick = .Focus, heal_low = 6, elements = .Weakness, threats = true, buffs = 2},
	.Cunning    = {pick = .Focus, heal_low = 6, elements = .Weakness, threats = true, buffs = 2, hinders = 2},
	.Ruthless   = {pick = .Lowest, heal_low = 6, elements = .Strongest, buffs = 2, hinders = 2},
	.Mastermind = {pick = .Lowest, heal_low = 6, elements = .Strongest, softest = true, threats = true, buffs = 3, hinders = 3},
}

@(private = "file")
HEAL_DEN :: 12
@(private = "file")
HEAL_WASTE :: 9 // a heal with every ally above three quarters is wasted
@(private = "file")
CHANCE_OF :: 6

@(private = "file")
ROUND_ID :: 0x34
// Returns a random standing front member, 255 when none stands.
@(private = "file")
RANDOM_MEMBER :: 0x801d72d0
// Takes the enemy index (actor id - ENEMY_IDS) in r4.
@(private = "file")
DECIDE :: 0x801d6238
// Takes a skill id in r4, returns the target for the acting enemy, 255 none.
@(private = "file")
SKILL_TARGET :: 0x801d6b64
// Takes a combatant id in r4, returns nonzero when it can be targeted.
@(private = "file")
TARGETABLE :: 0x801aed7c
// s16 percent by element level: 8 for fire, wind, water and earth, then 8
// for holy (round overlay data).
@(private = "file")
ELEMENT_RATES :: 0x801e509c
@(private = "file")
ELEMENT_LEVELS :: 8
@(private = "file")
ELEMENT_COUNT :: 5
@(private = "file")
HOLY :: 4
@(private = "file")
FULL_RATE :: 100

@(private = "file")
GAME_MODE_BATTLE :: 5


@(private = "file")
STATUS :: 0xae // u16, party and enemies
@(private = "file")
CONFUSED :: 0x10
@(private = "file")
ENEMY_FLAGS :: 0xac // u16
@(private = "file")
SKILL_USER :: 0x400 // may roll a skill
@(private = "file")
ENEMY_SKILLS :: 0x12c // 8 skill ids, the roll picks one at random
@(private = "file")
SKILL_COUNT :: 8
@(private = "file")
ENEMY_KIND :: 0x15d // u8, as the record's
@(private = "file")
ENEMY_SKILL :: 0x15e // u16
@(private = "file")
ENEMY_TARGET :: 0x15c // u8
@(private = "file")
TARGET :: 0x8011e0f8 // u8, the action's target
@(private = "file")
ENEMY_SLOTS :: 6
@(private = "file")
COMBATANTS :: ENEMY_IDS + ENEMY_SLOTS // ids below are single targets

// The round record at ACTION: +1 kind, +2 skill.
@(private = "file")
KIND_ATTACK :: 1
@(private = "file")
KIND_SKILL :: 4
@(private = "file")
NO_TARGET :: 255

@(private = "file")
SKILL_DATA_SIZE :: 12
@(private = "file")
SKILL_FLAGS :: 0 // u8; SKILL_HEALS for the Heal family
@(private = "file")
SKILL_HEALS :: 0x80
@(private = "file")
SKILL_SIDE :: 0x08 // set on support skills (buffs, heals, debuffs too)
@(private = "file")
SKILL_LEARN :: 2 // low nibble: learn level, 0 not learnable
@(private = "file")
SKILL_POWER :: 3 // u8, Flare 15, Fireblast 30, Inferno 80
@(private = "file")
SKILL_ELEMENT :: 6 // u8, bit per element as ELEMENT_RATES
@(private = "file")
SKILL_COST :: 4 // u8 AP
@(private = "file")
SKILL_EFFECT :: 9 // u8
@(private = "file")
SKILL_EFFECT_ID :: 10 // u8
// Effect ids Blunt, Weaken, Slow and Enfeeble lower buff slots 0..3.
@(private = "file")
DEBUFF_FIRST :: 0x28
@(private = "file")
DEBUFF_SLOTS :: 4
@(private = "file")
EFFECT_DEBUFF :: 0x01
@(private = "file")
EFFECT_BARRIER :: 0x02
@(private = "file")
EFFECT_BUFF :: 0x04
@(private = "file")
EFFECT_STATUS :: 0x08

@(private = "file")
FRONT_COUNT :: 3
@(private = "file")
COMBATANT_AP :: 0xb4 // u32
@(private = "file")
COMBATANT_AP_EXTRA :: 0xb8 // u16, spent before COMBATANT_AP
@(private = "file")
COMBATANT_ELEMENTS :: 0xea // u8 level per element
@(private = "file")
COMBATANT_CHAR :: 0xa4 // u8 char id, DRAGON_CHAR and up in a dragon form
@(private = "file")
DRAGON_CHAR :: 7
// The char record's skill ids: 16 known, then 8 learned from enemies.
@(private = "file")
COMBATANT_SKILLS :: 0xba
@(private = "file")
KNOWN_SKILLS :: 24
// u8 percent per stat (power, defense, ...), FULL_RATE unchanged.
@(private = "file")
PARTY_BUFFS :: 0x18c
// What a hindrance on a dragon form is worth, against a buff's percent.
@(private = "file")
DRAGON_WORTH :: 50

@(private = "file")
NOBODY :: 255
// Smart picks the weakest member SMART_PICKS times in SMART_OF.
@(private = "file")
SMART_PICKS :: 2
@(private = "file")
SMART_OF :: 3

@(private = "file")
ai: struct {
	random_member: psx.Func_Proc,
	decide:        psx.Func_Proc,
	// Tactical: the member the enemies focus on.
	focus:         u32,
	// Per combatant id, a bit per skill id the enemies buffed or hindered it
	// with this battle.
	marks:         [COMBATANTS][256 / 64]u64,
	// Per front member, the char id its marks are for: a dragon form (or
	// leaving one) is a new combatant to hinder.
	forms:         [FRONT_COUNT]u8,
	// Per enemy slot with ai_by_strength, its tier this battle (Original
	// until its first turn).
	tiers:         [ENEMY_SLOTS]Enemy_AI,
	// The tier of the enemy acting now.
	tier:          Enemy_AI,
	// With ai_moods, the acting enemy's mood and the member it is enraged
	// at (moods.odin).
	mood:          Mood,
	culprit:       u32,
}

@(private)
ai_init :: proc() -> bool {
	original, ok := psx.hook_overlay(RANDOM_MEMBER, SLOT_ENGINE, ROUND_ID, random_member)
	if !ok {
		fmt.eprintf("qol: battle function %08x not found\n", RANDOM_MEMBER)
		return false
	}
	ai.random_member = original
	original, ok = psx.hook_overlay(DECIDE, SLOT_ENGINE, ROUND_ID, decide)
	if !ok {
		fmt.eprintf("qol: battle function %08x not found\n", DECIDE)
		return false
	}
	ai.decide = original
	ai.focus = NOBODY
	return true
}

// The tier an enemy slot thinks at: enemy_ai, or with ai_by_strength the
// enemy's max HP against the standing front members' average, set on its
// first turn (so a dragon form does not change it): under half Aware, then
// one tier per doubling, Mastermind from 16 times; never above enemy_ai.
@(private = "file")
tier_of :: proc(slot: u32) -> Enemy_AI {
	top := config.battle_enemy_ai
	if !config.battle_ai_by_strength || top == .Original || slot >= ENEMY_SLOTS {
		return top
	}
	if ai.tiers[slot] != .Original {
		return ai.tiers[slot]
	}
	sum, count: u64
	for member in u32(0) ..< FRONT_COUNT {
		if targetable(member) {
			sum += u64(psx.lw(party_combatant(member) + COMBATANT_HP_MAX))
			count += 1
		}
	}
	// Twice the enemy's max HP over the party's average, in whole steps.
	halves := u64(psx.lw(enemy_combatant(slot) + COMBATANT_HP_MAX)) * 2 * count / max(sum, 1)
	tier := int(Enemy_AI.Aware)
	for ; halves != 0 && tier < int(Enemy_AI.Mastermind); halves >>= 1 {
		tier += 1
	}
	ai.tiers[slot] = Enemy_AI(min(tier, int(top)))
	if .Game in core.trace.active {
		core.tracef(.Game, "ai: enemy slot %d max HP %d, party average %d: %v", slot, psx.lw(enemy_combatant(slot) + COMBATANT_HP_MAX), sum / max(count, 1), ai.tiers[slot])
	}
	return ai.tiers[slot]
}

// The plan the enemy in `slot` acts on: its tier's, shaped by its mood
// (moods.odin), which also goes to ai.mood and ai.culprit.
@(private = "file")
plan_of :: proc(slot: u32) -> Plan {
	plan := PLANS[ai.tier]
	ai.mood, ai.culprit = mood_of(slot)
	switch ai.mood {
	case .Calm:
	case .Cocky:
		plan.pick = .Random
		plan.buffs = min(plan.buffs + 1, CHANCE_OF)
		plan.hinders = min(plan.hinders + 1, CHANCE_OF)
	case .Cautious:
		plan.heal_low = max(plan.heal_low, CAUTIOUS_HEAL)
		plan.buffs = min(plan.buffs + 1, CHANCE_OF)
	case .Enraged:
		// Everything at the culprit: no retargeting.
		plan.buffs, plan.hinders, plan.softest = 0, 0, false
		plan.elements = min(plan.elements, Elements.Weakness)
	case .Desperate:
		plan.buffs, plan.hinders, plan.all_out = 0, 0, true
		plan.elements = .Strongest
	}
	return plan
}

// Each frame: out of battle, forget the battle's marks and focus.
@(private)
ai_tick :: proc() {
	if psx.lhu(GAME_MODE) != GAME_MODE_BATTLE {
		ai.marks = {}
		ai.focus = NOBODY
		ai.tiers = {}
		moods_tick()
	}
}

@(private = "file")
decide :: proc() {
	index := psx.cpu.r[4] & 0xff
	ai.decide()
	enemy := enemy_combatant(index)
	ai.tier = tier_of(index)
	defer mood_turn(index)
	if ai.tier == .Original || psx.lhu(enemy + STATUS) & CONFUSED != 0 || psx.lhu(enemy + ENEMY_FLAGS) & SKILL_USER == 0 {
		return
	}
	for member in u32(0) ..< FRONT_COUNT {
		if form := u8(psx.lbu(party_combatant(member) + COMBATANT_CHAR)); form != ai.forms[member] {
			ai.marks[member] = {}
			ai.forms[member] = form
		}
	}
	think(enemy, plan_of(index))
	mark_cast()
	if .Game in core.trace.active {
		core.tracef(.Game, "ai: enemy %d %v decides kind %d skill %d on %d, AP %d", psx.lbu(ACTION), ai.mood, psx.lbu(ACTION + 1), psx.lhu(ACTION + 2), psx.lbu(TARGET), psx.lw(enemy + COMBATANT_AP))
	}
}

@(private = "file")
think :: proc(enemy: u32, plan: Plan) {
	kind := psx.lbu(ACTION + 1)
	if kind != KIND_ATTACK && kind != KIND_SKILL {
		return
	}
	rolled := u8(psx.lhu(ACTION + 2)) if kind == KIND_SKILL else 0
	if rolled != 0 && !castable(enemy, rolled) {
		// Short of AP the cast would only waste the turn.
		attack(enemy)
		rolled = 0
	}
	if rolled != 0 && learnable_unknown(rolled) {
		return
	}
	if plan.heal_low != 0 {
		if hurt := hurt_enemy(plan.heal_low); hurt != NOBODY {
			if heal := list_skill(enemy, .Heal); heal != 0 {
				use_skill(enemy, heal, hurt)
				return
			}
		}
	}
	if rolled != 0 && skill_is(rolled, .Heal) && hurt_enemy(HEAL_WASTE) == NOBODY {
		other := list_skill(enemy, .Other)
		if other == 0 {
			return
		}
		// Aimed below like a rolled one.
		use_skill(enemy, other, NOBODY)
		rolled = other
	}
	if plan.buffs != 0 {
		if skill, ally := unmarked(enemy, .Buff); skill != 0 && chance(plan.buffs) {
			use_skill(enemy, skill, ally)
			return
		}
	}
	if plan.hinders != 0 {
		// A buffed member or a dragon form is answered without a roll.
		if skill, member := answer(enemy); skill != 0 {
			use_skill(enemy, skill, member)
			return
		}
	}
	if plan.hinders != 0 && (rolled == 0 || !skill_is(rolled, .Hinder)) {
		if skill, member := unmarked(enemy, .Hinder); skill != 0 && chance(plan.hinders) {
			use_skill(enemy, skill, member)
			return
		}
	}
	if rolled == 0 && plan.all_out && kind == KIND_ATTACK {
		if skill := list_skill(enemy, .Damage); skill != 0 {
			// Aimed below like a rolled one.
			use_skill(enemy, skill, u32(psx.lbu(TARGET)))
			rolled = skill
		}
	}
	if rolled == 0 {
		return
	}
	switch {
	case skill_is(rolled, .Buff) && plan.buffs != 0:
		aim_unmarked(enemy, rolled, .Buff)
	case skill_is(rolled, .Hinder) && plan.hinders != 0:
		aim_unmarked(enemy, rolled, .Hinder)
	case skill_is(rolled, .Damage) && plan.elements != .Ignore:
		aim_damage(enemy, rolled, plan)
	}
}

@(private = "file")
Skill_Use :: enum u8 {
	Heal,   // SKILL_HEALS
	Damage, // power, not a support skill
	Buff,   // buff or barrier, not a heal
	Hinder, // debuff or status
	Other,  // anything but a heal
}

@(private = "file")
skill_is :: proc(skill: u8, use: Skill_Use) -> bool {
	data := SKILL_DATA + u32(skill) * SKILL_DATA_SIZE
	flags, effect := psx.lbu(data + SKILL_FLAGS), psx.lbu(data + SKILL_EFFECT)
	switch use {
	case .Heal:
		return flags & SKILL_HEALS != 0
	case .Damage:
		return flags != 0 && flags & (SKILL_HEALS | SKILL_SIDE) == 0 && psx.lbu(data + SKILL_POWER) != 0
	case .Buff:
		return flags & SKILL_HEALS == 0 && effect & (EFFECT_BUFF | EFFECT_BARRIER) != 0
	case .Hinder:
		return effect & (EFFECT_DEBUFF | EFFECT_STATUS) != 0
	case .Other:
		return flags & SKILL_HEALS == 0
	}
	return false
}

@(private = "file")
skill_power :: proc(skill: u8) -> i32 {
	return i32(psx.lbu(SKILL_DATA + u32(skill) * SKILL_DATA_SIZE + SKILL_POWER))
}

// A list skill the enemy has the AP for. The round's cast (0x801cdf04)
// checks AP plus the u16 at COMBATANT_AP_EXTRA (spent first) against the
// skill's cost and wastes the turn when short; DECIDE never checks.
@(private = "file")
castable :: proc(enemy: u32, skill: u8) -> bool {
	if skill == 0 {
		return false
	}
	cost := u32(psx.lbu(SKILL_DATA + u32(skill) * SKILL_DATA_SIZE + SKILL_COST))
	return cost <= psx.lw(enemy + COMBATANT_AP) + psx.lhu(enemy + COMBATANT_AP_EXTRA)
}

// The enemy's first castable skill of that use, 0 for none.
@(private = "file")
list_skill :: proc(enemy: u32, use: Skill_Use) -> u8 {
	for k in u32(0) ..< SKILL_COUNT {
		skill := u8(psx.lbu(enemy + ENEMY_SKILLS + k))
		if castable(enemy, skill) && skill_is(skill, use) {
			return skill
		}
	}
	return 0
}

@(private = "file")
learnable_unknown :: proc(skill: u8) -> bool {
	return psx.lbu(SKILL_DATA + u32(skill) * SKILL_DATA_SIZE + SKILL_LEARN) & 0xf != 0 && !skill_known(skill)
}

@(private = "file")
chance :: proc(in_six: u32) -> bool {
	psx.call(RAND)
	return psx.cpu.r[2] % CHANCE_OF < in_six
}

// The percent of a skill's damage that reaches `id`, as the game's element
// rate: 100 without an element, 0 immune, negative absorbed.
@(private = "file")
element_rate :: proc(id: u32, skill: u8) -> i32 {
	bits := psx.lbu(SKILL_DATA + u32(skill) * SKILL_DATA_SIZE + SKILL_ELEMENT)
	levels := combatant(id) + COMBATANT_ELEMENTS
	sum, count: i32
	for k in u32(0) ..< ELEMENT_COUNT {
		if bits & (1 << k) == 0 {
			continue
		}
		level := min(psx.lbu(levels + k), ELEMENT_LEVELS - 1)
		table := u32(ELEMENT_RATES + (ELEMENT_LEVELS * 2 if k == HOLY else 0))
		sum += i32(i16(psx.lhu(table + level * 2)))
		count += 1
	}
	return sum / count if count != 0 else FULL_RATE
}

// Pick the damage skill and target, from the rolled skill and the target the
// game gave it.
@(private = "file")
aim_damage :: proc(enemy: u32, rolled: u8, plan: Plan) {
	target := psx.lbu(TARGET)
	if target >= ENEMY_IDS {
		return
	}
	skill := rolled
	switch plan.elements {
	case .Ignore, .Avoid:
	case .Weakness:
		best := element_rate(target, skill) if castable(enemy, skill) else min(i32)
		for k in u32(0) ..< SKILL_COUNT {
			s := u8(psx.lbu(enemy + ENEMY_SKILLS + k))
			if !castable(enemy, s) || !skill_is(s, .Damage) {
				continue
			}
			if rate := element_rate(target, s); rate > best {
				skill, best = s, rate
			}
		}
	case .Strongest:
		best := skill_power(skill) * element_rate(target, skill) if castable(enemy, skill) else min(i32)
		for k in u32(0) ..< SKILL_COUNT {
			s := u8(psx.lbu(enemy + ENEMY_SKILLS + k))
			if !castable(enemy, s) || !skill_is(s, .Damage) {
				continue
			}
			if score := skill_power(s) * element_rate(target, s); score > best {
				skill, best = s, score
			}
		}
	}
	member := target
	if plan.softest {
		member = softest_member(skill, target)
	} else if element_rate(target, skill) <= 0 {
		member = hardest_hit(skill, target)
	}
	if element_rate(member, skill) <= 0 {
		// Nobody it can hurt: another damage skill that hurts the target.
		for k in u32(0) ..< SKILL_COUNT {
			s := u8(psx.lbu(enemy + ENEMY_SKILLS + k))
			if castable(enemy, s) && skill_is(s, .Damage) && element_rate(target, s) > 0 {
				skill, member = s, target
				break
			}
		}
	}
	if skill != rolled || member != target {
		set_action(enemy, skill, member)
	}
}

// The standing front member that takes the most of `skill`, `keep` on a tie.
@(private = "file")
hardest_hit :: proc(skill: u8, keep: u32) -> u32 {
	pick, best := keep, element_rate(keep, skill)
	for member in u32(0) ..< FRONT_COUNT {
		if member == keep || !targetable(member) {
			continue
		}
		if rate := element_rate(member, skill); rate > best {
			pick, best = member, rate
		}
	}
	return pick
}

// The standing front member with the least HP for the rate `skill` hurts it
// with, among those it hurts; `keep` when it hurts none.
@(private = "file")
softest_member :: proc(skill: u8, keep: u32) -> u32 {
	pick := keep
	best_hp, best_rate: i64
	for member in u32(0) ..< FRONT_COUNT {
		if !targetable(member) {
			continue
		}
		rate := i64(element_rate(member, skill))
		if rate <= 0 {
			continue
		}
		hp := i64(psx.lw(party_combatant(member) + COMBATANT_HP))
		// hp / rate < best_hp / best_rate, without division.
		if best_rate == 0 || hp * best_rate < best_hp * rate {
			pick, best_hp, best_rate = member, hp, rate
		}
	}
	return pick
}

// A buff (on an ally) or a hindrance (on a front member) from the enemy's
// list that the enemies have not cast on someone yet, and that someone: the
// acting enemy first for buffs, the healthiest member for hindrances.
@(private = "file")
unmarked :: proc(enemy: u32, use: Skill_Use) -> (u8, u32) {
	for k in u32(0) ..< SKILL_COUNT {
		skill := u8(psx.lbu(enemy + ENEMY_SKILLS + k))
		if !castable(enemy, skill) || !skill_is(skill, use) || learnable_unknown(skill) {
			continue
		}
		if who := unmarked_for(skill, use); who != NOBODY {
			return skill, who
		}
	}
	return 0, NOBODY
}

@(private = "file")
unmarked_for :: proc(skill: u8, use: Skill_Use) -> u32 {
	if use == .Buff {
		actor := psx.lbu(ACTION)
		if !marked(actor, skill) {
			return actor
		}
		for id in u32(ENEMY_IDS) ..< COMBATANTS {
			if targetable(id) && !marked(id, skill) {
				return id
			}
		}
		return NOBODY
	}
	member, _ := hinder_target(skill)
	return member
}

// The front member a hindrance answers best, unmarked, and what it is worth:
// the most buff over FULL_RATE in the stat a debuff lowers, DRAGON_WORTH more
// for a dragon form, the healthiest on a tie.
@(private = "file")
hinder_target :: proc(skill: u8) -> (u32, i32) {
	slot, lowers := debuff_slot(skill)
	pick := u32(NOBODY)
	best_worth: i32
	best_hp: u32
	for member in u32(0) ..< FRONT_COUNT {
		if !targetable(member) || marked(member, skill) {
			continue
		}
		p := party_combatant(member)
		worth: i32
		if lowers {
			worth = max(i32(psx.lbu(p + PARTY_BUFFS + slot)) - FULL_RATE, 0)
		}
		if psx.lbu(p + COMBATANT_CHAR) >= DRAGON_CHAR {
			worth += DRAGON_WORTH
		}
		hp := psx.lw(p + COMBATANT_HP)
		if pick == NOBODY || worth > best_worth || worth == best_worth && hp > best_hp {
			pick, best_worth, best_hp = member, worth, hp
		}
	}
	return pick, best_worth
}

// The list hindrance worth the most on an unmarked member, and that member;
// 0 when none is worth anything (nobody buffed or in a dragon form).
@(private = "file")
answer :: proc(enemy: u32) -> (u8, u32) {
	skill, member := u8(0), u32(NOBODY)
	best: i32
	for k in u32(0) ..< SKILL_COUNT {
		s := u8(psx.lbu(enemy + ENEMY_SKILLS + k))
		if !castable(enemy, s) || !skill_is(s, .Hinder) || learnable_unknown(s) {
			continue
		}
		if who, worth := hinder_target(s); who != NOBODY && worth > best {
			skill, member, best = s, who, worth
		}
	}
	return skill, member
}

// The buff slot a debuff lowers.
@(private = "file")
debuff_slot :: proc(skill: u8) -> (u32, bool) {
	id := psx.lbu(SKILL_DATA + u32(skill) * SKILL_DATA_SIZE + SKILL_EFFECT_ID)
	return id - DEBUFF_FIRST, id >= DEBUFF_FIRST && id < DEBUFF_FIRST + DEBUFF_SLOTS
}

// A rolled buff or hindrance goes to someone who has not had it; with nobody
// left, a hindrance becomes a damage skill when the list has one, and either
// becomes a plain attack otherwise.
@(private = "file")
aim_unmarked :: proc(enemy: u32, rolled: u8, use: Skill_Use) {
	target := psx.lbu(TARGET)
	if target >= COMBATANTS || !marked(target, rolled) {
		return
	}
	if who := unmarked_for(rolled, use); who != NOBODY {
		set_action(enemy, rolled, who)
		return
	}
	if use == .Hinder {
		if other := list_skill(enemy, .Damage); other != 0 {
			use_skill(enemy, other, NOBODY)
			return
		}
	}
	attack(enemy)
}

// Make the acting enemy's action a plain attack on a member, as DECIDE
// stores one.
@(private = "file")
attack :: proc(enemy: u32) {
	psx.call(RANDOM_MEMBER)
	target := psx.cpu.r[2] & 0xff
	if target == NO_TARGET {
		return
	}
	if .Game in core.trace.active {
		core.tracef(.Game, "ai: enemy %d %v attacks %d (rolled skill %d)", psx.lbu(ACTION), ai.tier, target, psx.lhu(ACTION + 2))
	}
	psx.sb(ACTION + 1, KIND_ATTACK)
	psx.sh(ACTION + 2, 0)
	psx.sb(enemy + ENEMY_KIND, KIND_ATTACK)
	psx.sh(enemy + ENEMY_SKILL, 0)
	psx.sb(enemy + ENEMY_TARGET, target)
	psx.sb(TARGET, target)
}

// Whether the enemies gave `id` the skill this battle; a status skill only
// while `id` still has a status, a debuff only until the member is buffed
// in that stat again.
@(private = "file")
marked :: proc(id: u32, skill: u8) -> bool {
	if ai.marks[id][skill >> 6] & (1 << (skill & 63)) == 0 {
		return false
	}
	if slot, lowers := debuff_slot(skill); lowers && id < ENEMY_IDS && psx.lbu(combatant(id) + PARTY_BUFFS + slot) > FULL_RATE {
		return false
	}
	effect := psx.lbu(SKILL_DATA + u32(skill) * SKILL_DATA_SIZE + SKILL_EFFECT)
	return effect & EFFECT_STATUS == 0 || psx.lhu(combatant(id) + STATUS) != 0
}

// Mark whom the acting enemy's buff or hindrance goes to: its target, or the
// whole side for a group target.
@(private = "file")
mark_cast :: proc() {
	if psx.lbu(ACTION + 1) != KIND_SKILL {
		return
	}
	skill := u8(psx.lhu(ACTION + 2))
	buff := skill_is(skill, .Buff)
	if !buff && !skill_is(skill, .Hinder) {
		return
	}
	target := psx.lbu(TARGET)
	first, last := target, target + 1
	if target >= COMBATANTS {
		first, last = 0, ENEMY_IDS
		if buff {
			first, last = ENEMY_IDS, COMBATANTS
		}
	}
	for id in first ..< last {
		ai.marks[id][skill >> 6] |= 1 << (skill & 63)
	}
}

// The targetable enemy with the least HP for its max HP, when that is below
// low / HEAL_DEN of it; NOBODY otherwise. An actor id.
@(private = "file")
hurt_enemy :: proc(low: u32) -> u32 {
	pick := u32(NOBODY)
	best_hp, best_max: u32
	for slot in u32(0) ..< ENEMY_SLOTS {
		id := ENEMY_IDS + slot
		if !targetable(id) {
			continue
		}
		e := enemy_combatant(slot)
		hp, hp_max := psx.lw(e + COMBATANT_HP), max(psx.lw(e + COMBATANT_HP_MAX), 1)
		if u64(hp) * HEAL_DEN >= u64(hp_max) * u64(low) {
			continue
		}
		if pick == NOBODY || u64(hp) * u64(best_max) < u64(best_hp) * u64(hp_max) {
			pick, best_hp, best_max = id, hp, hp_max
		}
	}
	return pick
}

// Make the acting enemy's action `skill` on the target the game picks for
// it; a single target becomes `aim` when given and on the same side.
@(private = "file")
use_skill :: proc(enemy: u32, skill: u8, aim: u32) {
	psx.cpu.r[4] = u32(skill)
	psx.call(SKILL_TARGET)
	target := psx.cpu.r[2] & 0xff
	if target == NO_TARGET {
		return
	}
	if aim != NOBODY && target < COMBATANTS && (target >= ENEMY_IDS) == (aim >= ENEMY_IDS) {
		target = aim
	}
	set_action(enemy, skill, target)
}

// Store the acting enemy's action, as DECIDE stores a rolled one.
@(private = "file")
set_action :: proc(enemy: u32, skill: u8, target: u32) {
	if .Game in core.trace.active {
		core.tracef(.Game, "ai: enemy %d %v uses skill %d (rolled kind %d skill %d) on %d", psx.lbu(ACTION), ai.tier, skill, psx.lbu(ACTION + 1), psx.lhu(ACTION + 2), target)
	}
	psx.sb(ACTION + 1, KIND_SKILL)
	psx.sh(ACTION + 2, u32(skill))
	psx.sb(enemy + ENEMY_KIND, KIND_SKILL)
	psx.sh(enemy + ENEMY_SKILL, u32(skill))
	psx.sb(enemy + ENEMY_TARGET, target)
	psx.sb(TARGET, target)
}

@(private = "file")
random_member :: proc() {
	actor := psx.lbu(ACTION)
	if actor < ENEMY_IDS {
		ai.random_member()
		return
	}
	ai.tier = tier_of(actor - ENEMY_IDS)
	plan := plan_of(actor - ENEMY_IDS)
	if ai.tier == .Original || psx.lhu(combatant(actor) + STATUS) & CONFUSED != 0 {
		ai.random_member()
		return
	}
	c := &psx.cpu
	if ai.mood == .Enraged && targetable(ai.culprit) {
		c.r[2] = ai.culprit
		return
	}
	if plan.pick == .Random {
		ai.random_member()
		return
	}
	pick := u32(NOBODY)
	switch plan.pick {
	case .Random:
	case .Mostly:
		psx.call(RAND)
		if c.r[2] % SMART_OF < SMART_PICKS {
			pick = weakest_member(false, false)
		}
	case .Focus:
		if ai.focus < FRONT_COUNT && targetable(ai.focus) {
			pick = ai.focus
		} else {
			pick = weakest_member(false, plan.threats)
			ai.focus = pick
		}
	case .Lowest:
		pick = weakest_member(true, plan.threats)
	}
	if pick == NOBODY {
		ai.random_member()
		return
	}
	if .Game in core.trace.active {
		core.tracef(.Game, "ai: enemy %d %v targets member %d", actor, ai.tier, pick)
	}
	c.r[2] = pick
}

// The standing front member with the least HP left: for its max HP, or in
// points when `absolute` (more AP wins a tie). With `threats` a healer comes
// before a caster and a caster before the rest. NOBODY when none stands.
@(private = "file")
weakest_member :: proc(absolute, threats: bool) -> u32 {
	pick := u32(NOBODY)
	best_hp, best_max, best_ap: u32
	best_role: Role
	for member in u32(0) ..< FRONT_COUNT {
		if !targetable(member) {
			continue
		}
		p := party_combatant(member)
		hp, hp_max, ap := psx.lw(p + COMBATANT_HP), max(psx.lw(p + COMBATANT_HP_MAX), 1), psx.lw(p + COMBATANT_AP)
		r := role(p) if threats else .Other
		better: bool
		switch {
		case pick == NOBODY || r != best_role:
			better = pick == NOBODY || r > best_role
		case absolute:
			better = hp < best_hp || hp == best_hp && ap > best_ap
		case:
			// hp / hp_max < best_hp / best_max, without division.
			better = u64(hp) * u64(best_max) < u64(best_hp) * u64(hp_max)
		}
		if better {
			pick, best_hp, best_max, best_ap, best_role = member, hp, hp_max, ap, r
		}
	}
	return pick
}

@(private = "file")
Role :: enum u8 {
	Other,
	Caster, // knows a damage skill it has the AP for
	Healer, // knows a heal it has the AP for
}

// What the member at `p` can do this turn: the best of its known skills.
@(private = "file")
role :: proc(p: u32) -> Role {
	r := Role.Other
	ap := psx.lw(p + COMBATANT_AP)
	for k in u32(0) ..< KNOWN_SKILLS {
		skill := u8(psx.lbu(p + COMBATANT_SKILLS + k))
		if skill == 0 || u32(psx.lbu(SKILL_DATA + u32(skill) * SKILL_DATA_SIZE + SKILL_COST)) > ap {
			continue
		}
		if skill_is(skill, .Heal) {
			return .Healer
		}
		if skill_is(skill, .Damage) {
			r = .Caster
		}
	}
	return r
}

@(private = "file")
targetable :: proc(member: u32) -> bool {
	psx.cpu.r[4] = member
	psx.call(TARGETABLE)
	return psx.cpu.r[2] & 0xff != 0
}
