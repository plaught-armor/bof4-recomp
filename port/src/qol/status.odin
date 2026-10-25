// Chance of the party's status effects landing on enemies.
//
// Status skills, death and the other effects with a resist roll (BTLMOVE.EMI,
// overlay 0x34 at 0x801cc800) ask RESIST_CHECK(kind, grade), which returns
// nonzero when the effect misses. The chance in percent is
//
//   min(CASTER_STAT/5 + 50, 100) * max(75 - TARGET_STAT/5, 25) / 100
//   * LEVEL_RATE[the grade's level] * LEVEL_RATE[the target's level] / 10000
//
// (kind 4 takes the target's rate from DEATH_RATE). A level of 0 or less
// always lands; 6 and up (5 for kind 4) never does. The roll lands when
// RAND % 100 is below the chance. Bosses sit at the high levels, which is
// why debuffs on them almost never work. With `status_rate` the hook runs
// the same check with the chance scaled when a party member targets an
// enemy; the immune levels stay immune.
//
// BOF4_CHEAT=hp also makes the party status-proof: every resist roll on a
// party member misses (death included), and STATUS_SET (the bits the status
// command lands, no-roll ones too) gives a party member none.
package qol

import "core:fmt"

import "ps:psx"

import "ps:core"

@(private = "file")
ROUND_ID :: 0x34
@(private = "file")
RESIST_CHECK :: 0x801d378c
@(private = "file")
STATUS_SET :: 0x801da4f4 // (bits u16) on TARGET, less its accessories' blocks

@(private = "file")
TARGET :: 0x8011e130 // u8, as ACTION
@(private = "file")
CASTER_STAT :: 0x8011e0e4 // u16
@(private = "file")
TARGET_STAT :: 0x8011e154 // u16
@(private = "file")
GRADE_LEVELS :: 0x8011e156 // s8 per grade
@(private = "file")
TARGET_LEVELS :: 0x8011e15a // s8 per kind
@(private = "file")
LEVEL_RATE :: 0x801e4fb8 // s16 percent per level
@(private = "file")
DEATH_RATE :: 0x801e4fc8 // s16 percent per level, kind 4
@(private = "file")
DEATH :: 4
@(private = "file")
IMMUNE :: 6
@(private = "file")
DEATH_IMMUNE :: 5

@(private = "file")
status: struct {
	check: psx.Func_Proc,
	set:   psx.Func_Proc,
}

@(private)
status_init :: proc() -> bool {
	original, ok := psx.hook_overlay(RESIST_CHECK, SLOT_ENGINE, ROUND_ID, resist_check)
	if !ok {
		fmt.eprintf("qol: battle function %08x not found\n", RESIST_CHECK)
		return false
	}
	status.check = original
	original, ok = psx.hook_overlay(STATUS_SET, SLOT_ENGINE, ROUND_ID, status_set)
	if !ok {
		fmt.eprintf("qol: battle function %08x not found\n", STATUS_SET)
		return false
	}
	status.set = original
	return true
}

@(private = "file")
resist_check :: proc() {
	if psx.lbu(TARGET) < ENEMY_IDS && autoplay_party_unhurt() {
		if .Game in core.trace.active {
			core.tracef(.Game, "status: kind %d on party slot %d misses", psx.cpu.r[4] & 0xff, psx.lbu(TARGET))
		}
		psx.cpu.r[2] = 1
		return
	}
	if config.battle_status_rate == 1 || psx.lbu(ACTION) >= ENEMY_IDS || psx.lbu(TARGET) < ENEMY_IDS {
		status.check()
		return
	}
	c := &psx.cpu
	kind, grade := c.r[4] & 0xff, c.r[5] & 0xff
	attack := min(i32(psx.lhu(CASTER_STAT) / 5) + 50, 100)
	defense := max(75 - i32(psx.lhu(TARGET_STAT) / 5), 25)
	level := i32(i8(psx.lbu(TARGET_LEVELS + kind)))
	grade_level := i32(i8(psx.lbu(GRADE_LEVELS + grade)))
	// The target's level is looked at first, as the game does.
	switch {
	case level <= 0:
		c.r[2] = 0
		return
	case level >= (DEATH_IMMUNE if kind == DEATH else IMMUNE):
		c.r[2] = 1
		return
	case grade_level <= 0:
		c.r[2] = 0
		return
	case grade_level >= IMMUNE:
		c.r[2] = 1
		return
	}
	target_rate := u32(DEATH_RATE if kind == DEATH else LEVEL_RATE)
	chance := i32(i16(psx.lhu(LEVEL_RATE + u32(grade_level) * 2))) * (attack * defense / 100)
	chance = chance * i32(i16(psx.lhu(target_rate + u32(level) * 2))) / 10000
	scaled := i32(f64(chance) * config.battle_status_rate + 0.5)
	psx.call(RAND)
	roll := i32(c.r[2]) % 100
	c.r[2] = 1 if roll >= scaled else 0
	if .Game in core.trace.active {
		core.tracef(.Game, "status: kind %d target %d chance %d -> %d roll %d %s", kind, psx.lbu(TARGET), chance, scaled, roll, "miss" if c.r[2] != 0 else "lands")
	}
}

@(private = "file")
status_set :: proc() {
	if psx.lbu(TARGET) < ENEMY_IDS && autoplay_party_unhurt() {
		if .Game in core.trace.active {
			core.tracef(.Game, "status: bits %04x on party slot %d blocked", psx.cpu.r[4] & 0xffff, psx.lbu(TARGET))
		}
		psx.cpu.r[4] = 0
	}
	status.set()
}
