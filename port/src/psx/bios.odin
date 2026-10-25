// High-level emulation of the BIOS A/B/C function tables the game calls, plus
// interrupt delivery through the HookEntryInt jump buffer.
package psx

import "core:fmt"
import "core:os"
import "core:strings"

import "ps:core"

@(private)
bios: struct {
	// HookEntryInt jump buffer: [0]=ra [1]=sp [2]=fp [3..10]=s0-s7 [11]=gp.
	hook:      u32,
	rand_seed: u32,
	pad_buf:   [2]u32,
	// SysEnqIntRP chain heads by priority.
	chains:    [4]u32,
}

// The seed of the BIOS rand() (A0:2F), where the game's random numbers come
// from.
rand_seed :: proc() -> u32 {
	return bios.rand_seed
}

set_rand_seed :: proc(seed: u32) {
	bios.rand_seed = seed
}

@(private)
arg :: #force_inline proc(n: u32) -> u32 {
	if n < 4 {
		return cpu.r[4 + n]
	}
	return r32(cpu.r[29] + 4 * n)
}

@(private)
ret :: #force_inline proc(v: u32) {
	cpu.r[2] = v
}

// BIOS pad driver: after InitPad, every vblank stores port 1 as a digital
// pad (status 0, id 0x41, buttons active-low in transfer order) and port 2
// as absent.
bios_pad_vblank :: proc() {
	if bios.pad_buf[0] != 0 {
		b := ~pad_game()
		w8(bios.pad_buf[0], 0x00)
		w8(bios.pad_buf[0] + 1, 0x41)
		w8(bios.pad_buf[0] + 2, u8(b >> 8))
		w8(bios.pad_buf[0] + 3, u8(b))
	}
	if bios.pad_buf[1] != 0 {
		w8(bios.pad_buf[1], 0xff)
	}
}

bios_a :: proc(fn: u32) {
	if .Bios in core.trace.active {
		core.tracef(.Bios, "A(%02xh) a0=%x a1=%x a2=%x ra=%x", fn, arg(0), arg(1), arg(2), cpu.r[31])
	}
	switch fn {
	case 0x13:
		bios_setjmp(arg(0))
	case 0x17:
		ret(u32(i32(strings.compare(mem_cstring(arg(0), 0x10000), mem_cstring(arg(1), 0x10000)))))
	case 0x18:
		n := arg(2)
		ret(u32(i32(strings.compare(mem_cstring(arg(0), n), mem_cstring(arg(1), n)))))
	case 0x19:
		s := mem_cstring(arg(1), 0x10000)
		copy(mem_slice(arg(0), u32(len(s)) + 1), transmute([]u8)s)
		w8(arg(0) + u32(len(s)), 0)
		ret(arg(0))
	case 0x28:
		bios_memset(arg(0), 0, arg(1))
		ret(arg(0))
	case 0x2a:
		bios_memcpy(arg(0), arg(1), arg(2))
		ret(arg(0))
	case 0x2b:
		bios_memset(arg(0), u8(arg(1)), arg(2))
		ret(arg(0))
	case 0x2f:
		bios.rand_seed = bios.rand_seed * 0x41c64e6d + 0x3039
		ret((bios.rand_seed >> 16) & 0x7fff)
	case 0x30:
		bios.rand_seed = arg(0)
	case 0x39, 0x44, 0x72:
	// InitHeap, FlushCache, CdRemove: nothing to do.
	case 0x3f:
		fmt.eprint("[printf] ", bios_format(mem_cstring(arg(0)), 1), sep = "")
	case 0x49:
		gp0_write(arg(0))
	case 0x70:
		ret(1) // _bu_init
	case 0xab, 0xac:
		// _card_info / _card_load: complete at once.
		card_info(arg(0))
		ret(1)
	case:
		bios_unknown("A", fn)
	}
}

