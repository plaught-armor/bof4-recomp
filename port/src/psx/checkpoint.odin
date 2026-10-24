// Frozen-time passes: run game code to draw an extra picture between two
// game frames, then put the machine back exactly as it was.
//
// A pass starts with checkpoint_save, which copies every piece of machine
// state that game code reaching the GPU can change (RAM a page at a time, on
// the pass's first write to each page: ram_guard in bus.odin), and freezes emulated
// time: events (vblank, DMA completion, CD, timers) and interrupts are held
// back, so no interrupt handler, vblank or present runs inside the pass.
// The caller then calls game functions with `call`, draws with the game's own
// GPU calls, and copies the picture with capture_extra_frame. checkpoint_restore
// puts RAM, VRAM, CPU, GTE, GPU, DMA, interrupt, event and BIOS state (the
// rand() seed among it) and the
// ordering-table cull back and lets time run again. Sound, CD, controller and memory card state are not saved;
// draw code never touches them, except the sound library's voice commit in
// the frame's end, whose SPU register writes spu_write drops in a pass.
package psx

import "core:fmt"

Checkpoint :: struct {
	// RAM is saved a page at a time, on the pass's first write to the page
	// (ram_keep); only the pages in `kept` hold saved bytes.
	ram:        [RAM_SIZE]u8,
	kept:       Ram_Pages,
	ram_ver:    [RAM_PAGES]u32,
	// RAM_KEEP_CHECK builds: all of RAM at save, to prove at restore that
	// every page the pass changed was kept.
	ram_check:  [RAM_SIZE when RAM_KEEP_CHECK else 0]u8,
	scratch:    [SCRATCH_SIZE]u8,
	vram:       [VRAM_W * VRAM_H]u16,
	vram_key:   u32,
	// The hi-res target's pixels. During a pass the pass draws into this
	// buffer instead, swapped with the target's own (which keeps the saved
	// picture); a tile is copied in from the saved picture just before the
	// pass first uses it (hi_tiles), and restore swaps back.
	hi:         []u32,
	hi_tiles:   u128,
	hi_swapped: bool,
	// The same as a texture when the target is drawn on the host GPU
	// (gl_target.odin), and the target width it was made for.
	hi_gl:      u32,
	hi_gl_w:    i32,
	// The pass this one runs inside (a room drawn for an in-between
	// picture), nil for one saved from the running machine.
	outer:      ^Checkpoint,
	cpu:        Cpu,
	cop0:       type_of(cop0),
	gte:        Gte,
	gpu:        Draw_State,
	gp:         type_of(gp),
	display:    type_of(display),
	dma:        type_of(dma),
	irq:        type_of(irq_regs),
	bios:       type_of(bios),
	events:     [Event]u64,
	next_event: u64,
	see:        type_of(see_through),
	depths:     Depth_Undo,
	worlds:     World_Undo,
	flats:      type_of(flats),
	portals:    type_of(portals),
	pictures:   type_of(pictures),
	backs:      type_of(backs),
	cover:      Picture,
	blacks:     type_of(blacks),
}

// Memory as one game frame's drawing found it, for replaying that drawing.
Draw_Start :: struct {
	ram:     [RAM_SIZE]u8,
	// ram's page versions (ram_ver).
	ram_ver: [RAM_PAGES]u32,
	scratch: [SCRATCH_SIZE]u8,
	gte:     Gte,
}

// One bit per RAM page.
@(private)
Ram_Pages :: [RAM_PAGES / 64]u64

// Build with -define:RAM_KEEP_CHECK=true to check, at every restore, that
// no RAM write went around ram_guard / ram_touch.
RAM_KEEP_CHECK :: #config(RAM_KEEP_CHECK, false)

@(private)
page_has :: #force_inline proc(set: ^Ram_Pages, p: u32) -> bool {
	return set[p / 64] & (1 << (p % 64)) != 0
}

// Before an armed page's write: give RAM page p a new version, and inside a
// pass copy it into the running pass's checkpoint when that has not saved it
// yet, and into the outer pass's too when that has not: the page is
// unchanged since the outer save, since any write since would have kept it.
@(private)
ram_keep :: proc(p: u32) #no_bounds_check {
	assert(p < RAM_PAGES, "RAM page out of range")
	ram_armed[p] = false
	ram_ver_last += 1
	ram_ver[p] = ram_ver_last
	cp := pass_checkpoint
	if cp == nil {
		return
	}
	at := p * RAM_PAGE
	if !page_has(&cp.kept, p) {
		copy(cp.ram[at:][:RAM_PAGE], ram[at:][:RAM_PAGE])
		cp.kept[p / 64] |= 1 << (p % 64)
	}
	if o := cp.outer; o != nil && !page_has(&o.kept, p) {
		copy(o.ram[at:][:RAM_PAGE], ram[at:][:RAM_PAGE])
		o.kept[p / 64] |= 1 << (p % 64)
	}
}

