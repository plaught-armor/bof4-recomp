// Battle speed and minigame slow motion.
//
// Battles run with emulated time sped up relative to real time, and
// minigames slowed down (host.set_speed), so every animation, timer and sound
// effect keeps its in-game length in ticks and only passes faster or slower
// on the wall clock. Nothing assumes a presentation rate: the speed is
// applied to the console's own vblank clock.
//
// Quick turns and quick idle (quick_battle.odin) do not touch the clock:
// they cut game frames instead, so nothing on screen changes pace.
//
// A minigame is recognised by its code overlay being resident: each overlay's
// first word is its global id (see cpu.Ovl_Entry), so reading the slot says
// which one is loaded.
package qol

import cpu "ps:psx/cpu"
import host "ps:psx/host"

@(private)
GAME_MODE_FIELD :: 2
@(private)
GAME_FRAME :: 0x80116b20 // u32, counts game frames

@(private)
MODE_BATTLE :: 5

@(private = "file")
Minigame :: struct {
	slot: u32,
	id:   u32,
}

// Minigame code overlays. Fishing: loaded by the fishing-spot maps (AREAE000
// etc.), the only code reading the fish records at 0x8011b920. Sandflier hunt:
// AREAE036 (map 0x0824), whose clock byte 0x801f7c07 is the one the known
// "clock stopped" cheat freezes. Kecak: SYSTEM/COMMU09B.EMI, the Faerie
// Village games house entry that carries its own instrument bank and a rising
// u16 beat table at 0x801eb000.
@(private = "file")
MINIGAMES :: [?]Minigame {
	{0x801aa000, 24},  // fishing
	{0x801f0800, 585}, // Sandflier hunt
	{0x801aa000, 37},  // Kecak
}

// Set the speed for the current game mode; called every vblank.
@(private)
speed_follow_mode :: proc() {
	speed := 1.0
	if cpu.lhu(GAME_MODE) == MODE_BATTLE {
		speed = config.battle_speed
	} else if minigame_resident() {
		speed = config.minigame_speed
	}
	host.set_speed(speed)
}

@(private = "file")
minigame_resident :: proc() -> bool {
	games := MINIGAMES
	for g in games {
		if cpu.lw(g.slot) == g.id {
			return true
		}
	}
	return false
}
