// Memory bus: main RAM (2 MiB, mirrored), scratchpad, and memory-mapped I/O.
//
// `lw`/`sw` and friends are what recompiled code uses; they decode the full
// PS1 address map. `r32`/`w32` and friends are the HLE side's direct RAM view
// and never touch I/O.
package psx

import "core:fmt"

RAM_SIZE :: 2 * 1024 * 1024
SCRATCH_BASE :: 0x1f800000
SCRATCH_SIZE :: 1024

ram: [RAM_SIZE]u8
scratch: [SCRATCH_SIZE]u8

// RAM pages, the unit a frozen-time pass saves RAM in (checkpoint.odin).
RAM_PAGE_SHIFT :: 12
RAM_PAGE :: 1 << RAM_PAGE_SHIFT
RAM_PAGES :: RAM_SIZE / RAM_PAGE

// Pages whose next write calls ram_keep (checkpoint.odin): it saves the page
// into the running pass's checkpoint, and gives it a new version. Every RAM
// writer goes through ram_guard or ram_touch.
@(private)
ram_armed: [RAM_PAGES]bool

// Each page's version: a number naming its bytes, changed by ram_keep on
// its first write since the number was last taken (into a checkpoint or a
// draw start, which arm every page). Two copies of a page with the same
// version hold the same bytes; draw_start_load copies only the others.
@(private)
ram_ver: [RAM_PAGES]u32

// The last version handed out.
@(private)
ram_ver_last: u32

// Save RAM offset o's page before a write to it. o is below RAM_SIZE.
@(private)
ram_guard :: #force_inline proc(o: u32) #no_bounds_check {
	if ram_armed[o >> RAM_PAGE_SHIFT] {
		ram_keep(o >> RAM_PAGE_SHIFT)
	}
}

// Save the pages of RAM bytes [addr, addr+n) before they are written; addr
// is masked to RAM as byte_ptr and mem_slice do. Scratchpad addresses are
// left alone (passes copy the scratchpad whole).
ram_touch :: proc(addr: u32, n: u32) {
	if n == 0 || addr & 0x1ffffc00 == SCRATCH_BASE {
		return
	}
	assert(n <= RAM_SIZE, "RAM write wider than RAM")
	o := addr & (RAM_SIZE - 1)
	last := (o + n - 1) & (RAM_SIZE - 1)
	for p := o >> RAM_PAGE_SHIFT; ; p = (p + 1) % RAM_PAGES {
		ram_guard(p << RAM_PAGE_SHIFT)
		if p == last >> RAM_PAGE_SHIFT {
			break
		}
	}
}

// ---------------------------------------------------------------- HLE view

@(private)
byte_ptr :: #force_inline proc(addr: u32) -> ^u8 {
	if addr & 0x1ffffc00 == SCRATCH_BASE {
		return &scratch[addr & (SCRATCH_SIZE - 1)]
	}
	return &ram[addr & (RAM_SIZE - 1)]
}

r8 :: #force_inline proc(addr: u32) -> u8 {return byte_ptr(addr)^}
r16 :: #force_inline proc(addr: u32) -> u16 {return u16((^u16le)(byte_ptr(addr))^)}
r32 :: #force_inline proc(addr: u32) -> u32 {return u32((^u32le)(byte_ptr(addr))^)}
rs8 :: #force_inline proc(addr: u32) -> i8 {return i8(r8(addr))}
rs16 :: #force_inline proc(addr: u32) -> i16 {return i16(r16(addr))}

w8 :: #force_inline proc(addr: u32, v: u8) {ram_touch(addr, 1); byte_ptr(addr)^ = v}
w16 :: #force_inline proc(addr: u32, v: u16) {ram_touch(addr, 2); (^u16le)(byte_ptr(addr))^ = u16le(v)}
w32 :: #force_inline proc(addr: u32, v: u32) {ram_touch(addr, 4); (^u32le)(byte_ptr(addr))^ = u32le(v)}

// Byte slice view of [addr, addr+n) in RAM (no wrap-around). Callers may
// write it, so inside a pass its pages are saved first.
mem_slice :: proc(addr: u32, n: u32) -> []u8 {
	if n == 0 {
		return nil
	}
	off := addr & (RAM_SIZE - 1)
	assert(off + n <= RAM_SIZE, "RAM slice out of range")
	ram_touch(off, n)
	return ram[off:][:n]
}

// NUL-terminated string at addr, for logging.
mem_cstring :: proc(addr: u32, limit: u32 = 256) -> string {
	off := addr & (RAM_SIZE - 1)
	n: u32 = 0
	for n < limit && off + n < RAM_SIZE && ram[off + n] != 0 {
		n += 1
	}
	return string(ram[off:][:n])
}

// Load a PS-X EXE text segment into RAM at its link address.
load_exe :: proc(data: []u8) -> (pc, gp, sp: u32, ok: bool) {
	if len(data) < 0x800 || string(data[:8]) != "PS-X EXE" {
		return
	}
	hdr := proc(d: []u8, o: int) -> u32 {return u32((^u32le)(&d[o])^)}
	pc = hdr(data, 0x10)
	gp = hdr(data, 0x14)
	text := hdr(data, 0x18)
	size := hdr(data, 0x1c)
	sp = hdr(data, 0x30)
	if int(size) + 0x800 > len(data) {
		return
	}
	copy(mem_slice(text, size), data[0x800:][:size])
	ok = true
	return
}

// ---------------------------------------------------------------- CPU view