// Put the kept pages of cp back into RAM, runs of neighbouring pages at once.
@(private)
ram_put_back :: proc(cp: ^Checkpoint) #no_bounds_check {
	p := u32(0)
	for p < RAM_PAGES {
		if !page_has(&cp.kept, p) {
			p += 1
			continue
		}
		first := p
		for p < RAM_PAGES && page_has(&cp.kept, p) {
			p += 1
		}
		copy(ram[first * RAM_PAGE:p * RAM_PAGE], cp.ram[first * RAM_PAGE:p * RAM_PAGE])
	}
}

// True between checkpoint_save and checkpoint_restore: run_events holds every
// event back.
events_frozen: bool

// The running pass's checkpoint, which hi_touch saves hi-res tiles into.
@(private)
pass_checkpoint: ^Checkpoint

// Copy the machine into cp and freeze time. Returns false, changing nothing,
// when the GPU is midway through a command or transfer, which a pass would
// corrupt. Inside a pass, cp nests in it: restore goes back to the pass.
checkpoint_save :: proc(cp: ^Checkpoint) -> bool {
	assert(!events_frozen || pass_checkpoint != nil, "pass without its checkpoint")
	assert(cp != pass_checkpoint, "checkpoint saved twice")
	if gp.need != 0 || gp.polyline || gp.uploading || gp.downloading {
		return false
	}
	gl_settle()
	cp.kept = {}
	cp.ram_ver = ram_ver
	ram_armed = true
	when RAM_KEEP_CHECK {
		cp.ram_check = ram
	}
	cp.scratch = scratch
	cp.vram = vram
	cp.vram_key = vram_key
	cp.hi_tiles = 0
	cp.hi_swapped = false
	if target_count == 2 && targets[1].gl {
		gl_hi_swap(cp, true)
		cp.hi_swapped = true
	} else if target_count == 2 {
		if len(cp.hi) != len(targets[1].rgb) {
			delete(cp.hi)
			cp.hi = make([]u32, len(targets[1].rgb))
		}
		targets[1].rgb, cp.hi = cp.hi, targets[1].rgb
		cp.hi_swapped = true
	}
	cp.outer = events_frozen ? pass_checkpoint : nil
	assert(cp.outer == nil || cp.outer.outer == nil, "passes nested twice")
	pass_checkpoint = cp
	cp.cpu = cpu
	cp.cop0 = cop0
	cp.gte = gte
	cp.gpu = gpu
	cp.gp = gp
	cp.display = display
	cp.dma = dma
	cp.irq = irq_regs
	cp.bios = bios
	cp.events = events
	cp.next_event = next_event
	// The frame's packets are drawn again from scratch, projected anew, and
	// its own projections wait for its own walk.
	cp.see = see_through
	depth_undo_begin(&cp.depths)
	world_undo_begin(&cp.worlds)
	cp.flats = flats
	cp.portals = portals
	cp.pictures = pictures
	cp.backs = backs
	cp.cover = cover
	cp.blacks = blacks
	events_frozen = true
	next_event = EVENT_OFF
	return true
}

// Put back the machine saved in cp and let time run again (or, for a nested
// pass, go back to the pass it ran in).
checkpoint_restore :: proc(cp: ^Checkpoint) {
	assert(events_frozen, "restore without a checkpoint")
	gl_settle()
	ram_put_back(cp)
	when RAM_KEEP_CHECK {
		for p in u32(0) ..< RAM_PAGES {
			at := p * RAM_PAGE
			if string(ram[at:][:RAM_PAGE]) != string(cp.ram_check[at:][:RAM_PAGE]) {
				fmt.panicf("RAM page %#x changed in a pass without being kept (present %d)", 0x80000000 + at, host.presents)
			}
		}
	}
	// Pages ram_put_back wrote are as they were at save, and the others
	// unchanged since: the saved versions name them all.
	ram_ver = cp.ram_ver
	ram_armed = true
	scratch = cp.scratch
	vram = cp.vram
	vram_world(cp.vram_key)
	if cp.hi_swapped && hi_saved(cp) {
		if targets[1].gl {
			gl_hi_swap(cp, false)
		} else {
			targets[1].rgb, cp.hi = cp.hi, targets[1].rgb
		}
	}
	cp.hi_tiles = 0
	cp.hi_swapped = false
	pass_checkpoint = cp.outer
	cpu = cp.cpu
	cop0 = cp.cop0
	gte = cp.gte
	gpu = cp.gpu
	// The command buffer may have grown during the pass; keep its storage
	// (the saved header could point at freed memory). It was empty at save.
	cmd := gp.cmd
	gp = cp.gp
	gp.cmd = cmd
	clear(&gp.cmd)
	display = cp.display
	dma = cp.dma
	irq_regs = cp.irq
	bios = cp.bios
	events = cp.events
	next_event = cp.next_event
	see_through = cp.see
	depth_undo_end(&cp.depths)
	world_undo_end(&cp.worlds)
	flats = cp.flats
	portals = cp.portals
	pictures = cp.pictures
	backs = cp.backs
	cover = cp.cover
	blacks = cp.blacks
	events_frozen = cp.outer != nil
	cp.outer = nil
}

