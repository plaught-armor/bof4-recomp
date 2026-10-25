// Reliable enemy-skill learning.
//
// Whenever a combatant uses a skill, the round (BTLMOVE.EMI, overlay 0x34 at
// 0x801cc800) calls LEARN_CHECK(skill). A skill whose LEARN_LEVEL is 0 cannot
// be learned. Otherwise each party member guarding this round rolls once, in
// party order, and the first to pass learns it:
//
//   part   = min(GAUGE * 100 / GAUGE_MAX, 25) (GAUGE was 0 in every battle
//            seen; GAUGE_MAX holds max AP)
//   chance = (part + 75 if BOOST_STATE == 4 + LEARN_STAT + 100) * 100
//            / LEARN_DIVISORS[level - 1, -1 more at GAUGE >= max/4, -1 more
//              at GAUGE >= max/2, not below 0]
//   learned when rand() % 10000 < chance
//
// Learning goes through SKILL_ADD(record, skill, 1), which puts the skill in
// the first empty one of the record's 8 learned-skill slots (record + 0x2e)
// and sets its bit in SKILL_BITS (the party's learned skills, reassigned at
// camp). It fails when the party already knows the skill, and also when all
// slots are full: the skill is then lost without a word. The learner and skill
// go to the battle text (LEARN_TEXT, flag LEARN_SHOW) for "X learned: Skill!".
//
// With `sure_learn`, LEARN_CHECK runs natively and Guard is not needed: seeing
// a learnable skill teaches it. The learner is the first standing member
// guarding this round, else the first standing member. It still draws one
// rand() as the game does, and learns through SKILL_ADD(record, skill, 0),
// which with every slot full sets the skill's bit alone: the message shows and
// the skill waits at camp.
package qol

import "core:fmt"

import "ps:psx"

import "ps:core"

@(private = "file")
ROUND_ID :: 0x34
@(private = "file")
LEARN_CHECK :: 0x801d8208 // a0 = skill; v0 = 0 not learnable, 1 learned, 255 not
@(private = "file")
SKILL_ADD :: 0x80194da8 // a0 = record, a1 = skill, a2 = 1 slot only / 0 slot or bit; v0 < 0 failed
@(private = "file")
WINDOW_OPEN :: 0x801ba2b4 // a0 = 3, a1 = 4: the learn message's window; v0 = its slot

// SKILL_DATA, 12 bytes per skill id; low nibble of byte 2 = learn level
// (1 easiest .. 8 hardest), 0 = cannot be learned.
@(private = "file")
SKILL_DATA_SIZE :: 12
@(private = "file")
LEARN_LEVEL :: 2

@(private = "file")
PARTY_COUNT :: 3
@(private = "file")
COMBATANT_FLAGS :: 0x0 // bit 0 active
@(private = "file")
COMBATANT_ACTIVE :: 0x1
@(private = "file")
COMBATANT_RECORD :: 0x9c
@(private = "file")
COMBATANT_CHAR :: 0xa4 // u8, record + 0x08: character id
@(private = "file")
COMBATANT_GAUGE :: 0xb8 // u16
@(private = "file")
COMBATANT_GAUGE_MAX :: 0xd8 // u32, max AP
@(private = "file")
COMBATANT_LEARN_STAT :: 0xf2 // u8
@(private = "file")
COMBATANT_BOOST_STATE :: 0x120 // u8
@(private = "file")
BOOST_ON :: 4
// The boost counts only for the playable characters.
@(private = "file")
CHAR_COUNT :: 7
@(private = "file")
COMBATANT_COMMAND :: 0x139 // u8, this round's command
@(private = "file")
COMMAND_GUARD :: 2

// Per learn level - 1, from the round overlay's data at 0x801cc834.
@(private = "file")
LEARN_DIVISORS := [8]i32{1, 2, 4, 8, 12, 16, 32, 64}
@(private = "file")
ROLL :: 10000
@(private = "file")
GAUGE_PART_MAX :: 25
@(private = "file")
BOOST :: 75

