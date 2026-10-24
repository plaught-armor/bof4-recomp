// SPU: 24 ADPCM voices with ADSR envelopes, volume sweeps, noise, pitch
// modulation, CD audio input, capture buffers, the sound RAM IRQ and the
// transfer port. The .Spu event mixes SPU_BATCH samples at 44100 Hz and hands
// them to the host (platform_audio), on a thread of its own (spu_mixer).
// Reverb lives in reverb.odin.
package psx

import "core:sync"
import "core:thread"

SPU_RAM_SIZE :: 512 * 1024
@(private)
SPU_VOICES :: 24
@(private)
SAMPLE_CYCLES :: CPU_HZ / 44100
@(private)
SPU_BATCH :: 32

// Register byte offsets within 0x1f801c00.
@(private)
SPU_KON :: 0x188
@(private)
SPU_KOFF :: 0x18c
@(private)
SPU_PMON :: 0x190
@(private)
SPU_NON :: 0x194
@(private)
SPU_EON :: 0x198
@(private)
SPU_ENDX :: 0x19c
@(private)
SPU_IRQ_ADDR :: 0x1a4
@(private)
SPU_CNT :: 0x1aa
@(private)
SPU_STAT :: 0x1ae

@(private)
SPUCNT_CD_ENABLE :: 0x0001
@(private)
SPUCNT_IRQ_ENABLE :: 0x0040
@(private)
SPUCNT_UNMUTE :: 0x4000

// ADPCM prediction filters shared by SPU voices and XA audio.
@(private)
ADPCM_POS := [5]i32{0, 60, 115, 98, 122}
@(private)
ADPCM_NEG := [5]i32{0, 0, -52, -55, -60}

@(private)
Adsr_Phase :: enum u8 {
	Off,
	Attack,
	Decay,
	Sustain,
	Release,
}

// Envelope or volume sweep: level moves by one step every `wait` samples.
@(private)
Envelope :: struct {
	level: i32,
	wait:  i32,
}

@(private)
Voice :: struct {
	// Next ADPCM block to decode, in bytes.
	addr:       u32,
	repeat:     u32,
	// The game wrote the repeat address after key-on, so loop-start flags
	// in the sample data must not replace it.
	repeat_set: bool,
	// Pitch counter: sample index in `samples` << 12 | fraction.
	counter:    u32,
	samples:    [28]i16,
	flags:      u8,
	old, older: i32,
	// Last sample of the previous block, for interpolation across blocks.
	last:       i16,
	phase:      Adsr_Phase,
	env:        Envelope,
	// Output after the envelope, before volume: drives pitch modulation.
	out:        i32,
	vol:        [2]Envelope,
}

@(private)
spu: struct {
	regs:        [0x200]u16,
	ram:         [SPU_RAM_SIZE]u8,
	voices:      [SPU_VOICES]Voice,
	// Transfer address in bytes.
	addr:        u32,
	endx:        u32,
	irq_flag:    bool,
	main_vol:    [2]Envelope,
	noise_level: u16,
	noise_timer: i32,
	// Capture buffer position (0..0x1ff halfwords).
	capture:     u32,
	batch:       [SPU_BATCH][2]i16,
}

spu_init :: proc() {
	spu.endx = (1 << SPU_VOICES) - 1
	spu.noise_level = 1
	schedule(.Spu, SAMPLE_CYCLES * SPU_BATCH)
}

@(private)
reg :: #force_inline proc(off: u32) -> u32 #no_bounds_check {
	return u32(spu.regs[(off & 0x3ff) >> 1])
}

spu_read :: proc(off: u32) -> u32 {
	spu_sync()
	switch off {
	case SPU_ENDX:
		return spu.endx & 0xffff
	case SPU_ENDX + 2:
		return spu.endx >> 16
	case SPU_STAT:
		s := reg(SPU_CNT) & 0x3f
		s |= spu.irq_flag ? 0x40 : 0
		s |= spu.capture >= 0x100 ? 0x800 : 0
		return s
	case 0x1b8, 0x1ba:
		return u32(u16(spu.main_vol[(off - 0x1b8) >> 1].level))
	}
	if off < SPU_VOICES * 0x10 {
		v := &spu.voices[off >> 4]
		switch off & 0xf {
		case 0xc:
			return u32(v.env.level)
		case 0xe:
			return v.repeat >> 3
		}
	}
	return reg(off)
}

