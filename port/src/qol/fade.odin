// Screen fades: longer and eased.
//
// The game mode overlay fades the whole screen with one rectangle drawn over
// it (FADE_DRAW: a 320x240 0x62 prim, subtractive for black, additive for
// white) whose grey level is the fade's progress. FADE_STEP runs once a game
// frame for a fade in progress: it draws the level from an s16 counter
// (counter >> 7, so 0x7fff is 0xff) and adds the fade's speed to it, done once
// the counter would leave 0..0x7fff. Speeds are fixed per caller, from 0x2000
// (four frames, 0.13 s) to 0x100; the map change and most event fades use
// 0x1000 or 0x2000, which reads as a cut more than a fade.
//
// Here no fade runs faster than FADE_SPEED_MAX, and the level eases in and
// out (smoothstep) instead of moving linearly, so the picture starts and
// ends its change slowly. Slower fades lengthen the waits the game spends in
// them; scripts wait for a fade to end, so events stay in step.
package qol

import cpu "ps:psx/cpu"

@(private = "file")
FADE_STEP :: 0x8018f524 // a0 = ^s16 counter, a1 = speed, a2 = layer, a3 = blend; v0 1 when done
@(private = "file")
FADE_DRAW :: 0x8018f474 // a0 = level 0..0xff, a1 = layer, a2 = blend
// FADE_WAIT (0x8018f5ac: a0 = s16 speed, above 0 to black, else from it;
// a1 = blend) runs a fade to its end, waiting a frame between steps: the map
// change's fade out. Its call of FADE_STEP returns here.
@(private = "file")
FADE_WAIT_STEP_RET :: 0x8018f5f8
// Largest counter step per game frame: sixteen frames, about half a second.
@(private = "file")
FADE_SPEED_MAX :: 0x800

// Vblanks a drawn level stays the screen's fade: through the loading a
// fade to black ends in, the screen stays black without a fade drawn.
@(private = "file")
FADE_FRESH :: 30

@(private = "file")
fade: struct {
	step, draw: cpu.Func_Proc,
	// The last level drawn (0..1, eased) and the vblank it was drawn at.
	level:      f32,
	at:         u64,
	// FADE_WAIT's stack as its last step found it, 0 none.
	wait_sp:    u32,
}

// The stack frame of FADE_WAIT, which steps a fade to its end a frame at a
// time: s16 counter at +16, the registers it keeps from +24.
@(private)
FADE_FRAME :: 40

// FADE_WAIT's stack frame, as its last step found it, 0 none.
@(private)
fade_frame :: proc() -> u32 {
	return fade.wait_sp
}

// How far the screen is faded, 0 (clear) to 1, for host drawing over it.
@(private)
screen_fade :: proc() -> f32 {
	if cpu.vblanks() - fade.at > FADE_FRESH {
		return 0
	}
	return fade.level
}

@(private)
fade_init :: proc() -> bool {
	fade.step = hook_game_mode(FADE_STEP, fade_step) or_return
	fade.draw = hook_game_mode(FADE_DRAW, fade_draw) or_return
	return true
}

@(private = "file")
fade_step :: proc() {
	c := &cpu.state
	speed := i32(i16(c.r[5]))
	if c.r[31] == FADE_WAIT_STEP_RET {
		fade.wait_sp = c.r[29]
	}
	c.r[5] = u32(clamp(speed, -FADE_SPEED_MAX, FADE_SPEED_MAX))
	fade.step()
	if c.r[2] == 1 && door_dark_hold() {
		c.r[2] = 0
	}
}

@(private = "file")
fade_draw :: proc() {
	c := &cpu.state
	t := f32(c.r[4] & 0xff) / 0xff
	fade.level = t * t * (3 - 2 * t)
	fade.at = cpu.vblanks()
	c.r[4] = u32(0xff * fade.level + 0.5)
	fade.draw()
}
