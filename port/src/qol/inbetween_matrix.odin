// Smooth motion, matrix part: the in-between pass (inbetween.odin) also
// blends the GTE's rotation and translation matrices.
//
// The pose blend moves the field camera and the listed objects. Anything
// else the game places through a matrix (the battle camera, objects outside
// OBJECT_SETS) would draw where game frame N-1 put it. So every matrix write
// (control registers 32-39) a real frame's drawing makes is logged, keyed by
// the return address at the write, the register, and its occurrence among
// writes with the same address and register. The pass runs the same drawing
// code, so its writes arrive with the same keys. A value the pass writes
// unchanged from frame N-1 is replaced by the value `f` of the way from frame
// N-2's; a value the pose blend already changed is left alone, so nothing is
// blended twice.
//
// A key written a different number of times in the two frames (something
// appeared or went away) is not blended, nor is an element that changed past
// its cut limit (camera cuts). Nothing is blended while the pose blend moved
// the camera: every matrix built from it is blended already, and one that
// merely rounds to frame N-1's value would be pulled toward N-2 a second
// time, off the view the third-person camera's exact projection was made
// for (a whole-picture pop of a pixel).
package qol

import cpu "ps:psx/cpu"
import gte "ps:psx/gte"
import io "ps:psx/io"

import "ps:core"

@(private = "file")
MAX_MATRIX_WRITES :: 1024

// Largest change of a matrix element between two game frames that is
// motion. Rotation elements are 1.3.12 fixed point (0x1000 = 1.0); the
// translation is in view units.
@(private = "file")
ROTATION_CUT_LIMIT :: 0x800
@(private = "file")
TRANSLATION_CUT_LIMIT :: 0x4000

// Slots of a log's index: a power of two, at least twice the keys it holds
// (each write adds one occurrence key and at most one count key).
@(private = "file")
LOG_SLOTS :: 4 * MAX_MATRIX_WRITES

// An occurrence key's k for the key counting a return address and
// register's writes.
@(private = "file")
COUNT_KEY :: 0xffff

@(private = "file")
Log_Slot :: struct {
	key:   u64,
	value: i32,
	// The slot holds a key while it matches its log's stamp.
	stamp: u32,
}

@(private = "file")
Matrix_Log :: struct {
	count:    int,
	// More writes than fit; the log can not be matched.
	overflow: bool,
	value:    [MAX_MATRIX_WRITES]u32,
	// Open-addressed index: (ra, reg, k) to the k'th such write's position
	// in value, and (ra, reg, COUNT_KEY) to the number of such writes.
	slots:    [LOG_SLOTS]Log_Slot,
	stamp:    u32,
}

@(private = "file")
Matrix_Mode :: enum {
	Off,
	Record, // a real frame's drawing: log into cur
	Blend, // the pass: log into pass, blend
}

// logs: the writes of each frame note's drawing (inbetween.odin's notes,
// same slots); rec the one a real frame's drawing logs into, prev and cur
// the ones the pass blends between (game frames N-2 and N-1).
@(private = "file")
gte_log: struct {
	mode:           Matrix_Mode,
	f:              f64,
	blended:        int,
	rec:            int,
	prev, cur:      int,
	logs:           [NOTES]Matrix_Log,
	pass:           Matrix_Log,
}

@(private)
matrix_init :: proc() {
	gte.gte_matrix_filter = matrix_filter
}

// A real frame's drawing starts: its writes go to note `slot`'s log.
@(private)
matrix_record_begin :: proc(slot: int) {
	gte_log.rec = slot
	log_reset(&gte_log.logs[slot])
	gte_log.mode = .Record
}

// The pass's drawing starts, at blend factor f between the drawings of notes
// `prev` and `cur`; `camera_moved`: the pose blend moved the camera, and
// nothing is blended.
@(private)
matrix_blend_begin :: proc(f: f64, prev, cur: int, camera_moved: bool) {
	if camera_moved {
		gte_log.mode = .Off
		return
	}
	gte_log.prev, gte_log.cur = prev, cur
	log_reset(&gte_log.pass)
	gte_log.blended = 0
	gte_log.f = f
	gte_log.mode = .Blend
}

