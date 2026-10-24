// Disassemble a range of a PS1 code file with jump and branch targets as
// addresses and lui/addiu (ori, loads, stores) constants resolved.
//
// The text follows llvm-mc's MIPS I disassembly (-triple=mipsel
// -mcpu=mips1), which these tools used before: the same mnemonics, aliases
// and operand forms, and a word llvm-mc rejects (a must-be-zero field set,
// an instruction MIPS I lacks, a GTE command) is shown as .word.
//
// For the executable pass base = load address - 0x800 (its header):
// SLUS_013.24 loads at 0x80010000, so 8000f800.
package tools

import "core:fmt"
import "core:strings"

DIS_USAGE :: `Usage: bof4tools dis <file> <load address hex> <start hex> <end hex>
  bof4tools dis overlays/ov_801cc800_015.bin 801cc800 801d1298 801d1400
For the executable, pass base = load address - 0x800 (SLUS_013.24 loads at
0x80010000, so 8000f800).`

@(private = "file")
reg :: proc(r: u32) -> string {
	switch r {
	case 0:
		return "$zero"
	case 28:
		return "$gp"
	case 29:
		return "$sp"
	case 30:
		return "$fp"
	case 31:
		return "$ra"
	}
	return fmt.tprintf("$%d", r)
}

@(private = "file")
FPU_CONDS := [16]string{"f", "un", "eq", "ueq", "olt", "ult", "ole", "ule", "sf", "ngle", "seq", "ngl", "lt", "nge", "le", "ngt"}

