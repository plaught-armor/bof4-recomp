// R3000A CPU state and the call dispatcher shared by recompiled code, the
// interpreter and HLE.
//
// Recompiled functions are host procedures. A MIPS `jal` becomes a host call
// through `call`, and `jr $ra` becomes a host return, so the MIPS return
// address only matters to code that inspects it. `call` resolves a target in
// this order: hand-written override, recompiled executable function, BIOS
// vector, recompiled overlay function whose overlay is resident, interpreter.
package psx

import "core:fmt"
import "core:os"

import "ps:core"

Cpu :: struct {
	r:      [32]u32,
	hi, lo: u32,
	// Instructions retired; the time base for every device.
	cycles: u64,
}

cpu: Cpu

// Cycle count at which run_events must next be called.
next_event: u64

Func_Proc :: #type proc()

Func_Entry :: struct {
	addr: u32,
	fn:   Func_Proc,
}

// Recompiled function of one overlay: valid while `id` (the overlay's first
// word) is at `slot` in RAM and the function's first code words are `sig`.
// The signature catches a different overlay loaded over part of this one
// without touching its header.
Ovl_Entry :: struct {
	addr: u32,
	slot: u32,
	id:   u32,
	sig:  [4]u32,
	fn:   Func_Proc,
}

@(private)
ovl_resident :: #force_inline proc(e: ^Ovl_Entry) -> bool {
	if r32(e.slot) != e.id {
		return false
	}
	for w, k in e.sig {
		if r32(e.addr + u32(k) * 4) != w {
			return false
		}
	}
	return true
}

@(private)
FN_TABLE_SIZE :: RAM_SIZE / 4

@(private)
dispatch: struct {
	// Executable functions and overrides, indexed by RAM word.
	fixed:     []Func_Proc,
	overlay:   map[u32][dynamic]Ovl_Entry,
	reported:  map[u32]bool,
}

@(private)
fn_index :: #force_inline proc(addr: u32) -> u32 {
	return (addr & (RAM_SIZE - 1)) >> 2
}

@(private)
is_ram_addr :: #force_inline proc(addr: u32) -> bool {
	return addr & 0x1fffffff < 0x800000
}

register_funcs :: proc(entries: []Func_Entry) {
	if dispatch.fixed == nil {
		dispatch.fixed = make([]Func_Proc, FN_TABLE_SIZE)
	}
	for e in entries {
		dispatch.fixed[fn_index(e.addr)] = e.fn
	}
}

register_overlay_funcs :: proc(entries: []Ovl_Entry) {
	for e in entries {
		list := dispatch.overlay[e.addr]
		append(&list, e)
		dispatch.overlay[e.addr] = list
	}
}

// Read by recompiled code at patch points (tools/recomp.odin PATCHES): skip
// the game's test that drops a map tile or model part with no projected
// corner on screen. Set while a camera close to the scenery is in use.
tiles_unculled: bool

// Replace the executable's function at addr with a hand-written procedure.
// Returns the recompiled one so the replacement can fall back to it; ok is
// false when no function was recompiled at addr.
hook :: proc(addr: u32, fn: Func_Proc) -> (original: Func_Proc, ok: bool) {
	if dispatch.fixed == nil || !is_ram_addr(addr) || addr & 3 != 0 {
		return nil, false
	}
	slot := &dispatch.fixed[fn_index(addr)]
	if slot^ == nil {
		return nil, false
	}
	original, slot^ = slot^, fn
	return original, true
}

// Replace the recompiled function at addr of overlay `id` at `slot` with a
// hand-written procedure. Returns the recompiled one so the replacement can
// fall back to it; ok is false when no such function was recompiled.
hook_overlay :: proc(addr, slot, id: u32, fn: Func_Proc) -> (original: Func_Proc, ok: bool) {
	list := dispatch.overlay[addr] or_return
	for &e in list {
		if e.slot == slot && e.id == id {
			original, e.fn = e.fn, fn
			return original, true
		}
	}
	return nil, false
}

// Return address of the innermost host-level call.
frame_ret: u32

// Execute the MIPS function at addr and return when it returns.
call :: proc(addr: u32) {
	// A jump to the caller's return address through a register other than
	// $ra (hand-written code saves $ra elsewhere) is a return; track it.
	if .Call in core.trace.active && core.trace_pc_ok(addr) {
		core.tracef(.Call, "%08x ra=%x sp=%x a0=%x a1=%x", addr, cpu.r[31], cpu.r[29], cpu.r[4], cpu.r[5])
	}
	outer := frame_ret
	frame_ret = cpu.r[31]
	defer frame_ret = outer
	if is_ram_addr(addr) && addr & 3 == 0 {
		if fn := dispatch.fixed[fn_index(addr)]; fn != nil {
			fn()
			return
		}
	}
	call_slow(addr)
}

@(private)
resolve_overlay :: proc(addr: u32) -> Func_Proc {
	list, ok := dispatch.overlay[addr]
	if !ok {
		return nil
	}
	for &e, k in list {
		if ovl_resident(&e) {
			if k != 0 {
				// Keep the resident variant first for the next lookup.
				list[0], list[k] = list[k], list[0]
				return list[0].fn
			}
			return e.fn
		}
	}
	return nil
}