spu_write :: proc(off, v: u32) {
	// A frozen-time pass (checkpoint.odin) runs the frame's end again, and
	// the sound library's commit there (0x8015da50..0x8015df08) writes the
	// voice volumes and key registers from the RAM the pass loaded, a frame
	// older than the chip's. Kept, they set voices back every pass and the
	// music and ambience stuttered under smooth motion. The pass's RAM is put
	// back, so its writes here are dropped.
	if events_frozen {
		return
	}
	spu_sync()
	spu.regs[(off & 0x3ff) >> 1] = u16(v)
	if off < SPU_VOICES * 0x10 {
		voice := &spu.voices[off >> 4]
		switch off & 0xf {
		case 0xc:
			voice.env.level = i32(u16(v) & 0x7fff)
		case 0xe:
			voice.repeat = (v & 0xffff) * 8
			voice.repeat_set = true
		}
		return
	}
	switch off {
	case SPU_KON, SPU_KON + 2:
		keys(v << ((off - SPU_KON) * 8), true)
	case SPU_KOFF, SPU_KOFF + 2:
		keys(v << ((off - SPU_KOFF) * 8), false)
	case SPU_ENDX, SPU_ENDX + 2:
	// Read-only.
	case SPU_CNT:
		if v & SPUCNT_IRQ_ENABLE == 0 {
			spu.irq_flag = false
		}
	case 0x1a6:
		spu.addr = (v & 0xffff) * 8
	case 0x1a8:
		spu_irq_check(spu.addr, 2)
		spu.ram[spu.addr & (SPU_RAM_SIZE - 1)] = u8(v)
		spu.ram[(spu.addr + 1) & (SPU_RAM_SIZE - 1)] = u8(v >> 8)
		spu.addr += 2
	}
}

@(private)
keys :: proc(mask: u32, on: bool) {
	for n in 0 ..< SPU_VOICES {
		if mask & (1 << u32(n)) == 0 {
			continue
		}
		v := &spu.voices[n]
		if !on {
			if v.phase != .Off {
				v.phase = .Release
				v.env.wait = 0
			}
			continue
		}
		v.addr = reg(u32(n) * 0x10 + 6) * 8
		v.repeat_set = false
		v.counter = 0
		v.old, v.older, v.last = 0, 0, 0
		v.phase = .Attack
		v.env = {}
		spu.endx &~= 1 << u32(n)
		decode_block(v)
	}
}

// Raise IRQ9 when [a, a+len) covers the IRQ address.
@(private)
spu_irq_check :: proc(a, len: u32) {
	if reg(SPU_CNT) & SPUCNT_IRQ_ENABLE == 0 || spu.irq_flag {
		return
	}
	target := reg(SPU_IRQ_ADDR) * 8
	if target >= (a & (SPU_RAM_SIZE - 1)) && target < (a & (SPU_RAM_SIZE - 1)) + len {
		spu.irq_flag = true
		irq_raise(.Spu)
	}
}

@(private)
decode_block :: proc(v: ^Voice) #no_bounds_check {
	a := v.addr & (SPU_RAM_SIZE - 16)
	spu_irq_check(a, 16)
	b := spu.ram[a:a + 16]
	shift := u32(b[0] & 0xf)
	if shift > 12 {
		shift = 9
	}
	f := min(int(b[0] >> 4) & 7, 4)
	v.flags = b[1]
	if v.flags & 4 != 0 && !v.repeat_set {
		v.repeat = a
	}
	for i in 0 ..< 28 {
		nib := (b[2 + i / 2] >> (4 * u32(i & 1))) & 0xf
		s := i32(i16(u16(nib) << 12)) >> shift
		s += (v.old * ADPCM_POS[f] + v.older * ADPCM_NEG[f] + 32) >> 6
		s = clamp(s, -0x8000, 0x7fff)
		v.samples[i] = i16(s)
		v.older, v.old = v.old, s
	}
	v.addr = a + 16
}