// One instruction as llvm-mc writes it: branch operands are the byte offset
// from the branch (offset * 4 + 4). ok is false for a word it rejects.
dis_insn :: proc(w: u32) -> (text: string, ok: bool) {
	op := w >> 26
	rs, rt, rd, sa, fn := w >> 21 & 31, w >> 16 & 31, w >> 11 & 31, w >> 6 & 31, w & 63
	imm := w & 0xffff
	simm := i32(i16(imm))
	branch := simm * 4 + 4
	t :: fmt.tprintf
	switch op {
	case 0:
		switch fn {
		case 0, 2, 3:
			if rs != 0 {
				return
			}
			switch w {
			case 0:
				return "nop", true
			case 0x40:
				return "ssnop", true
			case 0xc0:
				return "ehb", true
			}
			names := [4]string{"sll", "", "srl", "sra"}
			return t("%s %s, %s, %d", names[fn], reg(rd), reg(rt), sa), true
		case 4, 6, 7:
			if sa != 0 {
				return
			}
			names := [4]string{"sllv", "", "srlv", "srav"}
			return t("%s %s, %s, %s", names[fn - 4], reg(rd), reg(rt), reg(rs)), true
		case 8:
			if w & 0x1fffc0 != 0 {
				return
			}
			return t("jr %s", reg(rs)), true
		case 9:
			if rt != 0 || sa != 0 {
				return
			}
			switch rd {
			case 0:
				return t("jr %s", reg(rs)), true
			case 31:
				return t("jalr %s", reg(rs)), true
			}
			return t("jalr %s, %s", reg(rd), reg(rs)), true
		case 0xc:
			code := w >> 6 & 0xfffff
			return code == 0 ? "syscall" : t("syscall %d", code), true
		case 0xd:
			hi, lo := w >> 16 & 0x3ff, w >> 6 & 0x3ff
			switch {
			case hi == 0 && lo == 0:
				return "break", true
			case lo == 0:
				return t("break %d", hi), true
			}
			return t("break %d, %d", hi, lo), true
		case 0x10, 0x12:
			if w & 0x3ff07c0 != 0 {
				return
			}
			return t("%s %s", fn == 0x10 ? "mfhi" : "mflo", reg(rd)), true
		case 0x11, 0x13:
			if w & 0x1fffc0 != 0 {
				return
			}
			return t("%s %s", fn == 0x11 ? "mthi" : "mtlo", reg(rs)), true
		case 0x18, 0x19:
			if w & 0xffc0 != 0 {
				return
			}
			return t("%s %s, %s", fn == 0x18 ? "mult" : "multu", reg(rs), reg(rt)), true
		case 0x1a, 0x1b:
			if w & 0xffc0 != 0 {
				return
			}
			return t("%s $zero, %s, %s", fn == 0x1a ? "div" : "divu", reg(rs), reg(rt)), true
		case 0x20 ..= 0x27, 0x2a, 0x2b:
			if sa != 0 {
				return
			}
			switch {
			case (fn == 0x21 || fn == 0x25) && rt == 0:
				return t("move %s, %s", reg(rd), reg(rs)), true
			case fn == 0x22 && rs == 0:
				return t("neg %s, %s", reg(rd), reg(rt)), true
			case fn == 0x23 && rs == 0:
				return t("negu %s, %s", reg(rd), reg(rt)), true
			case fn == 0x27 && rt == 0:
				return t("not %s, %s", reg(rd), reg(rs)), true
			}
			names := [12]string{"add", "addu", "sub", "subu", "and", "or", "xor", "nor", "", "", "slt", "sltu"}
			return t("%s %s, %s, %s", names[fn - 0x20], reg(rd), reg(rs), reg(rt)), true
		}
	case 1:
		switch rt {
		case 0, 1:
			if rt == 0 && false {
				return
			}
			return t("%s %s, %d", rt == 0 ? "bltz" : "bgez", reg(rs), branch), true
		case 0x10:
			if w == 0x0410ffff {
				return "nal", true
			}
			return t("bltzal %s, %d", reg(rs), branch), true
		case 0x11:
			if rs == 0 {
				return t("bal %d", branch), true
			}
			return t("bgezal %s, %d", reg(rs), branch), true
		}
	case 2, 3:
		return t("%s %d", op == 2 ? "j" : "jal", (w & 0x3ffffff) << 2), true
	case 4, 5:
		switch {
		case op == 4 && rs == 0 && rt == 0:
			return t("b %d", branch), true
		case rt == 0:
			return t("%s %s, %d", op == 4 ? "beqz" : "bnez", reg(rs), branch), true
		}
		return t("%s %s, %s, %d", op == 4 ? "beq" : "bne", reg(rs), reg(rt), branch), true
	case 6, 7:
		if rt != 0 {
			return
		}
		return t("%s %s, %d", op == 6 ? "blez" : "bgtz", reg(rs), branch), true
	case 8 ..= 0xb:
		names := [4]string{"addi", "addiu", "slti", "sltiu"}
		return t("%s %s, %s, %d", names[op - 8], reg(rt), reg(rs), simm), true
	case 0xc ..= 0xe:
		names := [3]string{"andi", "ori", "xori"}
		return t("%s %s, %s, %d", names[op - 0xc], reg(rt), reg(rs), imm), true
	case 0xf:
		if rs != 0 {
			return
		}
		return t("lui %s, %d", reg(rt), imm), true
	case 0x10, 0x12:
		z := op == 0x10 ? 0 : 2
		if (rs == 0 || rs == 4) && w & 0x7f8 == 0 {
			return t("%s%d %s, $%d, %d", rs == 0 ? "mfc" : "mtc", z, reg(rt), rd, w & 7), true
		}
	case 0x11:
		return fpu_insn(w)
	case 0x20 ..= 0x2e:
		names := [15]string{"lb", "lh", "lwl", "lw", "lbu", "lhu", "lwr", "", "sb", "sh", "swl", "sw", "", "", "swr"}
		if names[op - 0x20] != "" {
			return t("%s %s, %d(%s)", names[op - 0x20], reg(rt), simm, reg(rs)), true
		}
	case 0x31 ..= 0x33, 0x39 ..= 0x3b:
		z := op & 7
		name := op < 0x38 ? "lwc" : "swc"
		if z == 1 {
			return t("%s1 $f%d, %d(%s)", name, rt, simm, reg(rs)), true
		}
		return t("%s%d $%d, %d(%s)", name, z, rt, simm, reg(rs)), true
	}
	return
}