bios_b :: proc(fn: u32) {
	if .Bios in core.trace.active {
		core.tracef(.Bios, "B(%02xh) a0=%x a1=%x a2=%x ra=%x", fn, arg(0), arg(1), arg(2), cpu.r[31])
	}
	switch fn {
	case 0x07:
		deliver_event(arg(0), arg(1))
		ret(1)
	case 0x08:
		ret(open_event(arg(0), arg(1), arg(2), arg(3)))
	case 0x09:
		ret(close_event(arg(0)))
	case 0x0a:
		ret(1)
	case 0x0b:
		ret(test_event(arg(0)))
	case 0x0c:
		ret(set_event_status(arg(0), EV_ENABLED))
	case 0x0d:
		ret(set_event_status(arg(0), EV_DISABLED))
	case 0x0e:
		ret(open_thread(arg(0), arg(1), arg(2)))
	case 0x0f:
		ret(close_thread(arg(0)))
	case 0x10:
		change_thread(arg(0))
	case 0x12:
		bios.pad_buf = {arg(0), arg(2)}
		ret(2)
	case 0x13, 0x14, 0x5b:
		ret(1) // StartPAD, StopPAD, ChangeClearPad
	case 0x15:
		bios.pad_buf = {arg(0), arg(1)}
		ret(1)
	case 0x17:
	// ReturnFromException: interrupt handlers return normally here.
	case 0x18:
		bios.hook = 0
	case 0x19:
		bios.hook = arg(0)
	case 0x32:
		ret(card_open(mem_cstring(arg(0)), arg(1)))
	case 0x33:
		ret(card_seek(arg(0), arg(1), arg(2)))
	case 0x34:
		ret(card_rw(arg(0), arg(1), arg(2), false))
	case 0x35:
		ret(card_rw(arg(0), arg(1), arg(2), true))
	case 0x36:
		ret(card_close(arg(0)))
	case 0x3f:
		fmt.eprintln("[puts]", mem_cstring(arg(0)))
	case 0x42:
		ret(card_nextfile(arg(1), true, mem_cstring(arg(0))))
	case 0x43:
		ret(card_nextfile(arg(0), false))
	case 0x45:
		ret(card_erase(mem_cstring(arg(0))))
	case 0x4a, 0x4b, 0x4c, 0x50:
		ret(1) // InitCARD, StartCARD, StopCARD, allow_new_card
	case 0x4e, 0x4f:
		ret(card_sector(arg(0), arg(1), arg(2), fn == 0x4e))
	case 0x5c:
		ret(0)
	case 0x56:
		ret(FAKE_C0_TABLE)
	case 0x57:
		ret(FAKE_B0_TABLE)
	case:
		bios_unknown("B", fn)
	}
}

bios_c :: proc(fn: u32) {
	if .Bios in core.trace.active {
		core.tracef(.Bios, "C(%02xh) a0=%x a1=%x a2=%x ra=%x", fn, arg(0), arg(1), arg(2), cpu.r[31])
	}
	switch fn {
	case 0x02:
		int_chain_enqueue(arg(0), arg(1))
		ret(0)
	case 0x03:
		int_chain_dequeue(arg(0), arg(1))
		ret(0)
	case 0x0a:
		ret(1) // ChangeClearRCnt
	case:
		bios_unknown("C", fn)
	}
}

@(private)
bios_unknown :: proc(table: string, fn: u32) {
	fmt.eprintfln("fatal: unimplemented BIOS %s(%02xh) (ra %#08x)", table, fn, cpu.r[31])
	os.exit(1)
}

@(private)
bios_setjmp :: proc(buf: u32) {
	w32(buf, cpu.r[31])
	w32(buf + 4, cpu.r[29])
	w32(buf + 8, cpu.r[30])
	for i in u32(0) ..< 8 {
		w32(buf + 12 + i * 4, cpu.r[16 + i])
	}
	w32(buf + 44, cpu.r[28])
	ret(0)
}

@(private)
bios_memcpy :: proc(dst, src, n: u32) {
	for i in u32(0) ..< n {
		w8(dst + i, r8(src + i))
	}
}

@(private)
bios_memset :: proc(dst: u32, v: u8, n: u32) {
	for i in u32(0) ..< n {
		w8(dst + i, v)
	}
}

// Minimal printf for debug output; `first` is the index of the first vararg.
@(private)
bios_format :: proc(f: string, first: u32) -> string {
	b := strings.builder_make(context.temp_allocator)
	n := first
	i := 0
	for i < len(f) {
		ch := f[i]
		i += 1
		if ch != '%' || i >= len(f) {
			strings.write_byte(&b, ch)
			continue
		}
		for i < len(f) && strings.index_byte("0123456789-+ #.lh", f[i]) >= 0 {
			i += 1
		}
		if i >= len(f) {
			break
		}
		conv := f[i]
		i += 1
		switch conv {
		case 'd', 'i':
			fmt.sbprint(&b, i32(arg(n)))
		case 'u':
			fmt.sbprint(&b, arg(n))
		case 'x', 'X', 'p':
			fmt.sbprintf(&b, "%x", arg(n))
		case 'c':
			strings.write_byte(&b, u8(arg(n)))
		case 's':
			strings.write_string(&b, mem_cstring(arg(n)))
		case '%':
			strings.write_byte(&b, '%')
			continue
		}
		n += 1
	}
	return strings.to_string(b)
}

// GetC0Table/GetB0Table: PsyQ libraries patch BIOS handler code reached
// through these tables. Point them at scratch kernel RAM so the patches land
// somewhere harmless; the HLE BIOS never executes that code.
@(private)
FAKE_C0_TABLE :: 0x200
@(private)
FAKE_B0_TABLE :: 0x300

