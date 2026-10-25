// Menus that follow the mouse pointer.
//
// The game's menus draw their highlight bar with CURSOR_DRAW (a0 x, a1 y,
// a2 width, a3 height, [sp+16] the style: 0 for the list taking input,
// otherwise greyed), so the bar's rectangle says where the cursor is in
// every menu that uses it, without knowing each menu's records. When the
// pointer moves over a row above or below the bar, inside the bar's column,
// this taps Up or Down, one row at a time, until the bar is under the
// pointer. A step that does not move the bar, moves it the other way (a
// wrap) or past the pointer ends the seek, as does any button the player
// holds; the pointer must move again to start another.
//
// A Confirm press (the left button's by default) while a seek runs is held
// back and given once the bar is under the pointer, so a quick move and
// click picks the row pointed at. Battle menus draw their own cursors and do
// not follow the pointer.
//
// The pointer comes from psx.pointer_take (display pixels, the game's screen
// coordinates; recorded and replayed like pad input). Steps are counted in
// vblanks and wait for the bar to move, so they keep pace with the game at
// any frame rate.
package qol

import "../psx"

import "ps:core"

@(private = "file")
CURSOR_DRAW_ADDR :: 0x80151f54

// Bars drawn in one frame, at most.
@(private = "file")
BARS :: 8
// Pixels either side of a bar that still count as its column.
@(private = "file")
COLUMN_SLACK :: 8
// A frame older than this many vblanks has no menu on screen.
@(private = "file")
BAR_STALE :: 4
// Vblanks a step holds its direction while the bar has not moved, then
// waits released for it to move.
@(private = "file")
STEP_HOLD :: 4
@(private = "file")
STEP_WAIT :: 12
// Vblanks released between steps, so the game sees each step as a new press
// (one game frame at 30 fps).
@(private = "file")
STEP_REST :: 2
@(private = "file")
SEEK_BUTTONS :: psx.PAD_UP | psx.PAD_DOWN | psx.PAD_LEFT | psx.PAD_RIGHT | psx.PAD_CIRCLE | psx.PAD_TRIANGLE | psx.PAD_SQUARE | psx.PAD_START | psx.PAD_SELECT | psx.PAD_L1 | psx.PAD_R1 | psx.PAD_L2 | psx.PAD_R2

@(private = "file")
Bar :: struct {
	x, y, w, h: i32,
}

@(private = "file")
Bar_Set :: struct {
	bars: [BARS]Bar,
	n:    int,
	at:   u64,
}

@(private = "file")
mouse_menus: struct {
	cursor_draw: psx.Func_Proc,
	next_pad:    proc(held: u16) -> u16,
	// Active bars of the frame being drawn and of the one before.
	drawing:     Bar_Set,
	shown:       Bar_Set,
	pointer:     [2]f32,
	seeking:     bool,
	// The step under way: its direction (0 between steps), the bar it left
	// and the vblank it started (or, between steps, the vblank the bar
	// moved); the seek's direction once it has one.
	step:        u16,
	dir:         u16,
	from:        Bar,
	step_at:     u64,
	// Confirm pressed during the seek, given on arrival.
	confirm:     bool,
}

@(private)
mouse_menus_init :: proc() -> bool {
	mouse_menus.cursor_draw = psx.hook(CURSOR_DRAW_ADDR, cursor_draw) or_return
	mouse_menus.next_pad = psx.pad_hook
	psx.pad_hook = mouse_menus_pad
	return true
}

@(private = "file")
cursor_draw :: proc() {
	c := &psx.cpu
	now := psx.vblanks()
	d := &mouse_menus.drawing
	if d.at != now {
		mouse_menus.shown = d^
		d^ = {at = now}
	}
	if psx.lw(c.r[29] + 16) == 0 && d.n < BARS {
		d.bars[d.n] = {i32(i16(c.r[4])), i32(i16(c.r[5])), i32(i16(c.r[6])), i32(i16(c.r[7]))}
		d.n += 1
	}
	mouse_menus.cursor_draw()
}