// The battle message's learner and skill; its show flag.
@(private = "file")
LEARN_TEXT :: 0x8011df30
@(private = "file")
LEARN_SKILL :: 0x18a // u8
@(private = "file")
LEARN_MEMBER :: 0x18b // u8
@(private = "file")
BATTLE_FLAGS :: 0x8011deec // u32
@(private = "file")
LEARN_SHOW :: 0x0800_0000
// Windows, 0x9c each; the learn message's names its learner at +8.
@(private = "file")
WINDOWS :: 0x801c83a8
@(private = "file")
WINDOW_SIZE :: 0x9c
@(private = "file")
WINDOW_MEMBER :: 0x8

@(private = "file")
learning: struct {
	check: psx.Func_Proc,
}

@(private)
learning_init :: proc() -> bool {
	original, ok := psx.hook_overlay(LEARN_CHECK, SLOT_ENGINE, ROUND_ID, learn_check)
	if !ok {
		fmt.eprintf("qol: battle function %08x not found\n", LEARN_CHECK)
		return false
	}
	learning.check = original
	return true
}

@(private = "file")
learn_check :: proc() {
	if !config.battle_sure_learn {
		learning.check()
		return
	}
	c := &psx.cpu
	skill := c.r[4] & 0xff
	level := psx.lbu(SKILL_DATA + skill * SKILL_DATA_SIZE + LEARN_LEVEL) & 0xf
	if level == 0 {
		c.r[2] = 0
		return
	}
	// The learner: a standing member, one guarding this round first.
	learner, found := u32(0), false
	for member in u32(0) ..< PARTY_COUNT {
		p := party_combatant(member)
		if psx.lbu(p + COMBATANT_FLAGS) & COMBATANT_ACTIVE == 0 || psx.lhu(p + COMBATANT_HP) == 0 {
			continue
		}
		if !found || psx.lbu(p + COMBATANT_COMMAND) == COMMAND_GUARD {
			learner, found = member, true
		}
		if psx.lbu(p + COMBATANT_COMMAND) == COMMAND_GUARD {
			break
		}
	}
	if !found {
		c.r[2] = 255
		return
	}
	ra := c.r[31]
	defer c.r[31] = ra
	p := party_combatant(learner)
	gauge, gauge_max := psx.lhu(p + COMBATANT_GAUGE), psx.lw(p + COMBATANT_GAUGE_MAX)
	chance := i32(min(gauge * 100 / max(gauge_max, 1), GAUGE_PART_MAX))
	if psx.lbu(p + COMBATANT_BOOST_STATE) == BOOST_ON && psx.lbu(p + COMBATANT_CHAR) < CHAR_COUNT {
		chance += BOOST
	}
	chance = (chance + i32(psx.lbu(p + COMBATANT_LEARN_STAT)) + 100) * 100
	index := i32(level) - 1
	if gauge >= gauge_max >> 2 {
		index -= 1
	}
	if gauge >= gauge_max >> 1 {
		index -= 1
	}
	chance /= LEARN_DIVISORS[clamp(index, 0, len(LEARN_DIVISORS) - 1)]
	psx.call(RAND)
	rolled := i32(c.r[2]) % ROLL < chance
	// Fails only when the party knows the skill already.
	c.r[4] = p + COMBATANT_RECORD
	c.r[5] = skill
	c.r[6] = 0
	psx.call(SKILL_ADD)
	if i8(c.r[2]) < 0 {
		c.r[2] = 255
		return
	}
	if .Game in core.trace.active {
		core.tracef(.Game, "learn: member %d skill %02x, chance %d/%d %v", learner, skill, chance, ROLL, rolled)
	}
	c.r[4], c.r[5] = 3, 4
	psx.call(WINDOW_OPEN)
	psx.sb(WINDOWS + (c.r[2] & 0xff) * WINDOW_SIZE + WINDOW_MEMBER, learner)
	psx.sb(LEARN_TEXT + LEARN_MEMBER, learner)
	psx.sb(LEARN_TEXT + LEARN_SKILL, skill)
	psx.sw(BATTLE_FLAGS, psx.lw(BATTLE_FLAGS) | LEARN_SHOW)
	c.r[2] = 1
}
