// Threaded drawing of the hi-res target (not a PS1 feature).
//
// During an ordering-table walk, draws are queued per target, and
// raster_sync draws the queues on several threads: the hi-res target's on
// threads each owning interleaved bands of its rows, VRAM's on one more
// thread at the same time. Each pixel still sees its draws in order, so the
// picture is the same as drawing them one by one.
//
// With the hi-res target on the GPU (gl_target.odin), VRAM's draws are
// drawn as they are queued instead, by the stream's threads, each owning
// interleaved bands of VRAM's rows, while the walk goes on; raster_sync
// waits for them. A draw texturing from VRAM a draw before it in the stream
// wrote (another band's rows, maybe) first waits for the stream to empty.
//
// Queued hi-res draws read their textures from VRAM while VRAM's draws run,
// so a VRAM draw over texels a queued hi-res draw reads, or a hi-res draw
// reading texels a queued VRAM draw writes, first draws the queues
// (raster_queue). Anything else touching VRAM, the hi-res target, their
// ghost layers or the walk's state the draws hold syncs first too.
package psx

import "base:intrinsics"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"


@(private)
Draw_Kind :: enum u8 {
	Triangle,
	Rect,
	Line,
	// Lay VRAM's ghost layer over it (gpu_ghost_flush, on the stream).
	Ghost,
}

// A queued draw: its state when issued and its shape.
@(private)
Draw :: struct {
	kind:  Draw_Kind,
	env:   Plot_Env,
	m:     Prim_Mode,
	using shape: struct #raw_union {
		tri:  Tri,
		line: [2]Vertex,
		rect: struct {
			x, y, w, h, r, g, b, u, v: i32,
		},
		// The layer's box the walk side knew of (ghosts merged at syncs).
		ghost: struct {
			lo, hi: [2]i32,
		},
	},
}

MAX_BANDS :: 8

// Draws the stream holds at once.
@(private)
STREAM_N :: 1024

// The stream's threads; each owns every STREAM_BANDS-th band of 8 rows, so
// the count divides VRAM's 64 bands and a wrapped row keeps its owner.
@(private)
STREAM_BANDS :: 4
#assert(VRAM_H / 8 % STREAM_BANDS == 0)

// One stream thread's side: the next draw it takes (tail), its pass, and
// whether it sleeps on `wake`; a cache line of its own.
@(private)
Stream_Band :: struct #align (64) {
	tail: i64,
	idle: bool,
	wake: sync.Sema,
	ra:   Raster,
}

// VRAM's queue while the hi-res target is on the GPU: a ring the walk fills
// (head) and every stream thread draws its rows of (its tail).
@(private)
stream: struct {
	ring:    [STREAM_N]Draw,
	head:    i64,
	// The head the last raster_run waited for (walk side only).
	synced:  i64,
	// VRAM cells drawn since the stream was last empty (walk side only).
	writes:  Cells,
	started: bool,
	bands:   [STREAM_BANDS]Stream_Band,
}

Sync_Cause :: enum u8 {
	Other,
	Hi_Raw,
	Vram_War,
	Vram_Raw,
	Full,
	Walk_End,
	Ghost,
}
sync_cause: Sync_Cause
sync_t: [Sync_Cause]time.Duration
sync_n: [Sync_Cause]int

sync_perf :: proc() {
	tracef(.Perf, "stream waits: %v %v", sync_n, sync_t)
	sync_t, sync_n = {}, {}
}

@(private)
raster: struct {
	on:      bool,
	// The hi-res target's queue and VRAM's.
	draws:   [dynamic]Draw,
	native:  [dynamic]Draw,
	// VRAM cells the queued hi-res draws read textures and CLUTs from, and
	// those the queued VRAM draws write.
	reads:   Cells,
	writes:  Cells,
	// One per band, then VRAM's.
	passes:  [MAX_BANDS + 1]Raster,
	// The thread pool: `bands` workers and the caller; a job runs on
	// `bands` of them (one per band) or, drawing the queues, bands + 1.
	bands:   i32,
	started: bool,
	go:      sync.Sema,
	done:    sync.Wait_Group,
	next:    i32,
	job:     proc(band, bands: i32, data: rawptr),
	data:    rawptr,
}