// Move past the 28 samples of the current block, honouring its loop flags.
@(private)
next_block :: proc(v: ^Voice, n: int) {
	v.last = v.samples[27]
	if v.flags & 1 != 0 {
		spu.endx |= 1 << u32(n)
		v.addr = v.repeat
		if v.flags & 2 == 0 {
			v.phase = .Off
			v.env.level = 0
		}
	}
	decode_block(v)
}

@(private)
env_tick :: proc(e: ^Envelope, exp, decrease: bool, shift: u32, step: i32) {
	e.wait -= 1
	if e.wait > 0 {
		return
	}
	cycles := i32(1) << u32(max(0, i32(shift) - 11))
	s := step << u32(max(0, 11 - i32(shift)))
	if exp && !decrease && e.level > 0x6000 {
		cycles *= 4
	}
	if exp && decrease {
		s = s * e.level >> 15
	}
	e.level = clamp(e.level + s, 0, 0x7fff)
	e.wait = cycles
}

@(private)
adsr_tick :: proc(v: ^Voice, n: u32) {
	lo := reg(n * 0x10 + 8)
	hi := reg(n * 0x10 + 0xa)
	switch v.phase {
	case .Off:
	case .Attack:
		env_tick(&v.env, lo & 0x8000 != 0, false, (lo >> 10) & 0x1f, 7 - i32((lo >> 8) & 3))
		if v.env.level >= 0x7fff {
			v.phase = .Decay
			v.env.wait = 0
		}
	case .Decay:
		env_tick(&v.env, true, true, (lo >> 4) & 0xf, -8)
		if v.env.level <= i32((lo & 0xf) + 1) * 0x800 {
			v.phase = .Sustain
			v.env.wait = 0
		}
	case .Sustain:
		dec := hi & 0x4000 != 0
		st := i32((hi >> 6) & 3)
		env_tick(&v.env, hi & 0x8000 != 0, dec, (hi >> 8) & 0x1f, dec ? -8 + st : 7 - st)
	case .Release:
		env_tick(&v.env, hi & 0x20 != 0, true, hi & 0x1f, -8)
		if v.env.level == 0 {
			v.phase = .Off
			spu.endx |= 1 << n
		}
	}
}

// Fixed volumes are signed 15-bit values; sweeps run an envelope (the phase
// inversion bit is ignored).
@(private)
volume :: proc(e: ^Envelope, r: u32) -> i32 {
	if r & 0x8000 == 0 {
		e.level = i32(i16(u16(r << 1)))
		return e.level
	}
	dec := r & 0x2000 != 0
	st := i32(r & 3)
	env_tick(e, r & 0x4000 != 0, dec, (r >> 2) & 0x1f, dec ? -8 + st : 7 - st)
	return e.level
}

@(private)
noise_tick :: proc() {
	cnt := reg(SPU_CNT)
	shift := (cnt >> 10) & 0xf
	spu.noise_timer -= i32((cnt >> 8) & 3) + 4
	if spu.noise_timer >= 0 {
		return
	}
	l := spu.noise_level
	parity := ((l >> 15) ~ (l >> 12) ~ (l >> 11) ~ (l >> 10) ~ 1) & 1
	spu.noise_level = l << 1 | parity
	spu.noise_timer += i32(0x20000 >> shift)
	if spu.noise_timer < 0 {
		spu.noise_timer += i32(0x20000 >> shift)
	}
}

