// I/O register dispatch, interrupt controller, event scheduler and root
// counters.
package psx

import "core:fmt"
import "core:os"
import "core:strconv"

import "ps:core"

// ---------------------------------------------------------------- timing

CPU_HZ :: 33_868_800
FRAME_CYCLES :: CPU_HZ / 60
SCANLINES :: 263
LINE_CYCLES :: FRAME_CYCLES / SCANLINES

Event :: enum {
	VBlank,
	Cdrom,
	Cdrom_Read,
	Dma,
	Spu,
	Sio,
	Timer0,
	Timer1,
	Timer2,
}

EVENT_OFF :: max(u64)

// CPU overclock: hardware delays and timer ticks last this many times their
// cycles, so the CPU runs that much more code per vblank while sound, disc
// and timers keep their real-time rates. 1 is the console's own speed;
// BOF4_CLOCK=n sets another (testing only).
clock_mul: u64 = 1

// Change clock_mul mid-run (autoplay's `clock`): the timers count on from
// their value now at the new rate. Events already scheduled keep their due
// cycle; periodic ones take the new rate from their next period.
clock_set :: proc(mul: u64) {
	for n in 0 ..< len(timers) {
		timers[n].value = timer_value(n)
		timers[n].base = cpu.cycles
	}
	clock_mul = mul
	for n in 0 ..< len(timers) {
		timer_reschedule(n)
	}
}

@(private)
events: [Event]u64

// The cycle the event being handled was due at (run_events).
@(private)
event_due: u64

schedule :: proc(e: Event, delay: u64) {
	events[e] = cpu.cycles + delay * clock_mul
	next_event = min(next_event, events[e])
}

// Schedule the event being handled again `period` cycles after it was due,
// not after it ran: recompiled code reaches run_events some way past the
// due cycle, and counting from there loses that much every period. A
// period already over runs again in the same run_events.
@(private)
schedule_period :: proc(e: Event, period: u64) {
	events[e] = event_due + period * clock_mul
	next_event = min(next_event, events[e])
}

unschedule :: proc(e: Event) {
	events[e] = EVENT_OFF
}

@(private)
event_handlers := [Event]proc() {
	.VBlank     = vblank_event,
	.Cdrom      = cdrom_event,
	.Cdrom_Read = cdrom_read_event,
	.Dma        = dma_event,
	.Spu        = spu_event,
	.Sio        = sio_event,
	.Timer0     = timer0_event,
	.Timer1     = timer1_event,
	.Timer2     = timer2_event,
}

// Called by recompiled code when cpu.cycles reaches next_event.
run_events :: proc() {
	if events_frozen {
		// Inside a frozen-time pass; checkpoint_restore reschedules.
		next_event = EVENT_OFF
		return
	}
	for {
		due := false
		for e in Event {
			if events[e] <= cpu.cycles {
				if .Event in core.trace.active {
					core.tracef(.Event, "%v (due %d)", e, events[e])
				}
				event_due = events[e]
				events[e] = EVENT_OFF
				event_handlers[e]()
				due = true
			}
		}
		if !due {
			break
		}
	}
	next_event = EVENT_OFF
	for t in events {
		next_event = min(next_event, t)
	}
	irq_check()
}

events_init :: proc() {
	for &t in events {
		t = EVENT_OFF
	}
	next_event = EVENT_OFF
	if v, ok := strconv.parse_u64(os.get_env("BOF4_CLOCK", context.temp_allocator)); ok && v >= 1 {
		clock_mul = v
	}
	schedule(.VBlank, FRAME_CYCLES)
}

@(private)
vblank_event :: proc() {
	schedule(.VBlank, FRAME_CYCLES)
	irq_raise(.VBlank)
	bios_pad_vblank()
	gpu_vblank()
	timers_vblank()
	platform_frame()
}

// ---------------------------------------------------------------- interrupts