// VRAM in 8x8 cells, a row of cells per u128: bit x / 8 of row y / 8. Fine
// enough that CLUT rows and texture pages beside the draw buffers do not
// share a cell with them.
@(private)
Cells :: [VRAM_H / 8]u128

// The cells of one row under VRAM columns x ..< x + w (wrapping).
@(private)
cell_span :: proc(x, w: i32) -> u128 {
	if w > VRAM_W - 8 {
		return ~u128(0)
	}
	a := u32(x & (VRAM_W - 1)) >> 3
	b := u32((x + w - 1) & (VRAM_W - 1)) >> 3
	from_a := ~u128(0) << a
	to_b := ~u128(0) >> (127 - b)
	return a <= b ? from_a & to_b : from_a | to_b
}

// Whether c has any cell under the area x, y, w x h (wrapping as VRAM does).
@(private)
cells_hit :: proc(c: ^Cells, x, y, w, h: i32) -> bool {
	span := cell_span(x, w)
	rows := h > VRAM_H - 8 ? i32(len(c)) : ((y + h - 1) >> 3) - (y >> 3) + 1
	for i in 0 ..< rows {
		if c[((y >> 3) + i) & (len(c) - 1)] & span != 0 {
			return true
		}
	}
	return false
}

// The rows of cells (bit y / 8) under VRAM rows y ..< y + h (wrapping).
@(private)
cell_rows :: proc(y, h: i32) -> u64 {
	#assert(len(Cells) == 64)
	if h > VRAM_H - 8 {
		return ~u64(0)
	}
	a := u32(y & (VRAM_H - 1)) >> 3
	b := u32((y + h - 1) & (VRAM_H - 1)) >> 3
	from_a := ~u64(0) << a
	to_b := ~u64(0) >> (63 - b)
	return a <= b ? from_a & to_b : from_a | to_b
}

// Add the cells under the area x, y, w x h to c.
@(private)
cells_add :: proc(c: ^Cells, x, y, w, h: i32) #no_bounds_check {
	span := cell_span(x, w)
	rows := h > VRAM_H - 8 ? i32(len(c)) : ((y + h - 1) >> 3) - (y >> 3) + 1
	for i in 0 ..< rows {
		c[((y >> 3) + i) & (len(c) - 1)] |= span
	}
}

// The VRAM tiles under the area x, y, w x h (wrapping as VRAM does).
@(private)
vram_tiles :: proc(x, y, w, h: i32) -> u128 {
	mask: u128
	for ty in y >> 6 ..= (y + h - 1) >> 6 {
		for tx in x >> 6 ..= (x + w - 1) >> 6 {
			mask |= 1 << u32((ty & 7) * 16 + (tx & 15))
		}
	}
	return mask
}

// Whether a textured draw under st reads any cell of c, and with add, add
// the cells it reads to c.
@(private)
texture_cells :: proc(c: ^Cells, st: ^Draw_State, m: ^Prim_Mode, add := false) -> bool {
	w := i32(64) << min(st.tp, 2)
	clut_w := st.tp == 0 ? i32(16) : 256
	if add {
		cells_add(c, st.tex_x, st.tex_y, w, 256)
		if st.tp < 2 {
			cells_add(c, m.clut_x, m.clut_y, clut_w, 1)
		}
		return false
	}
	return cells_hit(c, st.tex_x, st.tex_y, w, 256) || st.tp < 2 && cells_hit(c, m.clut_x, m.clut_y, clut_w, 1)
}

// Start queuing the hi-res target's draws, for a walk.
@(private)
raster_begin :: proc() {
	raster.on = target_count == 2
}

// Run job(band, bands, data) for every band at once, on the pool.
@(private)
raster_parallel :: proc(job: proc(band, bands: i32, data: rawptr), data: rawptr) {
	raster_launch(job, data, raster_pool())
}

// The pool's band count, starting the pool on first use.
@(private)
raster_pool :: proc() -> i32 {
	if !raster.started {
		raster.started = true
		raster.bands = i32(clamp(os.get_processor_core_count() / 2, 1, MAX_BANDS))
		for _ in 0 ..< raster.bands {
			thread.start(thread.create(raster_worker))
		}
	}
	return raster.bands
}