@(private)
voice_sample :: proc(n: u32) -> (l, r: i32) #no_bounds_check {
	assert(n < SPU_VOICES, "voice out of range")
	v := &spu.voices[n]
	if v.phase == .Off {
		v.out = 0
		return
	}
	s: i32
	if (reg(SPU_NON) | reg(SPU_NON + 2) << 16) & (1 << n) != 0 {
		s = i32(i16(spu.noise_level))
	} else {
		idx := v.counter >> 12
		assert(idx < 28, "sample counter past its block")
		s0 := i32(idx == 0 ? v.last : v.samples[idx - 1])
		s1 := i32(v.samples[idx])
		s = s0 + (s1 - s0) * i32(v.counter & 0xfff) >> 12
	}
	v.out = s * v.env.level >> 15
	l = v.out * volume(&v.vol[0], reg(n * 0x10)) >> 15
	r = v.out * volume(&v.vol[1], reg(n * 0x10 + 2)) >> 15
	adsr_tick(v, n)

	step := min(reg(n * 0x10 + 4), 0x4000)
	if n > 0 && (reg(SPU_PMON) | reg(SPU_PMON + 2) << 16) & (1 << n) != 0 {
		factor := spu.voices[n - 1].out + 0x8000
		step = u32(min(i32(step) * factor >> 15, 0x3fff))
	}
	v.counter += step
	for v.counter >> 12 >= 28 {
		v.counter -= 28 << 12
		next_block(v, int(n))
	}
	return
}

@(private)
capture_write :: proc(base: u32, s: i32) {
	a := base + spu.capture * 2
	spu_irq_check(a, 2)
	spu.ram[a] = u8(s)
	spu.ram[a + 1] = u8(s >> 8)
}

@(private)
spu_mix :: proc() -> [2]i16 {
	cnt := reg(SPU_CNT)
	noise_tick()
	sum, wet_in: [2]i32
	eon := reg(SPU_EON) | reg(SPU_EON + 2) << 16
	for n in u32(0) ..< SPU_VOICES {
		l, r := voice_sample(n)
		sum += {l, r}
		if eon & (1 << n) != 0 {
			wet_in += {l, r}
		}
	}
	if cnt & SPUCNT_UNMUTE == 0 {
		sum, wet_in = {}, {}
	}
	cd := xa_sample()
	if cnt & SPUCNT_CD_ENABLE != 0 {
		sum[0] += cd[0] * i32(i16(u16(reg(0x1b0)))) >> 15
		sum[1] += cd[1] * i32(i16(u16(reg(0x1b2)))) >> 15
	}
	capture_write(0x000, cd[0])
	capture_write(0x400, cd[1])
	capture_write(0x800, spu.voices[1].out)
	capture_write(0xc00, spu.voices[3].out)
	spu.capture = (spu.capture + 1) & 0x1ff
	wet := reverb_tick(wet_in)
	out: [2]i16
	for c in 0 ..< 2 {
		s := clamp(sum[c], -0x8000, 0x7fff)
		s = s * volume(&spu.main_vol[c], reg(0x180 + u32(c) * 2)) >> 15
		out[c] = i16(clamp(s + wet[c], -0x8000, 0x7fff))
	}
	return out
}

// Mix one batch and hand it to the host.
@(private)
spu_batch :: proc() {
	for &frame in spu.batch {
		frame = spu_mix()
	}
	platform_audio(spu.batch[:])
}

// The mixing thread. spu_event only counts batches due; the thread mixes
// them while the machine runs on. Whatever reads or changes the SPU or the
// CD audio input (registers, sound RAM, DMA, XA sectors) calls spu_sync
// first, which waits for the thread and mixes what is left, so every batch
// sees the state it would have seen mixed at its event. Batches go to the
// thread SPU_HANDOFF at a time, so a wake comes once per few batches; the
// game touches the SPU in under a tenth of batch gaps. With the sound RAM
// IRQ on, and in a forked child (fork copies no threads), batches mix at
// their event as before: the IRQ must be raised on the machine's thread.
@(private)
spu_mixer: struct {
	// Batches due (written by the machine) and mixed.
	posted, done: i64,
	// The thread has mixed what it saw posted and waits for a wake.
	idle:         bool,
	wake:         sync.Sema,
	// Batches handed over since the thread was last seen idle.
	running:      bool,
	started:      bool,
}