// The hi-res target's pixels over VRAM area x, y, w x h are about to be
// read or changed: inside a pass, copy in the tiles under it the pass has
// not used yet. Call before the read, or before the change is made or
// queued.
@(private)
hi_touch :: #force_inline proc(x, y, w, h: i32) {
	if events_frozen && w > 0 && h > 0 {
		hi_load(vram_tiles(x, y, w, h), 0)
	}
}

// As hi_touch, for an area about to be overwritten whole: tiles it covers
// entirely need no copy.
@(private)
hi_cover :: #force_inline proc(x, y, w, h: i32) {
	if events_frozen && w > 0 && h > 0 {
		whole: u128
		if x + w <= VRAM_W && y + h <= VRAM_H {
			for ty in (y + 63) >> 6 ..< (y + h) >> 6 {
				for tx in (x + 63) >> 6 ..< (x + w) >> 6 {
					whole |= 1 << u32(ty * 16 + tx)
				}
			}
		}
		hi_load(vram_tiles(x, y, w, h), whole)
	}
}

// Copy the tiles in mask but not in whole from the saved picture into the
// pass's buffer, once per pass. A nested pass's saved picture is the outer
// pass's buffer, which takes the tiles it lacks from its own saved picture
// first.
@(private)
hi_load :: proc(mask, whole: u128) {
	cp := pass_checkpoint
	if cp == nil || !cp.hi_swapped || !hi_saved(cp) {
		return
	}
	fresh := mask &~ cp.hi_tiles
	if fresh == 0 {
		return
	}
	cp.hi_tiles |= fresh
	gl := targets[1].gl
	if o := cp.outer; o != nil && o.hi_swapped && hi_saved(o) {
		lack := fresh &~ whole &~ o.hi_tiles
		o.hi_tiles |= lack
		if gl {
			gl_copy_tiles(cp.hi_gl, o.hi_gl, lack)
		} else {
			hi_copy_tiles(cp.hi, o.hi, lack)
		}
	}
	if gl {
		gl_copy_tiles(gpu_gl.main, cp.hi_gl, fresh &~ whole)
	} else {
		hi_copy_tiles(targets[1].rgb, cp.hi, fresh &~ whole)
	}
}

// Whether cp holds a saved picture of the hi-res target as it is now.
@(private)
hi_saved :: proc(cp: ^Checkpoint) -> bool {
	if target_count != 2 {
		return false
	}
	t := &targets[1]
	if t.gl {
		return cp.hi_gl != 0 && cp.hi_gl_w == t.w
	}
	return len(cp.hi) == len(t.rgb)
}

// Copy the hi-res target's tiles in mask (VRAM tiles, as vram_tiles) from
// src to dst, runs of neighbouring tiles at once.
@(private)
hi_copy_tiles :: proc(dst, src: []u32, mask: u128) #no_bounds_check {
	if mask == 0 {
		return
	}
	t := &targets[1]
	n := i32(64) << t.shift
	for ty in i32(0) ..< 8 {
		row := u16(mask >> u32(ty * 16))
		tx := i32(0)
		for tx < 16 {
			if row & (1 << u32(tx)) == 0 {
				tx += 1
				continue
			}
			x0 := tx
			for tx < 16 && row & (1 << u32(tx)) != 0 {
				tx += 1
			}
			for y in ty * n ..< (ty + 1) * n {
				i := y * t.w + x0 * n
				copy(dst[i:][:(tx - x0) * n], src[i:][:(tx - x0) * n])
			}
		}
	}
}

draw_start_save :: proc(ds: ^Draw_Start) {
	draw_start_take_ram(ds)
	ds.scratch = scratch
	ds.gte = gte
}

// Copy RAM, as it is now, into a draw start.
draw_start_take_ram :: proc(ds: ^Draw_Start) {
	ds.ram = ram
	ds.ram_ver = ram_ver
	ram_armed = true
}

