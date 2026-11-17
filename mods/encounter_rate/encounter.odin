// Random encounter rate.
//
// The field overlay (FLD_MAIN.EMI, id 0x0f at 0x801cc800) calls 0x801d728c(obj)
// once per movement step of the party leader. It counts down a step budget at
// STEPS_LEFT, 1 per step when obj+0x4d bit 0 is set (walking) and 2 otherwise
// (running); at zero it sets bit 0x200 of FIELD_EVENTS and returns 1. A budget
// of 0xff makes it roll a new one.
//
// This replacement runs the game's check, then, when the check counted a step,
// redoes the count with the steps scaled by rate through a fractional carry, so
// the rate works per step and does not depend on how often frames are drawn.
// The game's own tests (encounters off, a mode change pending, not the leader,
// no encounters in this area) stay the game's. The port's own [field]
// encounter_rate replaces the game's check, so it runs inside this one and the
// two rates multiply; keep it at 1.0 with this mod.
//
// rate is a setting: the mods directory's settings.tsv sets it with a line
// `encounter_rate<TAB>rate<TAB>512`.
package encounter_rate

import "api:game"

// Steps counted per step taken, in 1/256ths: 256 is the game's rate, 0 no
// random battles, 512 twice as many.
@(export, link_section = ".mod_settings")
rate := game.Setting{128, 0, 1024, 16, "rate", "Encounter rate (256 = the game's)"}

STEPS_LEFT :: 0x801172a7 // u8
FIELD_EVENTS :: 0x801172ac // u16
BATTLE_PENDING :: 0x200

// Fractional steps carried between checks, in 1/256ths.
carry: u32

encounter_check :: proc "c" (obj: u32) -> u32 {
	before := u32(game.load(u8, STEPS_LEFT))
	events := game.load(u16, FIELD_EVENTS)
	battle := game.original(proc "c" (obj: u32) -> u32)(obj)
	// 0xff rolled a budget; 0 started a battle without a step.
	if before == 0 || before == 0xff {return battle}
	// Neither a step nor a battle: one of the game's tests said no.
	if u32(game.load(u8, STEPS_LEFT)) == before && battle == 0 {return battle}

	per_step: u32 = game.load(u8, uintptr(obj + 0x4d)) & 1 != 0 ? 1 : 2
	carry += per_step * u32(rate.value)
	taken := carry >> 8
	carry &= 0xff
	left := before - taken if before > taken else 0
	game.store(STEPS_LEFT, u8(left))
	if left != 0 {
		game.store(FIELD_EVENTS, events)
		return 0
	}
	game.store(FIELD_EVENTS, events | BATTLE_PENDING)
	return 1
}

@(export, link_section = ".mod_hooks")
hook_encounter_check := game.Hook(type_of(encounter_check)){.Replace, game.ov_801cc800_015_801d728c, encounter_check}
