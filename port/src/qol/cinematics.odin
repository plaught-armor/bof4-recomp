// Skipping skill cinematics already seen (not a game feature).
//
// A few skills (the dragon transformations) play a long cinematic, loaded
// from a companion game file beside the skill's own (MAG###_0/_1 in
// BMAGIC). Once one has played through, later casts hurry past it: from the
// companion file's load until the battle loads MAGRET (the return to the
// battle that ends every skill), emulated time runs unpaced with the sound
// muted and the picture from before the cinematic held, fading to the battle
// after. The game itself runs every frame as usual, so the battle goes on
// exactly as if the cinematic had been watched.
package qol

import "core:strconv"

import "ps:psx"

import "ps:core"

// Game files of the cinematics: MAG060_0 to MAG211_1.
@(private = "file")
FIRST_CINEMATIC :: 0x62
@(private = "file")
LAST_CINEMATIC :: 0x72
// Game file loaded after every skill, ending its cinematic.
@(private = "file")
MAGRET_FILE :: 0xf

// The config's `seen` with every cinematic.
@(private)
CINEMATICS_ALL :: (1 << (LAST_CINEMATIC - FIRST_CINEMATIC + 1)) - 1

// Longest a skip may run without reaching MAGRET (a minute at 60 a second),
// in case a cinematic ends some other way.
@(private = "file")
SKIP_LIMIT :: 3600

@(private = "file")
cinematics: struct {
	// The cinematic playing (its bit in the config's `seen`), or 0.
	playing:  int,
	// Vblanks the current skip has run; -1 while not skipping.
	skipped:  int,
	// The battle loaded MAGRET since the last vblank.
	returned: bool,
}

@(private)
cinematics_init :: proc() -> bool {
	cinematics.skipped = -1
	psx.read_start_hook = cinematics_read
	return true
}

// A read starts at lba: note a cinematic's companion file or MAGRET.
@(private = "file")
cinematics_read :: proc(lba: u32) {
	if psx.lhu(GAME_MODE) != MODE_BATTLE {
		return
	}
	if lba == psx.lw(FILE_TABLE + MAGRET_FILE * 4) {
		cinematics.returned = true
		return
	}
	if cinematics.playing != 0 {
		return
	}
	for f in u32(FIRST_CINEMATIC) ..= LAST_CINEMATIC {
		if lba == psx.lw(FILE_TABLE + f * 4) {
			cinematics.playing = 1 << (f - FIRST_CINEMATIC)
			if config.battle_skip_seen && config.battle_seen & cinematics.playing != 0 {
				cinematics.skipped = 0
			}
			return
		}
	}
}

@(private)
cinematics_vblank :: proc() {
	if cinematics.playing == 0 {
		cinematics.returned = false
		return
	}
	ended: bool = cinematics.returned || psx.lhu(GAME_MODE) != MODE_BATTLE
	cinematics.returned = false
	if cinematics.skipped >= 0 {
		cinematics.skipped += 1
		ended ||= cinematics.skipped > SKIP_LIMIT
		psx.skipping = !ended
		// Keep the picture held through the next present.
		psx.hold_picture = ended ? 0 : 1
	}
	if !ended {
		return
	}
	if .Game in core.trace.active {
		core.tracef(.Game, "cinematic %x ended, %d vblanks skipped", cinematics.playing, cinematics.skipped)
	}
	if cinematics.skipped < 0 && config.battle_seen & cinematics.playing == 0 {
		config.battle_seen |= cinematics.playing
		buf: [16]u8
		config_write({{"battle", "seen", strconv.write_int(buf[:], i64(config.battle_seen), 10)}})
	}
	cinematics.playing = 0
	cinematics.skipped = -1
}