// The bars of the last whole frame drawn, none when no menu is up.
@(private = "file")
last_bars :: proc() -> Bar_Set {
	now := psx.vblanks()
	m := &mouse_menus
	set := m.drawing.at < now ? m.drawing : m.shown
	if now - set.at > BAR_STALE {
		return {}
	}
	return set
}

// The bar whose column holds the pointer, nearest it vertically.
@(private = "file")
pointed_bar :: proc(set: Bar_Set, p: [2]f32) -> (bar: Bar, ok: bool) {
	set := set
	best := f32(1e9)
	for b in set.bars[:set.n] {
		if p.x < f32(b.x - COLUMN_SLACK) || p.x >= f32(b.x + b.w + COLUMN_SLACK) {
			continue
		}
		if d := abs(p.y - f32(b.y) - f32(b.h) / 2); d < best {
			best, bar, ok = d, b, true
		}
	}
	return
}

@(private = "file")
seek_end :: proc() {
	m := &mouse_menus
	if .Game in core.trace.active {
		core.tracef(.Game, "mouse menus: seek to %v ends (confirm %v)", m.pointer, m.confirm)
	}
	if m.confirm {
		psx.press_for(psx.PAD_CROSS, psx.TAP_HOLD)
	}
	m.seeking, m.step, m.confirm = false, 0, false
}

// psx.pad_hook: start a seek when the pointer moves, then step the bar
// toward it.
@(private = "file")
mouse_menus_pad :: proc(held: u16) -> u16 {
	m := &mouse_menus
	held := mouse_menus_step(held)
	return m.next_pad != nil ? m.next_pad(held) : held
}

@(private = "file")
mouse_menus_step :: proc(held: u16) -> u16 {
	m := &mouse_menus
	pos, moved := psx.pointer_take()
	if !config.mouse_menus {
		m.seeking = false
		return held
	}
	if moved {
		m.pointer = pos
		if !m.seeking {
			m.seeking, m.step, m.dir = true, 0, 0
		}
	}
	if !m.seeking {
		return held
	}
	if held & SEEK_BUTTONS != 0 {
		m.confirm = false
		seek_end()
		return held
	}
	bar, ok := pointed_bar(last_bars(), m.pointer)
	if !ok {
		seek_end()
		return held
	}
	held := held
	if held & psx.PAD_CROSS != 0 {
		m.confirm = true
		held &~= psx.PAD_CROSS
	}
	now := psx.vblanks()
	if m.step != 0 {
		if bar == m.from {
			if now - m.step_at < STEP_HOLD {
				return held | m.step
			}
			if now - m.step_at >= STEP_HOLD + STEP_WAIT {
				seek_end()
			}
			return held
		}
		// The bar moved: on to the next step unless it went the wrong way or
		// past the pointer.
		went_down := bar.y > m.from.y
		if went_down != (m.step == psx.PAD_DOWN) {
			seek_end()
			return held
		}
		m.step, m.step_at = 0, now
	}
	dir: u16
	switch y := m.pointer.y; {
	case y < f32(bar.y):
		dir = psx.PAD_UP
	case y >= f32(bar.y + bar.h):
		dir = psx.PAD_DOWN
	}
	// Arrived, or passed the pointer (it sits between two rows).
	if dir == 0 || (m.dir != 0 && dir != m.dir) {
		seek_end()
		return held
	}
	if m.dir != 0 && now - m.step_at < STEP_REST {
		return held
	}
	if .Game in core.trace.active {
		core.tracef(.Game, "mouse menus: bar %v, pointer %v, step %s", bar, m.pointer, dir == psx.PAD_UP ? "up" : "down")
	}
	m.dir, m.step, m.from, m.step_at = dir, dir, bar, now
	return held | dir
}