@(private = "file")
fpu_insn :: proc(w: u32) -> (text: string, ok: bool) {
	rs, rt, fs, fd, fn := w >> 21 & 31, w >> 16 & 31, w >> 11 & 31, w >> 6 & 31, w & 63
	t :: fmt.tprintf
	switch rs {
	case 0, 2, 4, 6:
		if w & 0x7ff != 0 {
			return
		}
		names := [4]string{"mfc1", "cfc1", "mtc1", "ctc1"}
		f := rs & 2 == 0 ? "$f" : "$"
		return t("%s %s, %s%d", names[rs / 2], reg(rt), f, fs), true
	case 8:
		if rt & 2 != 0 {
			return
		}
		name := rt & 1 == 0 ? "bc1f" : "bc1t"
		branch := i32(i16(w & 0xffff)) * 4 + 4
		if cc := rt >> 2; cc != 0 {
			return t("%s $fcc%d, %d", name, cc, branch), true
		}
		return t("%s %d", name, branch), true
	case 16, 17, 20:
		f := rs == 16 ? "s" : rs == 17 ? "d" : "w"
		// Doubles are register pairs: their registers are even.
		if rs == 17 {
			used := fn >= 0x20 && fn < 0x30 ? fs : fn >= 0x30 ? rt | fs : rt | fs | fd
			if used & 1 != 0 {
				return
			}
		}
		if fn == 0x21 && fd & 1 != 0 {
			return
		}
		switch {
		case fn < 4 && rs != 20:
			names := [4]string{"add", "sub", "mul", "div"}
			return t("%s.%s $f%d, $f%d, $f%d", names[fn], f, fd, fs, rt), true
		case fn >= 4 && fn <= 7 && fn != 4 && rt == 0 && rs != 20:
			names := [4]string{"", "abs", "mov", "neg"}
			return t("%s.%s $f%d, $f%d", names[fn - 4], f, fd, fs), true
		case fn >= 0x20 && fn <= 0x24 && fn != 0x22 && fn != 0x23 && rt == 0:
			names := [5]string{"s", "d", "", "", "w"}
			to := names[fn - 0x20]
			if to == f {
				return
			}
			return t("cvt.%s.%s $f%d, $f%d", to, f, fd, fs), true
		case fn >= 0x30 && rs != 20 && fd & 3 == 0:
			cc := fd >> 2
			if cc != 0 {
				return t("c.%s.%s $fcc%d, $f%d, $f%d", FPU_CONDS[fn & 15], f, cc, fs, rt), true
			}
			return t("c.%s.%s $f%d, $f%d", FPU_CONDS[fn & 15], f, fs, rt), true
		}
	}
	return
}

dis_main :: proc(args: []string) {
	usage(args, DIS_USAGE, 4)
	d := read_file(args[0])
	base, lo, hi := parse_hex(args[1]), parse_hex(args[2]), parse_hex(args[3])
	hi_reg: [32]Maybe(u32)
	for pc := lo; pc < hi; pc += 4 {
		at := int(pc - base)
		if pc < base || at + 4 > len(d) {
			fail("dis: %08x is outside the file", pc)
		}
		w := u32le(d, at)
		text, ok := dis_insn(w)
		if !ok {
			text = fmt.tprintf(".word 0x%08x", w)
		}
		op, rs, rt := w >> 26, w >> 21 & 31, w >> 16 & 31
		imm := w & 0xffff
		note := ""
		switch op {
		case 2, 3:
			text = with_target(text, w & 0x3ffffff << 2 | pc & 0xf0000000, false)
		case 1, 4, 5, 6, 7:
			text = with_target(text, pc + 4 + u32(i32(i16(imm)) * 4), true)
		case 15:
			hi_reg[rt] = imm << 16
		case 9, 13, 32, 33, 35, 36, 37, 40, 41, 43:
			if h, known := hi_reg[rs].?; known {
				v := op == 13 ? h | imm : h + u32(i32(i16(imm)))
				note = fmt.tprintf("  ; %08x", v)
			}
		}
		print("%08x  %s%s", pc, text, note)
		free_all(context.temp_allocator)
	}
}

// The text with its trailing number (with a minus sign when `signed`)
// replaced by the address: also in a .word line ending in digits, as the
// Python tool did.
@(private = "file")
with_target :: proc(text: string, target: u32, signed: bool) -> string {
	n := len(text)
	for n > 0 && text[n - 1] >= '0' && text[n - 1] <= '9' {
		n -= 1
	}
	if n == len(text) {
		return text
	}
	if signed && n > 0 && text[n - 1] == '-' {
		n -= 1
	}
	return strings.concatenate({text[:n], fmt.tprintf("%08x", target)}, context.temp_allocator)
}
