// Smooth motion: an extra, in-between picture for every repeated display
// frame on field maps and in battle.
//
// Field logic runs once per two or three vblanks, so the display shows each
// picture more than once. The main loop draws game frame N-1's ordering
// table (DrawOTagEnv, returning to MAIN_DRAW_RET) right after putting frame
// N-2 on screen. Every frame's drawing is noted as it starts (a ring of
// NOTES: registers, draw state, object poses, the GTE matrix log), and the
// send queues frame N-1's in-between pictures. A frozen-time pass
// (psx.checkpoint_save) loads memory as frame N-1's drawing found it, moves
// the camera and every active object part of the way back toward their
// frame N-2 pose, and runs the frame's drawing again: the field draw and the
// scene render, then the main loop's frame end and the same DrawOTagEnv. The
// picture is copied as an extra frame and the machine is restored; present
// shows the extras in place of frame N-2's repeats. The game's logic, RNG
// and RAM never see the pass.
//
// The blend factor comes from the vblanks between the two game frames, not a
// fixed rate: with P vblanks per game frame one pass runs for each of the
// P-1 repeats, the k'th drawing the picture k/P of the way from frame N-2 to
// N-1. A field that moved further than its cut limit snaps to the new pose
// (map changes, warps, camera cuts).
//
// When the passes run: the game draws frame N right after the send, and that
// drawing takes a vblank or more of emulated time, so a repeat that falls
// inside it cannot run its pass then (the hooks are mid-frame). The send
// draws the pictures of as many repeats as the longest of the last few
// frames' drawings spanned; each later picture is drawn at its own repeat's
// present, once the drawing has ended. Drawing all P-1 at the send puts every pass in one
// vblank on top of the heaviest one, which stalls real time long enough to
// starve a low-latency sound queue. A frame whose drawing runs longer than
// predicted shows its last unpredicted repeat as the picture before it: with
// the prediction from the frame before alone, a field alternating between
// two and three vblanks of drawing froze a picture every other frame.
//
// Prims the frame commits after the scene render (fades from the event
// thread, screen effects of the main loop) are not drawn again: the real
// frame's commits (LAYER_ADD) between the scene render and the frame end are
// noted with their final contents, and the pass commits copies of them
// after its own scene render, unblended.
//
// Battle draws the same way from its own per-frame body: the pass starts at
// the battle's background layer draw (BATTLE_DRAW) instead of the field draw,
// and the battle's combatant and effect pools are listed in OBJECT_SETS like
// field objects, so the same pose blend moves them.
//
// Which callers draw a frame is read from the game's code, not listed: every
// frame body (field, event, battle and the other overlays' variants) calls
// the first draw and then, in the very next instruction, the scene render.
// A first-draw call whose return address holds `jal SCENE_DRAW` is a frame;
// any other caller (a lone map redraw) is not.
//
// Matrices the game loads into the GTE during the drawing are blended too
// (inbetween_matrix.odin), which moves what the pose blend does not list:
// the battle camera, unlisted objects.
//
// Other screens (menus) get tween.odin's screen-space prim blend instead.
package qol

import "core:fmt"
import "core:math"
import "core:slice"

import "../psx"

// Background layer list draw (16 slots at 0x80116c00); the battle frame's
// first drawing call.
@(private = "file")
BATTLE_DRAW :: 0x801401b8
@(private = "file")
LAYER_ADD :: 0x8013ae34 // a0 = layer 0..5, a1 = bytes: commit the prim at SPRITE_PACKETS
@(private = "file")
PRIM_POOL_SIZE :: 0x9000
@(private = "file")
OBJECT_SET :: 0x80116fad // u8, index into OBJECT_SETS
@(private = "file")
OBJECT_SETS :: 0x801744f8 // pointers to {base, stride, count} lists, base 0 ends
@(private = "file")
OBJECT_POS :: 0x0c // object offset of the world position, 3 x s32
@(private = "file")
OBJECT_ACTIVE :: 0x02 // object byte 0 flag