Irq :: enum u32 {
	VBlank = 0,
	Gpu    = 1,
	Cdrom  = 2,
	Dma    = 3,
	Timer0 = 4,
	Timer1 = 5,
	Timer2 = 6,
	Sio0   = 7,
	Sio    = 8,
	Spu    = 9,
}

irq_regs: struct {
	stat: u32,
	mask: u32,
	// Nesting guard: hardware interrupts are not delivered while one runs.
	in_handler: bool,
}

irq_raise :: proc(i: Irq) {
	if .Irq in core.trace.active {
		core.tracef(.Irq, "raise %v stat=%x mask=%x sr=%x", i, irq_regs.stat, irq_regs.mask, cop0.sr)
	}
	irq_regs.stat |= 1 << u32(i)
	if next_event > cpu.cycles {
		// Delivered at the next event check so the raising device finishes first.
		next_event = cpu.cycles
	}
}

irq_check :: proc() {
	if irq_regs.stat & irq_regs.mask == 0 || irq_regs.in_handler {
		return
	}
	if cop0.sr & 0x401 != 0x401 {
		return
	}
	deliver_irq()
}

// ---------------------------------------------------------------- root counters

Timer :: struct {
	mode:   u32,
	target: u32,
	// Counter value at `base` cycles, and cycles per tick.
	value:  u32,
	base:   u64,
	div:    u64,
}

@(private)
timers: [3]Timer

@(private)
timer_rate :: proc(n: int) -> u64 {
	src := (timers[n].mode >> 8) & 3
	switch n {
	case 0:
		return 1 // dot clock approximated by system clock
	case 1:
		if src & 1 != 0 {
			return LINE_CYCLES
		}
	case 2:
		if src >= 2 {
			return 8
		}
	}
	return 1
}

@(private)
timer_value :: proc(n: int) -> u32 {
	t := &timers[n]
	ticks := (cpu.cycles - t.base) / (t.div * clock_mul)
	v := u64(t.value) + ticks
	if t.mode & 0x08 != 0 && t.target != 0 {
		v %= u64(t.target) + 1
	} else {
		v &= 0xffff
	}
	return u32(v)
}

@(private)
timer_reschedule :: proc(n: int) {
	t := &timers[n]
	e := Event(int(Event.Timer0) + n)
	unschedule(e)
	if t.mode & 0x30 == 0 {
		return
	}
	limit := u64(0x10000)
	if t.mode & 0x10 != 0 && t.target != 0 {
		limit = u64(t.target)
	}
	cur := u64(timer_value(n))
	ticks := limit > cur ? limit - cur : limit
	schedule(e, max(ticks * t.div, 1))
}

@(private)
timer_fire :: proc(n: int) {
	t := &timers[n]
	t.value = timer_value(n)
	t.base = cpu.cycles
	if t.mode & 0x08 != 0 && t.mode & 0x10 != 0 {
		t.value = 0
	}
	t.mode |= 0x800 if t.mode & 0x10 != 0 else 0x1000
	if .Timer in core.trace.active {
		core.tracef(.Timer, "timer%d fire mode=%x target=%x", n, t.mode, t.target)
	}
	irq_raise(Irq(u32(Irq.Timer0) + u32(n)))
	timer_reschedule(n)
}

@(private)
timer0_event :: proc() {timer_fire(0)}
@(private)
timer1_event :: proc() {timer_fire(1)}
@(private)
timer2_event :: proc() {timer_fire(2)}

@(private)
timers_vblank :: proc() {}

timers_init :: proc() {
	for &t in timers {
		t = {div = 1}
	}
}

@(private)
timer_read :: proc(n: int, reg: u32) -> u32 {
	switch reg {
	case 0:
		return timer_value(n)
	case 4:
		m := timers[n].mode
		timers[n].mode &= ~u32(0x1800)
		return m
	case 8:
		return timers[n].target
	}
	return 0
}