// Device control block table (pointer at 0x150, byte size at 0x154). PsyQ's
// firstfile() looks up the "bu" device here and patches its handler; the
// HLE file functions never call through it, so one named entry is enough.
@(private)
FAKE_DCB_TABLE :: 0x3000

@(private)
DCB_SIZE :: 0x50

bios_init :: proc() {
	w32(FAKE_C0_TABLE + 0x18, 0x1000)
	w32(FAKE_B0_TABLE + 0x16c, 0x2000)
	bios_memset(FAKE_DCB_TABLE, 0, DCB_SIZE + 4)
	copy(mem_slice(FAKE_DCB_TABLE + DCB_SIZE, 3), "bu\x00")
	w32(FAKE_DCB_TABLE, FAKE_DCB_TABLE + DCB_SIZE)
	w32(0x150, FAKE_DCB_TABLE)
	w32(0x154, DCB_SIZE)
	threads_init()
}

// ---------------------------------------------------------------- events

@(private)
EV_DISABLED :: 0x1000
@(private)
EV_ENABLED :: 0x2000
@(private)
EV_READY :: 0x4000
@(private)
EV_MODE_CALLBACK :: 0x1000

@(private)
Bios_Event :: struct {
	class, spec, mode, status, func: u32,
}

@(private)
MAX_EVENTS :: 32

@(private)
events_tab: [MAX_EVENTS]Bios_Event

@(private)
event_slot :: proc(h: u32) -> ^Bios_Event {
	i := h & 0xffff
	if h & 0xffff0000 != 0xf1000000 || i >= MAX_EVENTS || events_tab[i].status == 0 {
		return nil
	}
	return &events_tab[i]
}

@(private)
open_event :: proc(class, spec, mode, func: u32) -> u32 {
	for &e, i in events_tab {
		if e.status == 0 {
			e = {class, spec, mode, EV_DISABLED, func}
			return 0xf1000000 | u32(i)
		}
	}
	fmt.eprintfln("bios: event table full (class %#x spec %#x)", class, spec)
	return 0xffffffff
}

@(private)
close_event :: proc(h: u32) -> u32 {
	if e := event_slot(h); e != nil {
		e^ = {}
		return 1
	}
	return 0
}

@(private)
set_event_status :: proc(h, status: u32) -> u32 {
	if e := event_slot(h); e != nil {
		e.status = status
		return 1
	}
	return 0
}

@(private)
test_event :: proc(h: u32) -> u32 {
	e := event_slot(h)
	if e == nil || e.status != EV_READY {
		return 0
	}
	e.status = EV_ENABLED
	return 1
}

deliver_event :: proc(class, spec: u32) {
	for &e in events_tab {
		if e.status != EV_ENABLED || e.class != class || e.spec & spec == 0 {
			continue
		}
		if e.mode == EV_MODE_CALLBACK && e.func != 0 {
			hle_call(e.func)
		} else {
			e.status = EV_READY
		}
	}
}

// Call guest code from HLE without disturbing the caller's registers.
@(private)
hle_call :: proc(addr: u32) {
	saved := cpu
	call(addr)
	cycles := cpu.cycles
	cpu = saved
	cpu.cycles = cycles
}

// ---------------------------------------------------------------- interrupts

// Run the game's interrupt handler the way the BIOS would: switch to the
// registers saved by setjmp in the HookEntryInt buffer and enter the code that
// follows that setjmp's "returned nonzero" branch. libetc places a call to its
// dispatcher (trapIntr) there; on hardware that dispatcher ends in
// ReturnFromException, which is a no-op here, so it simply returns.
deliver_irq :: proc() {
	target: u32 = 0
	if bios.hook != 0 {
		target = hook_target(r32(bios.hook))
	}
	if target == 0 && bios.chains == {} {
		return
	}
	if .Irq in core.trace.active {
		core.tracef(.Irq, "deliver stat=%x mask=%x hook=%x", irq_regs.stat, irq_regs.mask, target)
	}
	saved_cpu := cpu
	saved_sr := cop0.sr
	// Exception entry: push the interrupt-enable stack, disabling interrupts.
	cop0.sr = (cop0.sr & ~u32(0x3f)) | ((cop0.sr << 2) & 0x3c)
	irq_regs.in_handler = true
	run_int_chains()
	if target != 0 {
		buf := bios.hook
		cpu.r[29] = r32(buf + 4)
		cpu.r[30] = r32(buf + 8)
		for i in u32(0) ..< 8 {
			cpu.r[16 + i] = r32(buf + 12 + i * 4)
		}
		cpu.r[28] = r32(buf + 44)
		cpu.r[2] = 1
		call(target)
	}
	irq_regs.in_handler = false
	cycles := cpu.cycles
	cpu = saved_cpu
	cpu.cycles = cycles
	cop0.sr = saved_sr
}