@(private = "file")
MAX_OBJECTS :: 256
@(private = "file")
MAX_GROUPS :: 32
// Longest game frame, in vblanks, that still gets an in-between picture.
@(private = "file")
MAX_PERIOD :: 4
// Frames whose drawing spans the send's prediction looks back over: a field
// whose drawing takes two vblanks one frame and three the next (a town
// doorway with its room picture) must draw for three every frame.
@(private = "file")
SPAN_HISTORY :: 8
#assert(MAX_PERIOD - 1 <= psx.EXTRA_FRAMES)
@(private = "file")
MAX_LATE :: 512
@(private = "file")
PARTY_SIZE :: 0xfc
@(private = "file")
PARTY_COUNT :: 3

// Largest change between two game frames that is motion; anything bigger
// is a cut and the extra picture shows the new value. Measured per game
// frame: L1 turn yaw 0x60 at rotate_speed 1 (0x300 at the maximum 8, and the
// stick at 720 deg/s is 0x111), look-at 0x28 walking, camera position fixed.
// Field objects step 0x2000 walking, 0x2800 on the world map, 0x4000
// dashing; battle combatants 0x11333 running to a target.
@(private = "file")
CUT_LIMIT := [Field_Kind]i64 {
	.Angle    = 0x400,
	.Position = 0x2000,
	.Look_At  = 0x200,
}
@(private = "file")
FIELD_OBJECT_CUT_LIMIT :: 0x10000
@(private = "file")
BATTLE_OBJECT_CUT_LIMIT :: 0x40000

@(private = "file")
Pose :: struct {
	camera: [VIEW_FIELD_COUNT]i64,
	count:  int,
	addr:   [MAX_OBJECTS]u32,
	pos:    [MAX_OBJECTS][3]i32,
	vblank: u64,
	// Object cut limit of the screen the pose was drawn on.
	cut:    i64,
	tp:     Tp_Blend,
	// The window kept the picture from before over this frame's (a
	// crossing's set-up), so it is no start for a blend.
	held:   bool,
	// The machine switched to another map's world before this frame
	// (interiors.odin world_enter), so it is no end for a blend either.
	cut_in: bool,
}

// Prims committed between the scene render and the frame end of a frame's
// drawing, in commit order.
@(private = "file")
Late :: struct {
	recording: bool,
	// Complete and usable for the pass.
	ready:     bool,
	overflow:  bool,
	count:     int,
	layer:     [MAX_LATE]u32,
	addr:      [MAX_LATE]u32,
	size:      [MAX_LATE]u32,
	bytes:     [PRIM_POOL_SIZE]u8,
}

// One real frame's drawing, as the passes replay it: memory and registers
// at its first draw call (field or battle), the original function to run
// again, the return address of its scene render, its pose and late prims.
// Its GTE matrix writes are in inbetween_matrix.odin's log of the same slot.
@(private = "file")
Frame_Note :: struct {
	draw_start: ^psx.Draw_Start,
	regs:       psx.Cpu,
	draw:       psx.Func_Proc,
	scene_ret:  u32,
	pose:       Pose,
	late:       Late,
}

// Frame notes kept: the two game frames the queued pictures blend between,
// and the one the game draws meanwhile.
@(private)
NOTES :: 3

@(private = "file")
inbetween: struct {
	field_draw:    psx.Func_Proc,
	battle_draw:   psx.Func_Proc,
	draw_otag_env: psx.Func_Proc,
	checkpoint:    ^psx.Checkpoint,
	notes:         [NOTES]Frame_Note,
	// The note of the frame drawn last (or being drawn).
	noting:        int,
	// That frame's drawing is under way: from its first draw call to its
	// frame end.
	drawing:       bool,
	// A field frame was drawn and its ordering table is not yet sent.
	armed:         bool,
	// The pictures queued at the last frame's send: the note they replay,
	// the registers at its DrawOTagEnv call (which the passes repeat), the
	// vblanks between it and the frame before, the vblank it was sent at,
	// and the next picture to draw (1 .. period-1; 0 none queued).
	queued:        int,
	otag_regs:     psx.Cpu,
	period:        u64,
	sent_at:       u64,
	next:          u64,
	// Pictures of the queue drawn so far.
	captured:      int,
	// Vblanks from a send to the end of the next frame's drawing, for the
	// last few frames (span_at counts them).
	draw_spans:    [SPAN_HISTORY]u64,
	span_at:       int,
	scene_draw:    psx.Func_Proc,
	layer_add:     psx.Func_Proc,
	frame_end:     psx.Func_Proc,
	world_cut:     bool,
	// The queued frame is the first of a world entered through a door: it
	// blends from cut_pose, the town's last step carried on (cut_from).
	cut:           bool,
	cut_pose:      Pose,
}

