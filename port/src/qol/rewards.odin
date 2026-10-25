// EXP and zenny multipliers.
//
// A won battle leaves its totals in the battle text block: EXP_TOTAL and
// ZENNY_TOTAL. BTLEND.EMI (overlay 0x35 at 0x801cc800) then runs its first
// state, BTLEND_INIT, every frame until the screen effect is idle
// (SCREEN_STATE == SCREEN_IDLE, the game's own test at 0x8013c388). That
// frame it does its work once: it halves EXP on flag 8 of 0x8011dee6, prints
// "N EXP", splits EXP_TOTAL among the standing members by level (pending
// amounts at 0x801c8390, counted into record + 0x0c), and later counts
// ZENNY_TOTAL into the party's zenny (0x8011ad80). `exp_rate` and
// `zenny_rate` scale both totals just before that frame, so the message, the
// split and the count all see the scaled amounts.
package qol

import "core:fmt"

import "../psx"

import "ps:core"

@(private = "file")
BTLEND_ID :: 0x35
@(private = "file")
BTLEND_INIT :: 0x801cca50

@(private = "file")
SCREEN_STATE :: 0x8011c99e // u8
@(private = "file")
SCREEN_IDLE :: 4

@(private = "file")
EXP_TOTAL :: 0x8011df48 // u32
@(private = "file")
ZENNY_TOTAL :: 0x8011df4c // u32
// The game's own cap on a character's EXP.
@(private = "file")
REWARD_MAX :: 9_999_999

@(private = "file")
rewards: struct {
	init: psx.Func_Proc,
}

@(private)
rewards_init :: proc() -> bool {
	original, ok := psx.hook_overlay(BTLEND_INIT, SLOT_ENGINE, BTLEND_ID, btlend_init)
	if !ok {
		fmt.eprintf("qol: battle function %08x not found\n", BTLEND_INIT)
		return false
	}
	rewards.init = original
	return true
}

@(private = "file")
btlend_init :: proc() {
	if psx.lbu(SCREEN_STATE) == SCREEN_IDLE {
		scale_reward(EXP_TOTAL, config.battle_exp_rate)
		scale_reward(ZENNY_TOTAL, config.battle_zenny_rate)
	}
	rewards.init()
}

@(private = "file")
scale_reward :: proc(addr: u32, rate: f64) {
	if rate == 1 {
		return
	}
	total := psx.lw(addr)
	scaled := u32(min(f64(total) * rate + 0.5, REWARD_MAX))
	psx.sw(addr, scaled)
	if .Game in core.trace.active {
		core.tracef(.Game, "rewards: %08x %d -> %d", addr, total, scaled)
	}
}