// New versions for a draw start made by another process (a preload child,
// whose versions go on from the same numbers as this one's).
draw_start_adopt :: proc(ds: ^Draw_Start) {
	for &v in ds.ram_ver {
		ram_ver_last += 1
		v = ram_ver_last
	}
}

// Name the VRAM a pass has just put in place (a room's, from key 1; 0 is
// the machine's own), so the hi-res target keeps a GPU copy of each apart
// and swapping one in uploads only what changed (gl_vram_use).
vram_world :: proc(key: u32) {
	vram_key = key
	if target_count == 2 && targets[1].gl {
		gl_vram_use(key)
	}
}

// The VRAM in place, as vram_world named it.
@(private)
vram_key: u32

// Load a draw-start copy into the machine; only valid inside a pass.
draw_start_load :: proc(ds: ^Draw_Start) #no_bounds_check {
	assert(events_frozen, "draw start loaded outside a pass")
	// Most pages match already (the same version); only the others are kept
	// and written.
	for p in u32(0) ..< RAM_PAGES {
		at := p * RAM_PAGE
		if ram_ver[p] == ds.ram_ver[p] {
			when RAM_KEEP_CHECK {
				if string(ram[at:][:RAM_PAGE]) != string(ds.ram[at:][:RAM_PAGE]) {
					fmt.panicf("RAM page %#x changed without a new version (present %d)", 0x80000000 + at, host.presents)
				}
			}
			continue
		}
		ram_guard(at)
		copy(ram[at:][:RAM_PAGE], ds.ram[at:][:RAM_PAGE])
		ram_ver[p] = ds.ram_ver[p]
		ram_armed[p] = true
	}
	scratch = ds.scratch
	gte = ds.gte
}

// Load a draw-start copy's scratchpad and GTE, outside a pass: the machine
// goes on from there (an instant door, qol interiors.odin).
draw_start_enter :: proc(ds: ^Draw_Start) {
	scratch = ds.scratch
	gte = ds.gte
}

// Most extra pictures between two game frames: one per repeated vblank of a
// game frame up to 4 vblanks long.
EXTRA_FRAMES :: 3

// Pictures drawn by passes, shown by present in place of a game frame's
// repeats, in order.
@(private)
extra: struct {
	// At the shown target's resolution (render_scale_apply).
	frames: [EXTRA_FRAMES][]u32,
	// VRAM area they were copied from: the draw buffer of the game frame
	// that the display shows next.
	x, y:   i32,
	w, h:   i32,
	count:  int,
	shown:  int,
	ready:  bool,
}

// Copy the display-sized area at VRAM (x, y) as extra picture `step`, shown
// at the step+1'th repeat of the frame on screen; step 0 starts a new set.
// Call inside a pass, after drawing it.
capture_extra_frame :: proc(x, y: i32, step: int) {
	assert(events_frozen, "extra frame captured outside a pass")
	assert(step >= 0 && step < EXTRA_FRAMES, "extra frame step out of range")
	if step == 0 {
		extra.count, extra.shown = 0, 0
	}
	if display.w <= 0 || display.h <= 0 || display.depth24 || step != extra.count {
		extra.ready = false
		return
	}
	extra.x, extra.y = x & (VRAM_W - 1), y & (VRAM_H - 1)
	extra.w, extra.h = display.w, display.h
	hi_touch(extra.x, extra.y, extra.w, extra.h)
	convert_area(extra.x, extra.y, extra.w, extra.h, false, extra.frames[step][:], step)
	extra.count += 1
	extra.ready = true
	if .Gpu in trace.active {
		tracef(.Gpu, "extra frame %d from %d,%d %dx%d", step, extra.x, extra.y, extra.w, extra.h)
	}
}

// Decide what present shows: the extra pictures replace, in order, the
// frames the display repeats, until the display moves to the area they were
// drawn from (that game frame itself is now up). Repeats past the last
// picture keep showing it. `slot` is the GL frame slot the picture is the
// buffer of (the picture then nil: frame_pixels waits for it), -1 in
// software.
@(private)
extra_due :: proc(repeat: bool) -> (picture: []u32, slot: int, due: bool) {
	slot = -1
	if !extra.ready {
		return
	}
	if display.x == extra.x && display.y == extra.y {
		extra.ready = false
		return
	}
	if display.w != extra.w || display.h != extra.h || display.depth24 {
		extra.ready = false
		return
	}
	if !repeat {
		return
	}
	k := min(extra.shown, extra.count - 1)
	extra.shown += 1
	fw, fh := frame_size()
	if shown_target().gl {
		return nil, k, true
	}
	return extra.frames[k][:fw * fh], -1, true
}