// While a pass draws: third_person.odin's camera state blended like the
// pose.
@(private)
inbetween_tp: Tp_Blend

// While a pass draws: how far back toward the older pose it draws (0 the
// newer pose, 1 the older), for objects kept outside RAM (sections.odin's
// neighbour people).
@(private)
inbetween_back: f64

// While a pass draws: the vblank count its pose stands at, blended like
// the pose (interiors.odin door_cover fades by it).
@(private)
inbetween_vblank: f64

// While a pass draws: what each camera field of the blended pose holds past
// the whole value written to RAM, for the exact view (third_person.odin).
@(private)
inbetween_frac: [VIEW_FIELD_COUNT]f64

// The machine switched to another map's world (interiors.odin
// world_enter): the passes left for the frame before are of the old world,
// and the next frame noted is a cut.
@(private)
inbetween_world_switch :: proc() {
	inbetween.next = 0
	inbetween.world_cut = true
}

// True while a pass draws an in-between picture (not a door's room).
@(private)
inbetween_replaying: bool

@(private)
inbetween_init :: proc() -> bool {
	if !config.window_smooth_motion {
		return true
	}
	original_draw, ok := hook_field(FIELD_DRAW, field_draw)
	if !ok {
		return false
	}
	original_send, hooked := psx.hook(DRAW_OTAG_ENV, draw_otag_env)
	if !hooked {
		fmt.eprintf("qol: DrawOTagEnv %08x not found\n", DRAW_OTAG_ENV)
		return false
	}
	cp, cp_err := new(psx.Checkpoint)
	if cp_err != nil {
		fmt.eprintln("qol: smooth motion: out of memory", cp_err)
		return false
	}
	for &n in inbetween.notes {
		ds, ds_err := new(psx.Draw_Start)
		if ds_err != nil {
			fmt.eprintln("qol: smooth motion: out of memory", ds_err)
			return false
		}
		n.draw_start = ds
	}
	original_battle, found := psx.hook(BATTLE_DRAW, battle_draw)
	if !found {
		fmt.eprintf("qol: battle draw %08x not found\n", BATTLE_DRAW)
		return false
	}
	psx.present_hook = inbetween_present
	inbetween.field_draw = original_draw
	inbetween.battle_draw = original_battle
	inbetween.draw_otag_env = original_send
	inbetween.checkpoint = cp
	matrix_init()
	return late_init()
}

@(private = "file")
late_init :: proc() -> bool {
	ok: [3]bool
	inbetween.scene_draw, ok[0] = psx.hook(SCENE_DRAW, scene_draw)
	inbetween.layer_add, ok[1] = psx.hook(LAYER_ADD, layer_add)
	inbetween.frame_end, ok[2] = psx.hook(FRAME_END, frame_end)
	if ok != {true, true, true} {
		fmt.eprintf("qol: smooth motion: draw functions not found %v\n", ok)
		return false
	}
	return true
}

// Scene render hook: start noting the frame's later commits.
@(private = "file")
scene_draw :: proc() {
	note := &inbetween.notes[inbetween.noting]
	real := inbetween.armed && psx.cpu.r[31] == note.scene_ret && !psx.events_frozen
	inbetween.scene_draw()
	if real {
		matrix_end()
		late := &note.late
		late.recording = true
		late.ready = false
		late.overflow = false
		late.count = 0
	}
}