// SysEnqIntRP chains, highest priority (0) first. Each element is
// {next, second, first, unused}: first() runs on every interrupt and, when it
// returns nonzero, second(result) runs. libpad polls the pad from one.
@(private)
run_int_chains :: proc() {
	for head in bios.chains {
		e := head
		for guard := 0; e != 0 && guard < 64; guard += 1 {
			first := r32(e + 8)
			second := r32(e + 4)
			next := r32(e)
			if first != 0 {
				call(first)
				if v := cpu.r[2]; v != 0 && second != 0 {
					cpu.r[4] = v
					call(second)
				}
			}
			e = next
		}
	}
}

@(private)
int_chain_enqueue :: proc(pri, elem: u32) {
	if pri >= len(bios.chains) {
		return
	}
	int_chain_dequeue(pri, elem)
	w32(elem, bios.chains[pri])
	bios.chains[pri] = elem
}

@(private)
int_chain_dequeue :: proc(pri, elem: u32) {
	if pri >= len(bios.chains) {
		return
	}
	if bios.chains[pri] == elem {
		bios.chains[pri] = r32(elem)
		return
	}
	e := bios.chains[pri]
	for guard := 0; e != 0 && guard < 64; guard += 1 {
		if r32(e) == elem {
			w32(e, r32(elem))
			return
		}
		e = r32(e)
	}
}

// The setjmp return site is `beqz v0, X; nop; jal T`: the handler is T.
@(private)
hook_target :: proc(ra: u32) -> u32 {
	for k in u32(0) ..< 4 {
		w := r32(ra + k * 4)
		if w >> 26 == 0x03 {
			return ((ra + k * 4) & 0xf0000000) | ((w & 0x3ffffff) << 2)
		}
	}
	fmt.eprintfln("bios: HookEntryInt return site %#08x has no handler call", ra)
	return 0
}

// ---------------------------------------------------------------- threads

@(private)
MAX_THREADS :: 16

@(private)
Bios_Thread :: struct {
	used:  bool,
	regs:  Cpu,
	sr:    u32,
	entry: u32,
	co:    ^core.Coroutine,
}

@(private)
threads: [MAX_THREADS]Bios_Thread

// Index of the running thread; 0 is the main thread (handle 0xff000000).
@(private)
cur_thread: int

// Coroutine of a thread that closed itself. It keeps running until it
// switches away; the next thread to run then discards it.
@(private)
zombie: ^core.Coroutine

@(private)
reap_zombie :: proc() {
	if zombie != nil {
		core.co_kill(zombie)
		zombie = nil
	}
}

@(private)
threads_init :: proc() {
	threads[0] = {
		used = true,
		co   = &core.co_main_thread,
	}
	cur_thread = 0
}

@(private)
open_thread :: proc(pc, sp, gp: u32) -> u32 {
	for &t, i in threads {
		if t.used {
			continue
		}
		t = {
			used  = true,
			entry = pc,
			// The BIOS stores 0x40000404 and enters the thread with rfe;
			// threads[].sr holds the live value after that rfe.
			sr    = 0x40000401,
		}
		t.regs.r[29] = sp
		t.regs.r[30] = sp
		t.regs.r[28] = gp
		t.co = core.co_create(thread_entry, rawptr(uintptr(i)))
		return 0xff000000 | u32(i)
	}
	fmt.eprintln("bios: thread table full")
	return 0xffffffff
}

@(private)
thread_entry :: proc(arg: rawptr) {
	i := int(uintptr(arg))
	reap_zombie()
	call(threads[i].entry)
	fmt.eprintfln("fatal: thread %d returned from its entry %#08x", i, threads[i].entry)
	os.exit(1)
}

@(private)
close_thread :: proc(h: u32) -> u32 {
	i := int(h & 0xffff)
	if i == 0 || i >= MAX_THREADS || !threads[i].used {
		return 0
	}
	if i == cur_thread {
		zombie = threads[i].co
	} else {
		core.co_kill(threads[i].co)
	}
	threads[i] = {}
	return 1
}

@(private)
change_thread :: proc(h: u32) {
	i := int(h & 0xffff)
	if i >= MAX_THREADS || !threads[i].used {
		fmt.eprintfln("bios: ChangeTh to bad handle %#x", h)
		ret(0)
		return
	}
	if i == cur_thread {
		ret(1)
		return
	}
	from := &threads[cur_thread]
	to := &threads[i]
	ret(1)
	// A thread that closed itself has no slot to save into; OpenTh may even
	// have reused it. Any other zombie was reaped when this thread resumed.
	if zombie == nil {
		from.regs = cpu
		from.sr = cop0.sr
	}
	cycles := cpu.cycles
	cpu = to.regs
	cpu.cycles = cycles
	cop0.sr = to.sr
	cur_thread = i
	core.co_switch(to.co)
	// Resumed: whoever switched back already loaded our registers.
	reap_zombie()
}
