// Screen shake.
//
// Field and battle draw through one camera (rotation, translation, look-at
// in the 0x80138168 struct), turned into the GTE view matrix by VIEW_BUILD.
// The game has no shake service: each attack effect or event overlay that
// shakes the screen nudges a camera field by a fixed step, adding it on odd
// game frames and subtracting it on even ones (GAME_FRAME & 1), so the field
// swings back and forth every frame and returns to rest when the effect
// ends. Typical steps are 8 and 0x20 on the roll angle.
//
// With `screen_shake` off, VIEW_BUILD sees each camera field de-jittered: when
// a field reversed direction since the previous game frame by no more than
// the field kind's limit, the view uses the midpoint of its last two values,
// which holds still under a back-and-forth swing while steady pans pass
// through untouched. The camera RAM itself is restored after the matrix is
// built, so the game's own state and logic never see the filter.
package qol

import "core:fmt"

import cpu "ps:psx/cpu"

import "ps:core"


@(private)
Field_Kind :: enum u8 {
	Angle,    // s16, 0x1000 = 360°
	Position, // s32
	Look_At,  // s16
}

@(private)
View_Field :: struct {
	addr: u32,
	kind: Field_Kind,
}

@(private)
VIEW_FIELDS :: [?]View_Field {
	{0x8013818c, .Angle},
	{0x8013818e, .Angle},
	{0x80138190, .Angle},
	{0x80138194, .Position},
	{0x80138198, .Position},
	{0x8013819c, .Position},
	{0x801381a4, .Look_At},
	{0x801381a6, .Look_At},
	{0x801381a8, .Look_At},
}

@(private)
VIEW_FIELD_COUNT :: len(VIEW_FIELDS)

// Largest per-frame step treated as shake, by field kind; bigger reversals
// are camera cuts and pass through.
@(private = "file")
SHAKE_LIMIT := [Field_Kind]i64 {
	.Angle    = 0x40,
	.Position = 0x100,
	.Look_At  = 0x100,
}

@(private)
ANGLE_TURN :: 0x1000

@(private = "file")
shake: struct {
	view_build: cpu.Func_Proc,
	frame:      u32,
	// Each field's value at the last two game frames, and the correction the
	// current frame's view applies to it.
	last:       [VIEW_FIELD_COUNT]i64,
	before:     [VIEW_FIELD_COUNT]i64,
	offset:     [VIEW_FIELD_COUNT]i64,
	primed:     bool,
}

@(private)
shake_init :: proc() -> bool {
	original, ok := cpu.hook(VIEW_BUILD, view_build)
	if !ok {
		fmt.eprintf("qol: view builder %08x not found\n", VIEW_BUILD)
		return false
	}
	shake.view_build = original
	return true
}

@(private = "file")
view_build :: proc() {
	if config.camera_screen_shake {
		shake.primed = false
		shake.view_build()
		return
	}
	frame := cpu.lw(GAME_FRAME)
	if !shake.primed || frame != shake.frame {
		shake_step(frame)
	}
	fields := VIEW_FIELDS
	raw: [VIEW_FIELD_COUNT]u32
	for f, i in fields {
		raw[i] = field_read(f)
		if shake.offset[i] != 0 {
			field_write(f, u32(i64(i32(raw[i])) + shake.offset[i]))
		}
	}
	shake.view_build()
	for f, i in fields {
		if shake.offset[i] != 0 {
			field_write(f, raw[i])
		}
	}
}

// Take this game frame's camera values into the history and work out the
// correction each field's view gets for the frame.
@(private = "file")
shake_step :: proc(frame: u32) {
	fields := VIEW_FIELDS
	for f, i in fields {
		v := i64(i32(field_read(f)))
		shake.offset[i] = 0
		if shake.primed {
			now := field_delta(f.kind, v, shake.last[i])
			was := field_delta(f.kind, shake.last[i], shake.before[i])
			limit := SHAKE_LIMIT[f.kind]
			if now * was < 0 && abs(now) <= limit && abs(was) <= limit {
				shake.offset[i] = -now / 2
				if .Game in core.trace.active {
					core.tracef(.Game, "shake: %08x swung %d after %d, view holds midpoint", f.addr, now, was)
				}
			}
		}
		shake.before[i] = shake.primed ? shake.last[i] : v
		shake.last[i] = v
	}
	shake.frame = frame
	shake.primed = true
}

// Signed change from `from` to `to`; angles take the short way round.
@(private)
field_delta :: proc(kind: Field_Kind, to, from: i64) -> i64 {
	d := to - from
	if kind == .Angle {
		d = (d + ANGLE_TURN / 2) %% ANGLE_TURN - ANGLE_TURN / 2
	}
	return d
}

@(private)
field_read :: proc(f: View_Field) -> u32 {
	if f.kind == .Position {
		return cpu.lw(f.addr)
	}
	return cpu.lh(f.addr)
}

@(private)
field_write :: proc(f: View_Field, v: u32) {
	if f.kind == .Position {
		cpu.sw(f.addr, v)
		return
	}
	cpu.sh(f.addr, v)
}