// Run job(i, bands, data) for i in 0 ..< n (at most bands + 1) at once.
@(private)
raster_launch :: proc(job: proc(band, bands: i32, data: rawptr), data: rawptr, n: i32) {
	if preload_child {
		// A forked child has no pool threads: run the jobs in turn.
		for i in 0 ..< n {
			job(i, raster.bands, data)
		}
		return
	}
	raster.job, raster.data = job, data
	raster.next = 1
	sync.wait_group_add(&raster.done, int(n - 1))
	sync.sema_post(&raster.go, int(n - 1))
	job(0, raster.bands, data)
	sync.wait_group_wait(&raster.done)
}

@(private)
raster_end :: proc() {
	sync_cause = .Walk_End
	raster_sync()
	sync_cause = .Other
	raster.on = false
}

// Queue d for target t; a VRAM draw over pixels x0..=x1, y0..=y1. Draw the
// queues first when d and a queued draw of the other target would race on
// VRAM's texels.
@(private)
raster_queue :: proc(t: ^Target, d: ^Draw, x0, y0, x1, y1: i32) {
	if t.shift > 0 {
		if d.m.textured {
			if texture_cells(&raster.writes, &d.env.st, &d.m) {
				sync_cause = .Hi_Raw
				raster_sync()
				sync_cause = .Other
			}
			texture_cells(&raster.reads, &d.env.st, &d.m, add = true)
			if hi_only.on && !hi_only.missed && texture_cells(&hi_only.cells, &d.env.st, &d.m) {
				hi_only.missed = true
			}
		}
		if t.gl {
			gl_queue(t, d)
			return
		}
		append(&raster.draws, d^)
		return
	}
	if cells_hit(&raster.reads, x0, y0, x1 - x0 + 1, y1 - y0 + 1) {
		sync_cause = .Vram_War
		raster_sync()
		sync_cause = .Other
	}
	cells_add(&raster.writes, x0, y0, x1 - x0 + 1, y1 - y0 + 1)
	if targets[1].gl && !preload_child {
		if d.m.textured && texture_cells(&stream.writes, &d.env.st, &d.m) {
			sync_cause = .Vram_Raw
			stream_drain()
			sync_cause = .Other
		}
		cells_add(&stream.writes, x0, y0, x1 - x0 + 1, y1 - y0 + 1)
		stream_push(d)
		return
	}
	append(&raster.native, d^)
}

// Hand d to the stream's threads, starting them on first use.
@(private)
stream_push :: proc(d: ^Draw) {
	if !stream.started {
		stream.started = true
		for &sb, i in stream.bands {
			sb.ra = raster_make(&targets[0], nil, i32(i), STREAM_BANDS)
			th := thread.create(stream_worker)
			th.user_index = i
			thread.start(th)
		}
	}
	h := stream.head
	if h - stream_tail() == STREAM_N {
		t0 := time.tick_now()
		for spin := 0; h - stream_tail() == STREAM_N; spin += 1 {
			stream_pause(spin)
		}
		sync_t[.Full] += time.tick_since(t0)
		sync_n[.Full] += 1
	}
	stream.ring[h % STREAM_N] = d^
	sync.atomic_store(&stream.head, h + 1)
	for &sb in stream.bands {
		if sync.atomic_load(&sb.idle) {
			if _, ok := sync.atomic_compare_exchange_strong(&sb.idle, true, false); ok {
				sync.sema_post(&sb.wake)
			}
		}
	}
}

// The tail of the stream thread furthest behind: draws before it are done.
@(private)
stream_tail :: #force_inline proc() -> i64 {
	t := sync.atomic_load_explicit(&stream.bands[0].tail, .Acquire)
	for &sb in stream.bands[1:] {
		t = min(t, sync.atomic_load_explicit(&sb.tail, .Acquire))
	}
	return t
}

// Wait for the stream's threads to draw everything handed to them.
@(private)
stream_drain :: proc() {
	h := stream.head
	if stream_tail() != h {
		t0 := time.tick_now()
		for spin := 0; stream_tail() != h; spin += 1 {
			stream_pause(spin)
		}
		sync_t[sync_cause] += time.tick_since(t0)
		sync_n[sync_cause] += 1
	}
	stream.writes = {}
}

// Whether VRAM's draws run on the stream and some are not synced yet.
@(private)
stream_live :: #force_inline proc() -> bool {
	return targets[1].gl && !preload_child && stream.head != stream.synced
}