@(private = "file")
layer_add :: proc() {
	late := &inbetween.notes[inbetween.noting].late
	if !late.recording || psx.events_frozen {
		inbetween.layer_add()
		return
	}
	addr := psx.lw(SPRITE_PACKETS)
	layer, size := psx.cpu.r[4] & 0xff, psx.cpu.r[5] & 0xff
	inbetween.layer_add()
	if psx.lw(SPRITE_PACKETS) == addr {
		return // pool full: the game dropped the prim too
	}
	if late.count == MAX_LATE {
		late.overflow = true
		return
	}
	late.layer[late.count] = layer
	late.addr[late.count] = addr
	late.size[late.count] = size
	late.count += 1
}

// Frame end hook: take the noted prims' final contents.
@(private = "file")
frame_end :: proc() {
	late := &inbetween.notes[inbetween.noting].late
	if late.recording && !psx.events_frozen && psx.cpu.r[31] == FRAME_END_RET {
		late.recording = false
		late_copy(late)
	}
	if !psx.events_frozen && psx.cpu.r[31] == FRAME_END_RET && inbetween.drawing {
		inbetween.drawing = false
		inbetween.draw_spans[inbetween.span_at % len(inbetween.draw_spans)] = psx.vblanks() - inbetween.sent_at
		inbetween.span_at += 1
	}
	inbetween.frame_end()
}

@(private = "file")
late_copy :: proc(late: ^Late) {
	used := 0
	for i in 0 ..< late.count {
		n := int(late.size[i])
		if used + n > PRIM_POOL_SIZE {
			late.overflow = true
			break
		}
		for k in 0 ..< n {
			late.bytes[used + k] = u8(psx.lbu(late.addr[i] + u32(k)))
		}
		used += n
	}
	late.ready = !late.overflow
	if late.overflow && .Qol in psx.trace.active {
		psx.tracef(.Qol, "inbetween: more than %d late prims, frame not smoothed", MAX_LATE)
	}
}

// Commit copies of the noted late prims into the pass's frame.
@(private = "file")
late_replay :: proc(late: ^Late) {
	used := u32(0)
	for i in 0 ..< late.count {
		addr := psx.lw(SPRITE_PACKETS)
		for k in 0 ..< late.size[i] {
			psx.sb(addr + k, u32(late.bytes[used + k]))
		}
		used += late.size[i]
		psx.cpu.r[4], psx.cpu.r[5] = late.layer[i], late.size[i]
		inbetween.layer_add()
		if psx.lw(SPRITE_PACKETS) == addr && .Qol in psx.trace.active {
			psx.tracef(.Qol, "inbetween: prim pool full, %d late prims left out", late.count - i)
			return
		}
	}
}

// Field draw hook: note the frame's pose and memory, then draw as usual.
@(private = "file")
field_draw :: proc() {
	if frame_draw_call() {
		draw_note(inbetween.field_draw, psx.cpu.r[31] + 8, FIELD_OBJECT_CUT_LIMIT)
	}
	inbetween.field_draw()
}

// Battle background draw hook: the same for the battle frame.
@(private = "file")
battle_draw :: proc() {
	if frame_draw_call() {
		draw_note(inbetween.battle_draw, psx.cpu.r[31] + 8, BATTLE_OBJECT_CUT_LIMIT)
	}
	inbetween.battle_draw()
}

// Whether the first draw call being entered is a frame body's: outside a
// pass, and the scene render is the caller's next instruction.
@(private = "file")
frame_draw_call :: proc() -> bool {
	return !psx.events_frozen && psx.lw(psx.cpu.r[31]) == JAL_SCENE_DRAW
}