// A drawing (real or the pass's) has finished its scene render.
@(private)
matrix_end :: proc() {
	if gte_log.mode == .Blend && .Game in core.trace.active {
		core.tracef(.Game, "inbetween: %d of %d matrix writes blended", gte_log.blended, gte_log.pass.count)
	}
	gte_log.mode = .Off
}

@(private = "file")
matrix_filter :: proc(r, v: u32) -> u32 {
	if gte_log.mode == .Off || io.events_frozen != (gte_log.mode == .Blend) {
		return v
	}
	ra := cpu.state.r[31]
	if gte_log.mode == .Record {
		log_append(&gte_log.logs[gte_log.rec], ra, r, v)
		return v
	}
	k := log_count(&gte_log.pass, ra, r)
	log_append(&gte_log.pass, ra, r, v)
	prev, cur := &gte_log.logs[gte_log.prev], &gte_log.logs[gte_log.cur]
	if prev.overflow || cur.overflow || log_count(prev, ra, r) != log_count(cur, ra, r) {
		return v
	}
	i, j := log_find(cur, ra, r, k), log_find(prev, ra, r, k)
	if i < 0 || j < 0 || cur.value[i] != v {
		return v
	}
	out := value_blend(r, prev.value[j], v, 1 - gte_log.f)
	if out != v {
		gte_log.blended += 1
	}
	return out
}

@(private = "file")
log_reset :: proc(log: ^Matrix_Log) {
	log.count = 0
	log.overflow = false
	log.stamp += 1
	if log.stamp == 0 {
		log.slots = {}
		log.stamp = 1
	}
}

@(private = "file")
log_key :: #force_inline proc(ra, r: u32, k: int) -> u64 {
	return u64(ra) << 32 | u64(r) << 16 | u64(k)
}

// The slot holding `key`, or the empty slot where it would go.
@(private = "file")
log_slot :: proc(log: ^Matrix_Log, key: u64) -> ^Log_Slot {
	h := key * 0x9e3779b97f4a7c15
	i := int(h >> 32) & (LOG_SLOTS - 1)
	for {
		s := &log.slots[i]
		if s.stamp != log.stamp || s.key == key {
			return s
		}
		i = (i + 1) & (LOG_SLOTS - 1)
	}
}

@(private = "file")
log_append :: proc(log: ^Matrix_Log, ra, r, v: u32) {
	if log.count == MAX_MATRIX_WRITES {
		log.overflow = true
		return
	}
	c := log_slot(log, log_key(ra, r, COUNT_KEY))
	if c.stamp != log.stamp {
		c^ = {key = log_key(ra, r, COUNT_KEY), stamp = log.stamp}
	}
	o := log_slot(log, log_key(ra, r, int(c.value)))
	o^ = {key = log_key(ra, r, int(c.value)), value = i32(log.count), stamp = log.stamp}
	c.value += 1
	log.value[log.count] = v
	log.count += 1
}

// Number of writes logged with this return address and register.
@(private = "file")
log_count :: proc(log: ^Matrix_Log, ra, r: u32) -> int {
	c := log_slot(log, log_key(ra, r, COUNT_KEY))
	return c.stamp == log.stamp ? int(c.value) : 0
}

// Index of the k'th write with this return address and register; -1 when
// there is none.
@(private = "file")
log_find :: proc(log: ^Matrix_Log, ra, r: u32, k: int) -> int {
	if k >= COUNT_KEY {
		return -1
	}
	o := log_slot(log, log_key(ra, r, k))
	return o.stamp == log.stamp ? int(o.value) : -1
}

// Move register r's value `to` back toward `from` by `back`: two 16-bit
// rotation elements per register for 32-36, one 32-bit translation for
// 37-39. An element past its cut limit leaves the whole value at `to`.
@(private = "file")
value_blend :: proc(r, from, to: u32, back: f64) -> u32 {
	if r >= 37 {
		d := i64(i32(to)) - i64(i32(from))
		if abs(d) > TRANSLATION_CUT_LIMIT {
			return to
		}
		return u32(i32(i64(i32(to)) - i64(f64(d) * back)))
	}
	out: u32
	for shift in ([2]u32{0, 16}) {
		a, b := i64(i16(from >> shift)), i64(i16(to >> shift))
		if abs(b - a) > ROTATION_CUT_LIMIT {
			return to
		}
		out |= (u32(i16(b - i64(f64(b - a) * back))) & 0xffff) << shift
	}
	return out
}