// Hand the stream a job laying VRAM's ghost layer over it, in order with
// the draws before and after it, so the walk does not wait for them; the
// layer's box is the stream threads' from then on.
@(private)
stream_ghost_flush :: proc(t: ^Target) {
	d := Draw {
		kind = .Ghost,
	}
	d.ghost = {t.ghost.lo, t.ghost.hi}
	stream_push(&d)
	t.ghost.lo, t.ghost.hi = {t.w, t.h}, {0, 0}
}

// Drain the stream, then merge its ghost boxes into VRAM's ghost layer.
@(private)
stream_sync :: proc() {
	stream_drain()
	for &sb, i in stream.bands {
		raster_ghost_merge(&sb.ra)
		sb.ra = raster_make(&targets[0], nil, i32(i), STREAM_BANDS)
	}
	stream.synced = stream.head
}

// Back off while waiting for the other side of the stream.
@(private)
stream_pause :: #force_inline proc(spin: int) {
	if spin < 256 {
		intrinsics.cpu_relax()
	} else {
		thread.yield()
	}
}

@(private)
stream_worker :: proc(th: ^thread.Thread) {
	sb := &stream.bands[th.user_index]
	for {
		t := sb.tail
		if t == sync.atomic_load(&stream.head) {
			// Idle: sleep unless a draw came while going idle and the walk
			// has not seen us idle yet (then it posts no wake).
			sync.atomic_store(&sb.idle, true)
			if t != sync.atomic_load(&stream.head) {
				if _, ok := sync.atomic_compare_exchange_strong(&sb.idle, true, false); ok {
					continue
				}
			}
			sync.sema_wait(&sb.wake)
			continue
		}
		raster_draw(u16, &sb.ra, &stream.ring[t % STREAM_N])
		sync.atomic_store_explicit(&sb.tail, t + 1, .Release)
	}
}

// Draw the queues.
@(private)
raster_sync :: #force_inline proc() {
	if len(raster.draws) > 0 || len(raster.native) > 0 || gpu_gl.prim_n > 0 || stream.head != stream.synced {
		raster_run()
	}
}

@(private)
raster_run :: proc() {
	gl_submit()
	if stream.head != stream.synced {
		stream_sync()
	}
	bands := raster_pool()
	n := bands
	if len(raster.draws) == 0 {
		raster_band(bands, bands, nil)
	} else {
		if len(raster.native) > 0 {
			n += 1
		}
		raster_launch(raster_band, nil, n)
		for &p in raster.passes[:bands] {
			raster_ghost_merge(&p)
		}
	}
	if len(raster.native) > 0 {
		raster_ghost_merge(&raster.passes[bands])
	}
	clear(&raster.draws)
	clear(&raster.native)
	raster.reads, raster.writes = {}, {}
}

@(private)
raster_worker :: proc(_: ^thread.Thread) {
	for {
		sync.sema_wait(&raster.go)
		raster.job(sync.atomic_add(&raster.next, 1), raster.bands, raster.data)
		sync.wait_group_done(&raster.done)
	}
}

// Draw the hi-res queue's rows in band `band`, or VRAM's queue as band
// `bands`.
@(private)
raster_band :: proc(band, bands: i32, _: rawptr) {
	ra := &raster.passes[band]
	if band == bands {
		ra^ = raster_make(&targets[0], nil)
		for &d in raster.native {
			raster_draw(u16, ra, &d)
		}
	} else {
		ra^ = raster_make(&targets[1], nil, band, bands)
		for &d in raster.draws {
			raster_draw(u32, ra, &d)
		}
	}
}

// Draw queued draw d in pass ra, its target's pixels of type P.
@(private)
raster_draw :: #force_inline proc($P: typeid, ra: ^Raster, d: ^Draw) {
	ra.e = &d.env
	switch d.kind {
	case .Triangle:
		tri_rows(P, ra, &d.m, &d.tri)
	case .Rect:
		q := &d.rect
		draw_rect(P, ra, &d.m, q.x, q.y, q.w, q.h, q.r, q.g, q.b, q.u, q.v)
	case .Line:
		draw_line(P, ra, &d.m, d.line[0], d.line[1])
	case .Ghost:
		ghost_band(P, ra, d.ghost.lo, d.ghost.hi)
	}
}