// Note the pose, memory and registers at the frame's first draw call, which
// the pass runs again through `draw`; its scene render returns to scene_ret.
// Objects moving further than `cut` in a game frame snap.
@(private = "file")
draw_note :: proc(draw: psx.Func_Proc, scene_ret: u32, cut: i64) {
	inbetween.noting = (inbetween.noting + 1) % NOTES
	if inbetween.next != 0 && inbetween.noting == (inbetween.queued + NOTES - 1) % NOTES {
		// Two frames drawn since the queue: its older note is reused.
		inbetween.next = 0
	}
	note := &inbetween.notes[inbetween.noting]
	pose_record(&note.pose)
	note.pose.cut = cut
	psx.draw_start_save(note.draw_start)
	note.regs = psx.cpu
	note.draw = draw
	note.scene_ret = scene_ret
	note.late.ready = false
	inbetween.armed = true
	inbetween.drawing = true
	matrix_record_begin(inbetween.noting)
}

// DrawOTagEnv hook: queue the in-between pictures of the frame noted by
// field_draw as the main loop sends it.
@(private = "file")
draw_otag_env :: proc() {
	if psx.cpu.r[31] == MAIN_DRAW_RET && !psx.events_frozen {
		tween_record(psx.cpu.r[4])
	}
	if inbetween.armed && psx.cpu.r[31] == MAIN_DRAW_RET {
		inbetween.armed = false
		queue_inbetween()
	} else if psx.cpu.r[31] == MAIN_DRAW_RET && !psx.events_frozen {
		tween_draw(inbetween.draw_otag_env, inbetween.checkpoint)
	}
	inbetween.draw_otag_env()
}

@(private = "file")
queue_inbetween :: proc() {
	// The frame's matrices are all loaded; the game code that runs before
	// the passes (the next frame's logic) must not add to them.
	matrix_end()
	inbetween.next = 0
	inbetween.sent_at = psx.vblanks()
	q := inbetween.noting
	prev, cur := &inbetween.notes[(q + NOTES - 1) % NOTES].pose, &inbetween.notes[q].pose
	period := cur.vblank - prev.vblank
	inbetween.cut = cur.cut_in
	if cur.cut_in && !cut_from(prev, &inbetween.notes[(q + NOTES - 2) % NOTES].pose, cur) {
		return
	}
	if prev.vblank == 0 || prev.held || period < 2 || period > MAX_PERIOD || !inbetween.notes[q].late.ready {
		return
	}
	inbetween.queued = q
	inbetween.otag_regs = psx.cpu
	inbetween.period = period
	inbetween.captured = 0
	sections_pass_note()
	// The next frame's drawing takes a vblank or more of emulated time, and
	// the repeats that fall inside it (as many as the longest of the last
	// few frames' drawings covered) get their pictures now.
	now := clamp(slice.max(inbetween.draw_spans[:]), 2, period) - 1
	for step in 1 ..= now {
		if inbetween_pass(f64(step) / f64(period), inbetween.captured) {
			inbetween.captured += 1
		}
	}
	inbetween.next = now + 1
}

// Present hook: draw the later extra pictures of the queue, each just before
// the present that shows it, while the game goes on to its next frame.
// Drawing them all as the frame was sent made that vblank carry three
// pictures' work and the next ones none, long enough in a town at 2x detail
// to starve the sound queue.
//
// Only a present that repeats the frame on screen shows a picture (the one
// right after the send shows the new frame), and none is drawn while the
// next frame's drawing is under way, which a pass must not cut into: the
// picture is left out, and the repeat shows the one before.
@(private = "file")
inbetween_present :: proc() {
	if inbetween.next == 0 || psx.events_frozen || inbetween.drawing || !psx.display_repeats() {
		return
	}
	step := psx.vblanks() - inbetween.sent_at
	if step < inbetween.next {
		return
	}
	if step >= inbetween.period {
		inbetween.next = 0
		return
	}
	inbetween.next = step + 1
	if inbetween_pass(f64(step) / f64(inbetween.period), inbetween.captured) {
		inbetween.captured += 1
	}
}

// Draw the queued frame's picture `f` of the way from the game frame before
// it, as extra picture `index`. False when the GPU is busy. The pass draws
// the hi-res target alone (psx.hi_only_begin); one that turns out to read
// VRAM it left undrawn is drawn again with both.
@(private = "file")
inbetween_pass :: proc(f: f64, index: int) -> bool {
	ok, missed := inbetween_draw(f, index, true)
	if !missed {
		return ok
	}
	if .Qol in psx.trace.active {
		psx.tracef(.Qol, "inbetween: pass read VRAM it did not draw, drawn again in full")
	}
	ok, _ = inbetween_draw(f, index, false)
	return ok
}