@(private)
SPU_HANDOFF :: 4

@(private)
spu_event :: proc() {
	// Counted from the due cycle: from the handling one, the batches fell
	// about 0.9% short of 44100 Hz, more than audio_step corrects, and the
	// host queue ran dry every few seconds.
	schedule_period(.Spu, SAMPLE_CYCLES * SPU_BATCH)
	m := &spu_mixer
	if preload_child || reg(SPU_CNT) & SPUCNT_IRQ_ENABLE != 0 {
		spu_sync()
		spu_batch()
		return
	}
	sync.atomic_store_explicit(&m.posted, m.posted + 1, .Release)
	if m.running && sync.atomic_load_explicit(&m.idle, .Acquire) {
		m.running = false
	}
	if m.running || m.posted - m.done < SPU_HANDOFF {
		return
	}
	if !m.started {
		m.started = true
		thread.start(thread.create(spu_mixer_thread))
	}
	m.running = true
	sync.atomic_store(&m.idle, false)
	sync.sema_post(&m.wake)
}

@(private)
spu_mixer_thread :: proc(_: ^thread.Thread) {
	m := &spu_mixer
	for {
		sync.sema_wait(&m.wake)
		for d := m.done; d != sync.atomic_load_explicit(&m.posted, .Acquire); d += 1 {
			spu_batch()
			sync.atomic_store_explicit(&m.done, d + 1, .Release)
		}
		sync.atomic_store_explicit(&m.idle, true, .Release)
	}
}

// Bring the mix up to the machine's time: wait for the thread, then mix the
// batches it was not handed.
spu_sync :: proc() {
	m := &spu_mixer
	if m.running {
		for spin := 0; !sync.atomic_load_explicit(&m.idle, .Acquire); spin += 1 {
			stream_pause(spin)
		}
		m.running = false
	}
	for ; m.done != m.posted; m.done += 1 {
		spu_batch()
	}
}

dma_spu :: proc(c: ^Dma_Channel) {
	spu_sync()
	n := dma_words(c)
	a := c.madr & 0x1ffffc
	to_spu := c.chcr & 1 != 0
	start := spu.addr & (SPU_RAM_SIZE - 4)
	for _ in 0 ..< n {
		s := spu.addr & (SPU_RAM_SIZE - 4)
		spu_irq_check(s, 4)
		if to_spu {
			w := r32(a)
			for k in u32(0) ..< 4 {
				spu.ram[s + k] = u8(w >> (8 * k))
			}
		} else {
			w32(a, u32(spu.ram[s]) | u32(spu.ram[s + 1]) << 8 | u32(spu.ram[s + 2]) << 16 | u32(spu.ram[s + 3]) << 24)
		}
		spu.addr += 4
		a += 4
	}
	if to_spu && dma_spu_hook != nil {
		dma_spu_hook(start, n * 4)
	}
}

// Run after DMA moved data into sound RAM: the sound RAM address and byte
// count; the qol package uses it to see where a map's sound bank lands.
dma_spu_hook: proc(addr, size: u32)

// Whether voice n sounds a sample that loops: from its current block on,
// the first block with the end flag also has the repeat flag. False when
// the voice is off or released.
voice_loops :: proc(n: int) -> bool {
	spu_sync()
	v := &spu.voices[n]
	if v.phase == .Off || v.phase == .Release {
		return false
	}
	if v.flags & 1 != 0 {
		return v.flags & 2 != 0
	}
	a := v.addr & (SPU_RAM_SIZE - 16)
	for _ in 0 ..< SPU_RAM_SIZE / 16 {
		if f := spu.ram[a + 1]; f & 1 != 0 {
			return f & 2 != 0
		}
		a = (a + 16) & (SPU_RAM_SIZE - 16)
	}
	return false
}

// Sound RAM, for the qol package to keep and put back a map's sound bank.
sound_ram :: proc() -> ^[SPU_RAM_SIZE]u8 {
	spu_sync()
	return &spu.ram
}
