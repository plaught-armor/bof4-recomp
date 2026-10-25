// KO max-HP loss.
//
// A member still KO'd when a battle ends gets up with 1 HP and one more KO
// mark (KO_MARKS, at most 5), and the game takes a tenth of the base max HP
// (BASE_HP_MAX) per mark off the effective max HP (RECORD_HP_MAX); only an inn
// clears the marks. The marks are bumped in four places (BTLEND.EMI's battle
// end, the battle overlay's own end and mid-battle revive, and a round action
// that costs max HP), and every one of them ends in RECOMPUTE, which rebuilds
// the stats of the 6 party slots (PARTY_SLOTS) from their base stats and
// marks. `ko_hp_loss`:
//
//   inn   as the game
//   camp  as the game, and the camp menu clears the marks too, giving back
//         the max HP they took (HP stays as it is)
//   off   the hook clears the marks before every recompute, so max HP stays
//         whole and what was lost comes back at the next one
package qol

import "core:fmt"

import cpu "ps:psx/cpu"

import "ps:core"

@(private)
Ko_Hp_Loss :: enum u8 {
	Inn,
	Camp,
	Off,
}

// As bof4.ini and the Extras menu name the modes.
@(private)
KO_HP_LOSS_KEYS := [Ko_Hp_Loss]string {
	.Inn  = "inn",
	.Camp = "camp",
	.Off  = "off",
}
@(private)
KO_HP_LOSS_TEXT := [Ko_Hp_Loss]string {
	.Inn  = "Inn",
	.Camp = "Camp",
	.Off  = "Off",
}

@(private = "file")
RECOMPUTE_ID :: 0x0e

@(private = "file")
BASE_HP_MAX :: 0x5c // u32
@(private = "file")
KO_MARKS :: 0x83 // u8
@(private = "file")
MARK_SHARE :: 10 // a mark takes BASE_HP_MAX / MARK_SHARE

@(private = "file")
ko_loss: struct {
	recompute: cpu.Func_Proc,
}

@(private)
ko_loss_init :: proc() -> bool {
	original, ok := cpu.hook_overlay(RECOMPUTE, SLOT_GAME, RECOMPUTE_ID, recompute)
	if !ok {
		fmt.eprintf("qol: stats function %08x not found\n", RECOMPUTE)
		return false
	}
	ko_loss.recompute = original
	return true
}

@(private = "file")
recompute :: proc() {
	if config.battle_ko_hp_loss == .Off {
		clear_marks(false)
	}
	ko_loss.recompute()
}

// Each tick of the camp menu (camp_menu.odin).
@(private)
ko_loss_camp :: proc() {
	if config.battle_ko_hp_loss == .Camp {
		clear_marks(true)
	}
}

// Clear the party's marks; with `give_back`, add the max HP they took back
// to the effective max HP, as the next recompute would.
@(private = "file")
clear_marks :: proc(give_back: bool) {
	for k in u32(0) ..< PARTY_SLOT_COUNT {
		index := cpu.lbu(PARTY_SLOTS + k)
		if index == EMPTY_SLOT {
			continue
		}
		record := char_record(index)
		marks := cpu.lbu(record + KO_MARKS)
		if marks == 0 {
			continue
		}
		cpu.sb(record + KO_MARKS, 0)
		if give_back {
			cpu.sw(record + RECORD_HP_MAX, cpu.lw(record + RECORD_HP_MAX) + cpu.lw(record + BASE_HP_MAX) / MARK_SHARE * marks)
		}
		if .Game in core.trace.active {
			core.tracef(.Game, "ko_loss: character %d marks %d cleared, max HP %d", index, marks, cpu.lw(record + RECORD_HP_MAX))
		}
	}
}