@(private = "file")
inbetween_draw :: proc(f: f64, index: int, hi_only: bool) -> (ok, missed: bool) {
	main := inbetween.otag_regs
	q := inbetween.queued
	note, prev := &inbetween.notes[q], &inbetween.notes[(q + NOTES - 1) % NOTES]
	if !psx.checkpoint_save(inbetween.checkpoint) {
		if .Qol in psx.trace.active {
			psx.tracef(.Qol, "inbetween: GPU busy, frame skipped")
		}
		return false, false
	}
	defer psx.checkpoint_restore(inbetween.checkpoint)
	// Ends before the restore (defers run last first).
	hi := hi_only && psx.hi_only_begin()
	defer if hi {
		missed = psx.hi_only_end()
	}
	inbetween_replaying = true
	defer inbetween_replaying = false
	psx.draw_start_load(note.draw_start)
	// A cut's frame before is another world's: its matrices are no start.
	if inbetween.cut {
		pose_blend(&inbetween.cut_pose, &note.pose, f)
		psx.cpu = note.regs
		matrix_blend_begin(f, q, q, false)
	} else {
		camera_moved := pose_blend(&prev.pose, &note.pose, f)
		psx.cpu = note.regs
		matrix_blend_begin(f, (q + NOTES - 1) % NOTES, q, camera_moved)
	}
	note.draw()
	psx.cpu.r[29] = note.regs.r[29]
	game_call(SCENE_DRAW, note.scene_ret)
	matrix_end()
	late_replay(&note.late)
	psx.cpu = main
	game_call(FRAME_END, FRAME_END_RET)
	doors_between_draw()
	psx.cpu = main
	inbetween.draw_otag_env()
	env := main.r[5]
	psx.capture_extra_frame(i32(i16(psx.lh(env))), i32(i16(psx.lh(env + 2))), index)
	ok = true
	return
}

// The pose a world's first frame (cur) blends from, a door's walk in: the
// town's last step (before to last) carried on back from cur, the camera's
// and the party's (the same objects in both worlds); the room's other
// objects stand. False when the town's frames give no step.
@(private = "file")
cut_from :: proc(last, before, cur: ^Pose) -> bool {
	step := last.vblank - before.vblank
	if before.vblank == 0 || before.held || last.held || last.cut_in || step < 2 || step > MAX_PERIOD {
		return false
	}
	p := &inbetween.cut_pose
	p^ = cur^
	p.vblank = last.vblank
	p.cut_in = false
	fields := VIEW_FIELDS
	for fl, i in fields {
		p.camera[i] = cur.camera[i] - field_delta(fl.kind, last.camera[i], before.camera[i])
	}
	p.tp = {
		t        = cur.tp.t - (last.tp.t - before.tp.t),
		arm      = cur.tp.arm - (last.tp.arm - before.tp.arm),
		distance = cur.tp.distance - (last.tp.distance - before.tp.distance),
		yaw      = cur.tp.yaw - (last.tp.yaw - before.tp.yaw),
	}
	p.count = 0
	for i in 0 ..< cur.count {
		obj := cur.addr[i]
		if obj < PARTY_OBJ || obj >= PARTY_OBJ + PARTY_SIZE * PARTY_COUNT {
			continue
		}
		a, b := pose_find(last, obj, i), pose_find(before, obj, i)
		if a < 0 || b < 0 {
			continue
		}
		p.addr[p.count] = obj
		p.pos[p.count] = cur.pos[i] - (last.pos[a] - before.pos[b])
		p.count += 1
	}
	return true
}