@(private)
timer_write :: proc(n: int, reg, v: u32) {
	t := &timers[n]
	if .Timer in core.trace.active {
		core.tracef(.Timer, "timer%d write reg%d <- %x", n, reg, v)
	}
	switch reg {
	case 0:
		t.value = v & 0xffff
		t.base = cpu.cycles
	case 4:
		t.mode = (v & 0x3ff) | 0x400
		t.value = 0
		t.base = cpu.cycles
		t.div = timer_rate(n)
	case 8:
		t.target = v & 0xffff
	}
	timer_reschedule(n)
}

// ---------------------------------------------------------------- dispatch

@(private)
memctrl: [16]u32

io_read :: proc(p: u32, size: u32) -> u32 {
	v := io_read_reg(p, size)
	if .Io in core.trace.active {
		core.tracef(.Io, "read%d  %08x -> %x ra=%x", size * 8, p, v, cpu.r[31])
	}
	return v
}

@(private)
io_read_reg :: proc(p: u32, size: u32) -> u32 {
	switch p {
	case 0x1f801000 ..< 0x1f801040:
		return memctrl[(p - 0x1f801000) >> 2]
	case 0x1f801040 ..< 0x1f801050:
		return sio0_read(p - 0x1f801040, size)
	case 0x1f801050 ..< 0x1f801060:
		return 0
	case 0x1f801060:
		return 0x00000b88
	case 0x1f801070:
		return irq_regs.stat
	case 0x1f801074:
		return irq_regs.mask
	case 0x1f801080 ..< 0x1f801100:
		return dma_read((p - 0x1f801080) & ~u32(3)) >> ((p & 3) * 8)
	case 0x1f801100 ..< 0x1f801130:
		return timer_read(int((p - 0x1f801100) >> 4), p & 0xf)
	case 0x1f801800 ..< 0x1f801804:
		return cdrom_read(p & 3)
	case 0x1f801810:
		return gpu_read()
	case 0x1f801814:
		return gpu_stat()
	case 0x1f801820:
		return mdec_read_data()
	case 0x1f801824:
		return mdec_read_status()
	case 0x1f801c00 ..< 0x1f802000:
		v := spu_read(p - 0x1f801c00)
		if size == 4 {
			v |= spu_read(p - 0x1f801c00 + 2) << 16
		}
		return v
	}
	report_once(p, "io read")
	return 0
}

io_write :: proc(p, v: u32, size: u32) {
	if .Io in core.trace.active {
		core.tracef(.Io, "write%d %08x <- %x ra=%x", size * 8, p, v, cpu.r[31])
	}
	switch p {
	case 0x1f801000 ..< 0x1f801040:
		memctrl[(p - 0x1f801000) >> 2] = v
	case 0x1f801040 ..< 0x1f801050:
		sio0_write(p - 0x1f801040, v, size)
	case 0x1f801050 ..< 0x1f801064:
	case 0x1f801070:
		if .Irq in core.trace.active {
			core.tracef(.Irq, "ack stat=%x & %x ra=%x", irq_regs.stat, v, cpu.r[31])
		}
		irq_regs.stat &= v
	case 0x1f801074:
		irq_regs.mask = v & 0x7ff
		irq_check()
	case 0x1f801080 ..< 0x1f801100:
		dma_write_sized(p - 0x1f801080, v, size)
	case 0x1f801100 ..< 0x1f801130:
		timer_write(int((p - 0x1f801100) >> 4), p & 0xf, v)
	case 0x1f801800 ..< 0x1f801804:
		cdrom_write(p & 3, v & 0xff)
	case 0x1f801810:
		gp0_write(v)
	case 0x1f801814:
		gp1_write(v)
	case 0x1f801820:
		mdec_write_cmd(v)
	case 0x1f801824:
		mdec_write_ctrl(v)
	case 0x1f801c00 ..< 0x1f802000:
		spu_write(p - 0x1f801c00, v & 0xffff)
		if size == 4 {
			spu_write(p - 0x1f801c00 + 2, v >> 16)
		}
	case 0x1f802000 ..< 0x1f803000:
	// expansion 2: debug LEDs and POST
	case:
		fmt.eprintfln("io write %#08x = %#x", p, v)
	}
}

