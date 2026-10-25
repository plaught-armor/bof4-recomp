// Damage dealt and taken multipliers.
//
// Every hit of the round (BTLMOVE.EMI, overlay 0x34 at 0x801cc800) ends in
// HP_APPLY with the hit context at HIT: the target's id (below ENEMY_IDS a
// party member, else an enemy), its combatant, and the hit record whose
// HIT_DAMAGE (s32; negative heals) HP_APPLY takes from the target's HP,
// clamped to 0..max HP. The damage number is spawned just before, from the
// same value, into the popup pool (POPUPS) at step 0. `damage_dealt` scales
// the damage to enemies and `damage_taken` the damage to the party: the hook
// scales HIT_DAMAGE, rewrites the matching popup spawned for this hit, then
// runs the game's HP_APPLY. Heals are left alone. With `[battle] balance`
// on, a hit on an enemy is also capped at BALANCE_HIT_MAX, so the
// Kaiser/Cursed Sword/Last Resort combination no longer one-shots bosses.
package qol

import "core:fmt"

import "ps:psx"

import "ps:core"

@(private = "file")
ROUND_ID :: 0x34
@(private = "file")
HP_APPLY :: 0x801d8ecc

@(private = "file")
HIT :: 0x8011e130
@(private = "file")
HIT_TARGET_ID :: 0x0 // u8
@(private = "file")
HIT_RECORD :: 0x10 // pointer
@(private = "file")
HIT_DAMAGE :: 0xc // s32, in the hit record

// Popups, 24 x 16 (popup.odin): +0 bit 0 in use, +1 step, +2 target, +8 value.
@(private = "file")
POPUPS :: 0x801caab0
@(private = "file")
POPUP_SIZE :: 16
@(private = "file")
POPUP_COUNT :: 24
@(private = "file")
POPUP_IN_USE :: 0x1
@(private = "file")
POPUP_TARGET :: 0x2
@(private = "file")
POPUP_VALUE :: 0x8

// Past what the damage number can show.
@(private = "file")
DAMAGE_MAX :: 999_999

// Largest hit on an enemy in the rebalanced mode.
@(private = "file")
BALANCE_HIT_MAX :: 9999

@(private = "file")
damage: struct {
	apply: psx.Func_Proc,
}

@(private)
damage_init :: proc() -> bool {
	original, ok := psx.hook_overlay(HP_APPLY, SLOT_ENGINE, ROUND_ID, hp_apply)
	if !ok {
		fmt.eprintf("qol: battle function %08x not found\n", HP_APPLY)
		return false
	}
	damage.apply = original
	return true
}

@(private = "file")
hp_apply :: proc() {
	target := psx.lbu(HIT + HIT_TARGET_ID)
	rate := config.battle_damage_taken if target < ENEMY_IDS else config.battle_damage_dealt
	if target < ENEMY_IDS && autoplay_party_unhurt() {
		rate = 0
	}
	record := psx.lw(HIT + HIT_RECORD)
	dealt := i32(psx.lw(record + HIT_DAMAGE))
	mood_hit(psx.lbu(ACTION), target, dealt)
	if dealt > 0 {
		rate *= timed_rate(target)
		limit := f64(DAMAGE_MAX)
		if config.battle_balance && target >= ENEMY_IDS {
			limit = BALANCE_HIT_MAX
		}
		scaled := i32(min(f64(dealt) * rate + 0.5, limit))
		if scaled == dealt {
			damage.apply()
			return
		}
		psx.sw(record + HIT_DAMAGE, u32(scaled))
		for k in u32(0) ..< POPUP_COUNT {
			p := POPUPS + k * POPUP_SIZE
			if psx.lbu(p) & POPUP_IN_USE != 0 && psx.lbu(p + POPUP_STEP) == 0 && psx.lbu(p + POPUP_TARGET) == target && i32(psx.lw(p + POPUP_VALUE)) == dealt {
				psx.sw(p + POPUP_VALUE, u32(scaled))
			}
		}
		if .Game in core.trace.active {
			core.tracef(.Game, "damage: target %d %d -> %d", target, dealt, scaled)
		}
	}
	damage.apply()
}