// Draw a triangle into target t (VRAM or the hi-res target, queued during
// a walk).
@(private)
draw_triangle :: proc(t: ^Target, e: ^Plot_Env, m: ^Prim_Mode, va, vb, vc: Vertex) {
	d: Draw = ---
	if !tri_setup(&d.tri, t, &e.st, m, va, vb, vc) {
		return
	}
	tri := &d.tri
	if t.shift > 0 {
		k := t.shift
		hi_touch(tri.min_x >> k, tri.min_y >> k, (tri.max_x >> k) - (tri.min_x >> k) + 1, (tri.max_y >> k) - (tri.min_y >> k) + 1)
	}
	if raster.on || t.gl {
		d.kind, d.env, d.m = .Triangle, e^, m^
		raster_queue(t, &d, tri.min_x, tri.min_y, tri.max_x, tri.max_y)
		return
	}
	gl_vram_write(t, tri.min_x, tri.min_y, tri.max_x, tri.max_y)
	ra := raster_make(t, e)
	if t.shift > 0 {
		tri_rows(u32, &ra, m, tri)
	} else {
		tri_rows(u16, &ra, m, tri)
	}
	raster_ghost_merge(&ra)
}

@(private)
rect_issue :: proc(t: ^Target, e: ^Plot_Env, m: ^Prim_Mode, x, y, w, h, r, g, b, u, v: i32) {
	if t.shift > 0 && events_frozen {
		x0, y0 := max(x, e.st.x1), max(y, e.st.y1)
		hi_touch(x0, y0, min(x + w - 1, e.st.x2) - x0 + 1, min(y + h - 1, e.st.y2) - y0 + 1)
	}
	if raster.on || t.gl {
		x0, y0 := max(x, e.st.x1), max(y, e.st.y1)
		x1, y1 := min(x + w - 1, e.st.x2), min(y + h - 1, e.st.y2)
		if x0 > x1 || y0 > y1 {
			return
		}
		d := Draw {
			kind = .Rect,
			env  = e^,
			m    = m^,
		}
		d.rect = {x, y, w, h, r, g, b, u, v}
		raster_queue(t, &d, x0, y0, x1, y1)
		return
	}
	gl_vram_write(t, max(x, e.st.x1), max(y, e.st.y1), min(x + w - 1, e.st.x2), min(y + h - 1, e.st.y2))
	ra := raster_make(t, e)
	if t.shift > 0 {
		draw_rect(u32, &ra, m, x, y, w, h, r, g, b, u, v)
	} else {
		draw_rect(u16, &ra, m, x, y, w, h, r, g, b, u, v)
	}
	raster_ghost_merge(&ra)
}

@(private)
line_issue :: proc(t: ^Target, e: ^Plot_Env, m: ^Prim_Mode, a, b: Vertex) {
	if t.shift > 0 && events_frozen {
		x0, y0 := max(min(a.x, b.x), e.st.x1), max(min(a.y, b.y), e.st.y1)
		hi_touch(x0, y0, min(max(a.x, b.x), e.st.x2) - x0 + 1, min(max(a.y, b.y), e.st.y2) - y0 + 1)
	}
	if raster.on || t.gl {
		x0, y0 := max(min(a.x, b.x), e.st.x1), max(min(a.y, b.y), e.st.y1)
		x1, y1 := min(max(a.x, b.x), e.st.x2), min(max(a.y, b.y), e.st.y2)
		if x0 > x1 || y0 > y1 {
			return
		}
		d := Draw {
			kind = .Line,
			env  = e^,
			m    = m^,
		}
		d.line = {a, b}
		raster_queue(t, &d, x0, y0, x1, y1)
		return
	}
	gl_vram_write(t, max(min(a.x, b.x), e.st.x1), max(min(a.y, b.y), e.st.y1), min(max(a.x, b.x), e.st.x2), min(max(a.y, b.y), e.st.y2))
	ra := raster_make(t, e)
	if t.shift > 0 {
		draw_line(u32, &ra, m, a, b)
	} else {
		draw_line(u16, &ra, m, a, b)
	}
	raster_ghost_merge(&ra)
}

// The rows lo ..< hi split into `bands` runs: band's run.
@(private)
band_run :: proc(lo, hi, band, bands: i32) -> (i32, i32) {
	n := hi - lo
	return lo + i32(i64(n) * i64(band) / i64(bands)), lo + i32(i64(n) * i64(band + 1) / i64(bands))
}