// ---------------------------------------------------------------- DMA

Dma_Channel :: struct {
	madr, bcr, chcr: u32,
}

@(private)
dma: struct {
	ch:      [7]Dma_Channel,
	dpcr:    u32,
	dicr:    u32,
	// Channels whose completion interrupt is pending delivery.
	pending: u32,
}

dma_init :: proc() {
	dma.dpcr = 0x07654321
}

@(private)
dma_read :: proc(off: u32) -> u32 {
	if off < 0x70 {
		c := &dma.ch[off >> 4]
		switch off & 0xf {
		case 0:
			return c.madr
		case 4:
			return c.bcr
		case 8:
			return c.chcr
		}
		return 0
	}
	switch off {
	case 0x70:
		return dma.dpcr
	case 0x74:
		return dma.dicr
	}
	return 0
}

@(private)
dma_update_master :: proc() {
	d := dma.dicr
	prev := d & 0x80000000
	flag := (d & 0x8000) != 0 || ((d & 0x800000) != 0 && ((d >> 24) & (d >> 16) & 0x7f) != 0)
	dma.dicr = (d & 0x7fffffff) | (flag ? 0x80000000 : 0)
	if flag && prev == 0 {
		irq_raise(.Dma)
	}
}

// Byte and halfword stores (libcd sets DICR enables with sb) update only
// their lanes. DICR flags read back as 0 so untouched lanes ack nothing.
@(private)
dma_write_sized :: proc(off, v: u32, size: u32) {
	if size == 4 {
		dma_write(off, v)
		return
	}
	base := off & ~u32(3)
	shift := (off & 3) * 8
	lanes := (size == 2 ? u32(0xffff) : u32(0xff)) << shift
	cur := dma_read(base)
	if base == 0x74 {
		cur &= ~u32(0x7f000000)
	}
	dma_write(base, (cur & ~lanes) | ((v << shift) & lanes))
}

@(private)
dma_write :: proc(off, v: u32) {
	if off < 0x70 {
		n := off >> 4
		c := &dma.ch[n]
		switch off & 0xf {
		case 0:
			c.madr = v & 0xffffff
		case 4:
			c.bcr = v
		case 8:
			c.chcr = v
			if v & 0x01000000 != 0 && dma.dpcr & (8 << (n * 4)) != 0 {
				dma_run(n)
			}
		}
		return
	}
	switch off {
	case 0x70:
		dma.dpcr = v
	case 0x74:
		// Bits 24-30 acknowledge by writing 1.
		dma.dicr = (dma.dicr & 0x7f000000 & ~(v & 0x7f000000)) | (v & 0x00ff803f)
		dma_update_master()
	}
}

@(private)
dma_run :: proc(n: u32) {
	c := &dma.ch[n]
	if .Dma in core.trace.active {
		core.tracef(.Dma, "ch%d start madr=%x bcr=%x chcr=%x", n, c.madr, c.bcr, c.chcr)
	}
	switch n {
	case 2:
		dma_gpu(c)
	case 6:
		dma_otc(c)
	case 3:
		dma_cdrom(c)
	case 4:
		dma_spu(c)
	case 0:
		dma_mdec_in(c)
	case 1:
		if !dma_mdec_out(c) {
			// Completes once the MDEC has produced enough output.
			return
		}
	case:
		fmt.eprintfln("dma: channel %d not emulated", n)
	}
	dma_finish(n)
}

// Complete channel n: clear its busy bit and raise its interrupt shortly after.
dma_finish :: proc(n: u32) {
	if .Dma in core.trace.active {
		core.tracef(.Dma, "ch%d finish", n)
	}
	dma.ch[n].chcr &= ~u32(0x11000000)
	dma.pending |= 1 << n
	schedule(.Dma, 64)
}