@(private)
in_ram :: #force_inline proc(a: u32) -> (u32, bool) {
	p := a & 0x1fffffff
	return p & (RAM_SIZE - 1), p < 0x800000
}

lw :: #force_inline proc(a: u32) -> u32 #no_bounds_check {
	if o, ok := in_ram(a); ok {
		return u32((^u32le)(&ram[o])^)
	}
	return load_slow(a, 4)
}

lhu :: #force_inline proc(a: u32) -> u32 #no_bounds_check {
	if o, ok := in_ram(a); ok {
		return u32((^u16le)(&ram[o])^)
	}
	return load_slow(a, 2) & 0xffff
}

lh :: #force_inline proc(a: u32) -> u32 {
	return u32(i32(i16(lhu(a))))
}

lbu :: #force_inline proc(a: u32) -> u32 #no_bounds_check {
	if o, ok := in_ram(a); ok {
		return u32(ram[o])
	}
	return load_slow(a, 1) & 0xff
}

lb :: #force_inline proc(a: u32) -> u32 {
	return u32(i32(i8(lbu(a))))
}

sw :: #force_inline proc(a, v: u32) #no_bounds_check {
	if trace.watching {trace_store(a, v, 4)}
	if o, ok := in_ram(a); ok && cop0.sr & 0x10000 == 0 {
		ram_guard(o)
		(^u32le)(&ram[o])^ = u32le(v)
		return
	}
	store_slow(a, v, 4)
}

sh :: #force_inline proc(a, v: u32) #no_bounds_check {
	if trace.watching {trace_store(a, v & 0xffff, 2)}
	if o, ok := in_ram(a); ok && cop0.sr & 0x10000 == 0 {
		ram_guard(o)
		(^u16le)(&ram[o])^ = u16le(v)
		return
	}
	store_slow(a, v & 0xffff, 2)
}

sb :: #force_inline proc(a, v: u32) {
	if trace.watching {trace_store(a, v & 0xff, 1)}
	if o, ok := in_ram(a); ok && cop0.sr & 0x10000 == 0 {
		ram_guard(o)
		ram[o] = u8(v)
		return
	}
	store_slow(a, v & 0xff, 1)
}

lwl :: proc(a, cur: u32) -> u32 {
	w := lw(a & ~u32(3))
	switch a & 3 {
	case 0:
		return (cur & 0x00ffffff) | (w << 24)
	case 1:
		return (cur & 0x0000ffff) | (w << 16)
	case 2:
		return (cur & 0x000000ff) | (w << 8)
	}
	return w
}

lwr :: proc(a, cur: u32) -> u32 {
	w := lw(a & ~u32(3))
	switch a & 3 {
	case 1:
		return (cur & 0xff000000) | (w >> 8)
	case 2:
		return (cur & 0xffff0000) | (w >> 16)
	case 3:
		return (cur & 0xffffff00) | (w >> 24)
	}
	return w
}

swl :: proc(a, v: u32) {
	al := a & ~u32(3)
	w := lw(al)
	switch a & 3 {
	case 0:
		w = (w & 0xffffff00) | (v >> 24)
	case 1:
		w = (w & 0xffff0000) | (v >> 16)
	case 2:
		w = (w & 0xff000000) | (v >> 8)
	case 3:
		w = v
	}
	sw(al, w)
}

swr :: proc(a, v: u32) {
	al := a & ~u32(3)
	w := lw(al)
	switch a & 3 {
	case 0:
		w = v
	case 1:
		w = (w & 0x000000ff) | (v << 8)
	case 2:
		w = (w & 0x0000ffff) | (v << 16)
	case 3:
		w = (w & 0x00ffffff) | (v << 24)
	}
	sw(al, w)
}

@(private)
load_slow :: proc(a: u32, size: u32) -> u32 {
	p := a & 0x1fffffff
	switch {
	case p & 0x1ffffc00 == SCRATCH_BASE:
		o := p & (SCRATCH_SIZE - 1)
		switch size {
		case 4:
			return u32((^u32le)(&scratch[o])^)
		case 2:
			return u32((^u16le)(&scratch[o])^)
		}
		return u32(scratch[o])
	case p >= 0x1f801000 && p < 0x1f803000:
		return io_read(p, size)
	case p >= 0x1fc00000 && p < 0x1fc80000:
		return 0
	case a == 0xfffe0130:
		return 0
	}
	fmt.eprintfln("bus: read%d from unmapped %#08x (present %d, ra %#08x)", size * 8, a, host.presents, cpu.r[31])
	return 0
}

@(private)
store_slow :: proc(a, v: u32, size: u32) {
	if cop0.sr & 0x10000 != 0 {
		return // cache isolated: BIOS cache flush, writes go nowhere
	}
	p := a & 0x1fffffff
	switch {
	case p & 0x1ffffc00 == SCRATCH_BASE:
		o := p & (SCRATCH_SIZE - 1)
		switch size {
		case 4:
			(^u32le)(&scratch[o])^ = u32le(v)
		case 2:
			(^u16le)(&scratch[o])^ = u16le(v)
		case:
			scratch[o] = u8(v)
		}
	case p >= 0x1f801000 && p < 0x1f803000:
		io_write(p, v, size)
	case a == 0xfffe0130:
	case:
		fmt.eprintfln("bus: write%d %#x to unmapped %#08x (present %d, ra %#08x)", size * 8, v, a, host.presents, cpu.r[31])
	}
}
