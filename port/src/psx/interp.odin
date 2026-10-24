// Fallback interpreter for code the recompiler did not cover (overlays not yet
// recompiled, unlabelled jump targets).
//
// It follows the same calling convention as recompiled code: `jal`/`jalr`
// become host calls through `call`, and `jr $ra` returns from interp_run.
// Plain jumps stay inside the interpreter unless they land on a function the
// dispatcher knows, in which case they become a tail call.
package psx

import "core:fmt"
import "core:os"

@(private)
INTERP_EVENT_STRIDE :: 64

@(private)
Interp :: struct {
	pc:     u32,
	// Branch target pending after the current delay slot, if any.
	target: u32,
	taken:  bool,
	done:   bool,
}

interp_run :: proc(start: u32) {
	st := Interp {
		pc = start,
	}
	budget := 0
	for !st.done {
		w := lw(st.pc)
		pc := st.pc
		st.pc += 4
		if .Interp in trace.active && trace_pc_ok(pc) {
			tracef(.Interp, "%08x %08x", pc, w)
		}
		interp_exec(&st, pc, w)
		cpu.r[0] = 0
		cpu.cycles += CYCLES_PER_INSN
		budget += 1
		if budget >= INTERP_EVENT_STRIDE {
			budget = 0
			if cpu.cycles >= next_event {
				run_events()
			}
		}
	}
}

// Average R3000A cost per instruction including memory stalls; matches
// CYCLES_PER_INSN in tools/recomp.odin. Native rewrites use it for the cycles
// they charge under BOF4_MAPCHECK and old replays (psx.charge_native).
CYCLES_PER_INSN :: 2

// Execute the delay slot at st.pc, then follow a taken branch to target.
@(private)
branch :: proc(st: ^Interp, taken: bool, target: u32) {
	slot := st.pc
	w := lw(slot)
	st.pc += 4
	if .Interp in trace.active && trace_pc_ok(slot) {
		tracef(.Interp, "%08x %08x (delay)", slot, w)
	}
	interp_exec(st, slot, w)
	cpu.r[0] = 0
	cpu.cycles += CYCLES_PER_INSN
	if taken {
		goto_target(st, target)
	}
}

@(private)
goto_target :: proc(st: ^Interp, target: u32) {
	if is_ram_addr(target) && dispatch.fixed[fn_index(target)] != nil {
		call(target)
		st.done = true
		return
	}
	st.pc = target
}

@(private)
signed_imm :: #force_inline proc(w: u32) -> u32 {
	return u32(i32(i16(u16(w))))
}

@(private)
interp_exec :: proc(st: ^Interp, pc, w: u32) {
	r := &cpu.r
	rs := (w >> 21) & 31
	rt := (w >> 16) & 31
	imm := signed_imm(w)
	addr := r[rs] + imm
	switch w >> 26 {
	case 0x00:
		interp_special(st, pc, w)
	case 0x01:
		interp_regimm(st, pc, w)
	case 0x02:
		branch(st, true, (pc & 0xf0000000) | ((w & 0x3ffffff) << 2))
	case 0x03:
		r[31] = pc + 8
		branch(st, false, 0)
		call((pc & 0xf0000000) | ((w & 0x3ffffff) << 2))
	case 0x04:
		branch(st, r[rs] == r[rt], pc + 4 + (imm << 2))
	case 0x05:
		branch(st, r[rs] != r[rt], pc + 4 + (imm << 2))
	case 0x06:
		branch(st, i32(r[rs]) <= 0, pc + 4 + (imm << 2))
	case 0x07:
		branch(st, i32(r[rs]) > 0, pc + 4 + (imm << 2))
	case 0x08, 0x09:
		r[rt] = r[rs] + imm
	case 0x0a:
		r[rt] = i32(r[rs]) < i32(imm) ? 1 : 0
	case 0x0b:
		r[rt] = r[rs] < imm ? 1 : 0
	case 0x0c:
		r[rt] = r[rs] & (w & 0xffff)
	case 0x0d:
		r[rt] = r[rs] | (w & 0xffff)
	case 0x0e:
		r[rt] = r[rs] ~ (w & 0xffff)
	case 0x0f:
		r[rt] = w << 16
	case 0x10:
		interp_cop0(pc, w)
	case 0x12:
		interp_cop2(pc, w)
	case 0x20:
		r[rt] = lb(addr)
	case 0x21:
		r[rt] = lh(addr)
	case 0x22:
		r[rt] = lwl(addr, r[rt])
	case 0x23:
		r[rt] = lw(addr)
	case 0x24:
		r[rt] = lbu(addr)
	case 0x25:
		r[rt] = lhu(addr)
	case 0x26:
		r[rt] = lwr(addr, r[rt])
	case 0x28:
		sb(addr, r[rt])
	case 0x29:
		sh(addr, r[rt])
	case 0x2a:
		swl(addr, r[rt])
	case 0x2b:
		sw(addr, r[rt])
	case 0x2e:
		swr(addr, r[rt])
	case 0x32:
		gte_write(rt, lw(addr))
	case 0x3a:
		sw(addr, gte_read(rt))
	case:
		bad_insn(pc, w)
	}
}

