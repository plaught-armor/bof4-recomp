// Guard that pays: a member who guarded a round regains AP.
//
// Guard sets bit 0 of the combatant's u16 at +0x134 (GUARD_FLAGS) as the
// round starts. The physical damage formula (0x801d3b58, round overlay)
// halves the hit on a guarding target 15 times in 16 and cuts it by a
// quarter otherwise; another formula (0x801deda8) gives a guarding target
// +10. With `sure_learn` Guard is no longer needed to learn enemy skills,
// so `guard_ap` gives it a second use: ROUND_END (0x801d24e0) clears the
// flags, and each standing member whose guard bit it cleared regains a
// fifth of its max AP, rounded up.
package qol

import "core:fmt"

import "../psx"

@(private = "file")
ROUND_ID :: 0x34
@(private = "file")
ROUND_END :: 0x801d24e0 // clears every combatant's command and GUARD_FLAGS

@(private = "file")
PARTY_COUNT :: 3
@(private = "file")
COMBATANT_AP :: 0xb4 // u32
@(private = "file")
COMBATANT_AP_MAX :: 0xd8 // u32
@(private = "file")
GUARD_FLAGS :: 0x134 // u16
@(private = "file")
GUARDING :: 0x1
// AP regained per guarded round, as a divisor of max AP.
@(private = "file")
GUARD_AP_PART :: 5

@(private = "file")
guard: struct {
	round_end: psx.Func_Proc,
}

@(private)
guard_init :: proc() -> bool {
	original, ok := psx.hook_overlay(ROUND_END, SLOT_ENGINE, ROUND_ID, round_end)
	if !ok {
		fmt.eprintf("qol: battle function %08x not found\n", ROUND_END)
		return false
	}
	guard.round_end = original
	return true
}

@(private = "file")
round_end :: proc() {
	if !config.battle_guard_ap {
		guard.round_end()
		return
	}
	guarding: [PARTY_COUNT]bool
	for member in u32(0) ..< PARTY_COUNT {
		guarding[member] = psx.lhu(party_combatant(member) + GUARD_FLAGS) & GUARDING != 0
	}
	guard.round_end()
	for member in u32(0) ..< PARTY_COUNT {
		p := party_combatant(member)
		if !guarding[member] || psx.lhu(p + GUARD_FLAGS) & GUARDING != 0 || psx.lw(p + COMBATANT_HP) == 0 {
			continue
		}
		ap, ap_max := psx.lw(p + COMBATANT_AP), psx.lw(p + COMBATANT_AP_MAX)
		gained := min(ap + (ap_max + GUARD_AP_PART - 1) / GUARD_AP_PART, ap_max)
		psx.sw(p + COMBATANT_AP, max(ap, gained))
		if .Qol in psx.trace.active {
			psx.tracef(.Qol, "guard: member %d AP %d -> %d of %d", member, ap, max(ap, gained), ap_max)
		}
	}
}