@(private)
dma_event :: proc() {
	p := dma.pending
	dma.pending = 0
	for n in u32(0) ..< 7 {
		if p & (1 << n) != 0 && dma.dicr & (1 << (16 + n)) != 0 {
			dma.dicr |= 1 << (24 + n)
		}
	}
	dma_update_master()
}

@(private)
dma_words :: proc(c: ^Dma_Channel) -> u32 {
	if (c.chcr >> 9) & 3 == 0 {
		n := c.bcr & 0xffff
		return n == 0 ? 0x10000 : n
	}
	return (c.bcr & 0xffff) * (c.bcr >> 16)
}

// Ordering tables are cleared by OTC DMA; a clear of at least this many
// entries is taken as a frame's table (the last two, for double buffering).
@(private)
OT_MIN_ENTRIES :: 256

@(private)
ot_ranges: [2][2]u32

// The ordering-table bucket a linked-list node is, if it is one.
@(private)
ot_bucket :: proc(a: u32) -> (int, bool) {
	for r in ot_ranges {
		if r[1] != 0 && a >= r[0] && a <= r[1] {
			return int((a - r[0]) / 4), true
		}
	}
	return 0, false
}

@(private)
dma_otc :: proc(c: ^Dma_Channel) {
	n := dma_words(c)
	a := c.madr
	if n >= OT_MIN_ENTRIES {
		ot_ranges[1] = ot_ranges[0]
		ot_ranges[0] = {(a - (n - 1) * 4) & 0x1ffffc, a & 0x1ffffc}
	}
	for i in 0 ..< n {
		w32(a, i == n - 1 ? 0x00ffffff : (a - 4) & 0x1fffff)
		a -= 4
	}
}

@(private = "file")
dma_walk_seen: [0x200000 / 4]u32 // packet address: the list walk that last passed it
@(private = "file")
dma_walk_serial: u32

@(private)
dma_gpu :: proc(c: ^Dma_Channel) {
	switch (c.chcr >> 9) & 3 {
	case 2:
		// Linked list: walk packets from MADR.
		a := c.madr & 0x1ffffc
		see_begin()
		defer see_end()
		gpu_big_triangles = see.active
		defer gpu_big_triangles = false
		defer gpu_ghost_flush()
		defer portal_walk_end()
		picture_walk_begin()
		defer picture_flush()
		// Before the walk's state above is spent, its queued draws are done.
		raster_begin()
		defer raster_end()
		dma_walk_serial += 1
		prev := u32(0)
		for _ in 0 ..< 0x100000 {
			// A packet linked twice closes a loop, which the PS1's GPU DMA
			// would walk for ever (it happens for a frame after an instant
			// door's world switch): the walk ends where it comes round.
			if dma_walk_seen[a >> 2] == dma_walk_serial {
				core.tracef(.Dma, "gpu list: packet %#x linked again from %#x, list ends", a, prev)
				break
			}
			dma_walk_seen[a >> 2] = dma_walk_serial
			prev = a
			tag := r32(a)
			n := tag >> 24
			// Ghosts go over the scene before bucket 0's HUD, which is drawn
			// after them; faded pixels there blend straight into VRAM.
			if (see.active && !see.direct) || depth_walk.on {
				if b, ok := ot_bucket(a); ok && b == 0 {
					if see.active && !see.direct {
						gpu_ghost_flush()
						see.direct = true
					}
					picture_flush()
				}
			}
			if portals.n > 0 {
				portal_find(a)
			}
			packet_now = a
			for k in u32(0) ..< n {
				gp0_write(r32(a + 4 + k * 4))
			}
			if tag & 0x800000 != 0 {
				break
			}
			a = tag & 0x1ffffc
		}
	case:
		n := dma_words(c)
		a := c.madr & 0x1ffffc
		if c.chcr & 1 != 0 {
			for _ in 0 ..< n {
				gp0_write(r32(a))
				a += 4
			}
		} else {
			for _ in 0 ..< n {
				w32(a, gpu_read())
				a += 4
			}
		}
	}
}