// Note the camera and every active object's position, and the time.
@(private = "file")
pose_record :: proc(p: ^Pose) {
	fields := VIEW_FIELDS
	for f, i in fields {
		p.camera[i] = i64(i32(field_read(f)))
	}
	p.count = 0
	p.vblank = psx.vblanks()
	p.held = psx.hold_picture > 0
	p.cut_in = inbetween.world_cut
	inbetween.world_cut = false
	p.tp = third_person_state()
	list := psx.lw(OBJECT_SETS + psx.lbu(OBJECT_SET) * 4)
	for _ in 0 ..< MAX_GROUPS {
		base := psx.lw(list)
		if base == 0 {
			return
		}
		stride, count := psx.lw(list + 4), i32(psx.lw(list + 8))
		for k in 0 ..< max(count, 0) {
			obj := base + u32(k) * stride
			if psx.lbu(obj) & OBJECT_ACTIVE == 0 {
				continue
			}
			if p.count == MAX_OBJECTS {
				return
			}
			p.addr[p.count] = obj
			for axis in 0 ..< 3 {
				p.pos[p.count][axis] = i32(psx.lw(obj + OBJECT_POS + u32(axis) * 4))
			}
			p.count += 1
		}
		list += 12
	}
}

// Write the pose `f` of the way from prev to cur into RAM: v = cur - (cur -
// prev) * (1 - f). Fields that moved past their cut limit keep cur's value.
// True when the camera (its fields or the third-person state) was blended.
@(private = "file")
pose_blend :: proc(prev, cur: ^Pose, f: f64) -> (camera_moved: bool) {
	back := 1 - f
	inbetween_back = back
	inbetween_vblank = f64(cur.vblank) - (f64(cur.vblank) - f64(prev.vblank)) * back
	fields := VIEW_FIELDS
	snapped := 0
	for fl, i in fields {
		d := field_delta(fl.kind, cur.camera[i], prev.camera[i])
		inbetween_frac[i] = 0
		if abs(d) > CUT_LIMIT[fl.kind] {
			snapped += 1
			continue
		}
		camera_moved ||= d != 0
		v := f64(cur.camera[i]) - f64(d) * back
		whole := math.round(v)
		field_write(fl, u32(i64(whole)))
		inbetween_frac[i] = v - whole
	}
	a, b := prev.tp, cur.tp
	camera_moved ||= a != b
	inbetween_tp = {
		t        = b.t - (b.t - a.t) * back,
		arm      = b.arm - (b.arm - a.arm) * back,
		distance = b.distance - (b.distance - a.distance) * back,
		yaw      = b.yaw - (b.yaw - a.yaw) * back,
	}
	moved := 0
	for i in 0 ..< cur.count {
		j := pose_find(prev, cur.addr[i], i)
		if j < 0 {
			continue
		}
		moved += object_blend(cur.addr[i], prev.pos[j], cur.pos[i], back, cur.cut) ? 1 : 0
	}
	if .Qol in psx.trace.active {
		psx.tracef(.Qol, "inbetween: f %.2f, %d of %d objects moved, %d camera fields snapped", f, moved, cur.count, snapped)
	}
	return
}

// Index of obj in p, trying `hint` first; -1 when absent.
@(private = "file")
pose_find :: proc(p: ^Pose, obj: u32, hint: int) -> int {
	if hint < p.count && p.addr[hint] == obj {
		return hint
	}
	for k in 0 ..< p.count {
		if p.addr[k] == obj {
			return k
		}
	}
	return -1
}

// Move obj back toward `from`; returns whether it moved. Objects that jumped
// past `cut` stay where they are.
@(private = "file")
object_blend :: proc(obj: u32, from, to: [3]i32, back: f64, cut: i64) -> bool {
	d: [3]i64
	for axis in 0 ..< 3 {
		d[axis] = i64(to[axis]) - i64(from[axis])
		if abs(d[axis]) > cut {
			if .Qol in psx.trace.active {
				psx.tracef(.Qol, "inbetween: object %08x jumped %v, snapped", obj, d)
			}
			return false
		}
	}
	if d == {} {
		return false
	}
	for axis in 0 ..< 3 {
		v := i64(to[axis]) - i64(f64(d[axis]) * back)
		psx.sw(obj + OBJECT_POS + u32(axis) * 4, u32(i32(v)))
	}
	return true
}