@(private)
interp_special :: proc(st: ^Interp, pc, w: u32) {
	r := &cpu.r
	rs := (w >> 21) & 31
	rt := (w >> 16) & 31
	rd := (w >> 11) & 31
	sa := (w >> 6) & 31
	switch w & 0x3f {
	case 0x00:
		r[rd] = r[rt] << sa
	case 0x02:
		r[rd] = r[rt] >> sa
	case 0x03:
		r[rd] = u32(i32(r[rt]) >> sa)
	case 0x04:
		r[rd] = r[rt] << (r[rs] & 31)
	case 0x06:
		r[rd] = r[rt] >> (r[rs] & 31)
	case 0x07:
		r[rd] = u32(i32(r[rt]) >> (r[rs] & 31))
	case 0x08:
		t := r[rs]
		branch(st, false, 0)
		if rs == 31 || t == frame_ret {
			st.done = true
		} else {
			goto_target(st, t)
		}
	case 0x09:
		t := r[rs]
		r[rd] = pc + 8
		branch(st, false, 0)
		call(t)
	case 0x0c:
		syscall(pc)
	case 0x0d:
		brk(pc, (w >> 6) & 0xfffff)
	case 0x10:
		r[rd] = cpu.hi
	case 0x11:
		cpu.hi = r[rs]
	case 0x12:
		r[rd] = cpu.lo
	case 0x13:
		cpu.lo = r[rs]
	case 0x18:
		mult(r[rs], r[rt])
	case 0x19:
		multu(r[rs], r[rt])
	case 0x1a:
		div(r[rs], r[rt])
	case 0x1b:
		divu(r[rs], r[rt])
	case 0x20, 0x21:
		r[rd] = r[rs] + r[rt]
	case 0x22, 0x23:
		r[rd] = r[rs] - r[rt]
	case 0x24:
		r[rd] = r[rs] & r[rt]
	case 0x25:
		r[rd] = r[rs] | r[rt]
	case 0x26:
		r[rd] = r[rs] ~ r[rt]
	case 0x27:
		r[rd] = ~(r[rs] | r[rt])
	case 0x2a:
		r[rd] = i32(r[rs]) < i32(r[rt]) ? 1 : 0
	case 0x2b:
		r[rd] = r[rs] < r[rt] ? 1 : 0
	case:
		bad_insn(pc, w)
	}
}

@(private)
interp_regimm :: proc(st: ^Interp, pc, w: u32) {
	r := &cpu.r
	rs := (w >> 21) & 31
	rt := (w >> 16) & 31
	target := pc + 4 + (signed_imm(w) << 2)
	taken := (rt & 1 != 0) == (i32(r[rs]) >= 0)
	if rt & 0x1e == 0x10 {
		r[31] = pc + 8
		branch(st, false, 0)
		if taken {
			call(target)
		}
		return
	}
	branch(st, taken, target)
}

@(private)
interp_cop0 :: proc(pc, w: u32) {
	rt := (w >> 16) & 31
	rd := (w >> 11) & 31
	switch (w >> 21) & 31 {
	case 0x00:
		cpu.r[rt] = mfc0(rd)
	case 0x04:
		mtc0(rd, cpu.r[rt])
	case 0x10:
		if w & 0x3f == 0x10 {
			rfe()
			return
		}
		bad_insn(pc, w)
	case:
		bad_insn(pc, w)
	}
}

@(private)
interp_cop2 :: proc(pc, w: u32) {
	rt := (w >> 16) & 31
	rd := (w >> 11) & 31
	if w & 0x02000000 != 0 {
		gte_cmd(w & 0x1ffffff)
		return
	}
	switch (w >> 21) & 31 {
	case 0x00:
		cpu.r[rt] = gte_read(rd)
	case 0x02:
		cpu.r[rt] = gte_read(rd + 32)
	case 0x04:
		gte_write(rd, cpu.r[rt])
	case 0x06:
		gte_write(rd + 32, cpu.r[rt])
	case:
		fmt.eprintfln("fatal: bad cop2 %#08x at %#08x", w, pc)
		os.exit(1)
	}
}