@(private)
call_slow :: proc(addr: u32) {
	switch addr & 0x1fffffff {
	case 0xa0:
		bios_a(cpu.r[9])
		return
	case 0xb0:
		bios_b(cpu.r[9])
		return
	case 0xc0:
		bios_c(cpu.r[9])
		return
	}
	if fn := resolve_overlay(addr); fn != nil {
		fn()
		return
	}
	report_once(addr, "interpreting")
	interp_run(addr)
}

report_once :: proc(addr: u32, what: string) {
	if !dispatch.reported[addr] {
		dispatch.reported[addr] = true
		fmt.eprintfln("%s %#08x (ra %#08x) at present %d", what, addr, cpu.r[31], host.presents)
		// With BOF4_DUMP, keep RAM as it was so the code can be identified.
		if dir := core.dump_dir(); dir != "" {
			name := fmt.tprintf("%s/ram_interp_%08x.bin", dir, addr)
			if err := os.write_entire_file(name, ram[:]); err != nil {
				fmt.eprintln("BOF4_DUMP: ram write failed:", name, err)
			}
		}
	}
}

// A recompiled function jumped to pc, which is not one of its block labels.
jump_unknown :: proc(func, pc: u32) {
	if pc == frame_ret {
		return
	}
	if pc < func || !is_ram_addr(pc) {
		call(pc)
		return
	}
	if is_ram_addr(pc) && dispatch.fixed[fn_index(pc)] != nil || resolve_overlay(pc) != nil {
		call(pc)
		return
	}
	report_once(pc, "unlabelled jump target, interpreting")
	interp_run(pc)
}

mult :: #force_inline proc(a, b: u32) {
	p := i64(i32(a)) * i64(i32(b))
	cpu.lo = u32(p)
	cpu.hi = u32(u64(p) >> 32)
}

multu :: #force_inline proc(a, b: u32) {
	p := u64(a) * u64(b)
	cpu.lo = u32(p)
	cpu.hi = u32(p >> 32)
}

div :: proc(a, b: u32) {
	n, d := i32(a), i32(b)
	switch {
	case d == 0:
		cpu.hi = a
		cpu.lo = n >= 0 ? 0xffffffff : 1
	case a == 0x80000000 && d == -1:
		cpu.lo = 0x80000000
		cpu.hi = 0
	case:
		cpu.lo = u32(n / d)
		cpu.hi = u32(n % d)
	}
}

divu :: proc(a, b: u32) {
	if b == 0 {
		cpu.lo = 0xffffffff
		cpu.hi = a
		return
	}
	cpu.lo = a / b
	cpu.hi = a % b
}

brk :: proc(pc, code: u32) {
	fmt.eprintfln("break %#x at %#08x", code, pc)
}

bad_insn :: proc(pc, w: u32) {
	fmt.eprintfln("fatal: reserved instruction %#08x at %#08x", w, pc)
	ram_dump_env()
	os.exit(1)
}

// Debug aid: BOF4_RAMDUMP=<file> saves main RAM for post-mortem; called
// where the port exits on purpose.
ram_dump_env :: proc() {
	if path := os.get_env("BOF4_RAMDUMP", context.temp_allocator); path != "" {
		if err := os.write_entire_file(path, ram[:]); err != nil {
			fmt.eprintln("BOF4_RAMDUMP: write failed:", path, err)
		}
	}
}

// ---------------------------------------------------------------- COP0

COP0_SR :: 12
COP0_CAUSE :: 13
COP0_EPC :: 14

cop0: struct {
	sr:    u32,
	cause: u32,
	epc:   u32,
}

mfc0 :: proc(r: u32) -> u32 {
	switch r {
	case COP0_SR:
		return cop0.sr
	case COP0_CAUSE:
		return cop0.cause
	case COP0_EPC:
		return cop0.epc
	case 15:
		return 2 // PRId
	}
	return 0
}

mtc0 :: proc(r, v: u32) {
	switch r {
	case COP0_SR:
		cop0.sr = v
		irq_check()
	case COP0_CAUSE:
		cop0.cause = (cop0.cause & ~u32(0x300)) | (v & 0x300)
	}
}

rfe :: proc() {
	cop0.sr = (cop0.sr & ~u32(0xf)) | ((cop0.sr >> 2) & 0xf)
}

// `syscall`: the only users are EnterCriticalSection (a0=1) and
// ExitCriticalSection (a0=2), which the BIOS implements by editing SR.
syscall :: proc(pc: u32) {
	switch cpu.r[4] {
	// The BIOS edits the SR saved on exception entry (bits 0x404), which rfe
	// turns into the live IEc/IM2 bits 0x401; edit those directly.
	case 1:
		cpu.r[2] = (cop0.sr & 0x401) == 0x401 ? 1 : 0
		cop0.sr &= ~u32(0x401)
	case 2:
		cop0.sr |= 0x401
		irq_check()
	case 0:
		// NoFunction
	case:
		fmt.eprintfln("syscall %d at %#08x", cpu.r[4], pc)
	}
}
