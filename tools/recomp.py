#!/usr/bin/env python3
"""Static recompiler: MIPS R3000A machine code -> Odin source.

Each recompiled function becomes an Odin procedure that operates on the
emulated CPU state (`psx.cpu`) and memory bus (`psx.lw`, `psx.sw`, ...). Control
flow inside a function is a `for { switch pc { ... } }` state machine whose
cases are basic-block labels; straight-line code falls through. Calls go
through `psx.call(addr)` so the runtime can pick overlay variants, apply
hand-written overrides and fall back to its interpreter.

Usage:
  recomp.py exe   <SLUS_013.24> <overlays_dir> <funcs.tsv> <out_dir>
  recomp.py ovl   <SLUS_013.24> <overlays_dir> <funcs.tsv> <out_dir>

Both modes read the executable and every overlay: functions reached only
through pointers are found from references anywhere in the program.
"""

import bisect
import hashlib
import os
import struct
import sys
from collections import defaultdict

# Average R3000A cost per instruction including memory stalls. Timing
# loops in the PsyQ libraries (VSync timeout, CD waits) assume roughly this.
CYCLES_PER_INSN = 2

# Executable code range (PS-X EXE text; everything outside is data or overlay space).
EXE_CODE_LO = 0x80139598
EXE_CODE_HI = 0x80172BDC
# Main RAM in KSEG0, for pointer scans.
RAM_LO = 0x80000000
RAM_HI = 0x80200000


def sx16(v):
    return v - 0x10000 if v & 0x8000 else v


def hexu(v):
    return "0x%08x" % (v & 0xFFFFFFFF)


class Image:
    def __init__(self, base, data):
        self.base = base
        self.data = data
        self.end = base + len(data)

    def word(self, addr):
        o = addr - self.base
        if o < 0 or o + 4 > len(self.data):
            return None
        return struct.unpack_from("<I", self.data, o)[0]


# ---------------------------------------------------------------- decoding

class Insn:
    __slots__ = ("pc", "w", "op", "rs", "rt", "rd", "sa", "fn", "imm", "kind",
                 "target", "reads", "writes", "is_load")

    def __init__(self, pc, w):
        self.pc = pc
        self.w = w
        self.op = w >> 26
        self.rs = (w >> 21) & 31
        self.rt = (w >> 16) & 31
        self.rd = (w >> 11) & 31
        self.sa = (w >> 6) & 31
        self.fn = w & 63
        self.imm = w & 0xFFFF
        self.kind = "alu"     # alu | branch | jump | call | jr | jalr | bad | sys
        self.target = None
        self.reads = set()
        self.writes = set()
        self.is_load = False
        classify(self)


LOADS = {0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26}
STORES = {0x28, 0x29, 0x2A, 0x2B, 0x2E}


def classify(i):
    op, rs, rt, rd = i.op, i.rs, i.rt, i.rd
    if op == 0:
        f = i.fn
        if f in (0, 2, 3):
            i.reads = {rt}; i.writes = {rd}
        elif f in (4, 6, 7):
            i.reads = {rs, rt}; i.writes = {rd}
        elif f == 8:
            i.kind = "jr"; i.reads = {rs}
        elif f == 9:
            i.kind = "jalr"; i.reads = {rs}; i.writes = {rd}
        elif f in (12, 13):
            i.kind = "sys"
        elif f in (16, 18):
            i.writes = {rd}; i.reads = {"hilo"}
        elif f in (17, 19):
            i.reads = {rs}; i.writes = {"hilo"}
        elif f in (24, 25, 26, 27):
            i.reads = {rs, rt}; i.writes = {"hilo"}
        elif f in (32, 33, 34, 35, 36, 37, 38, 39, 42, 43):
            i.reads = {rs, rt}; i.writes = {rd}
        else:
            i.kind = "bad"
    elif op == 1:
        if rt & 0x1E == 0x10 or rt in (0, 1):
            i.kind = "branch"; i.reads = {rs}
            i.target = (i.pc + 4 + (sx16(i.imm) << 2)) & 0xFFFFFFFF
            if rt & 0x1E == 0x10:
                i.writes = {31}
        else:
            i.kind = "bad"
    elif op in (2, 3):
        i.kind = "jump" if op == 2 else "call"
        i.target = ((i.pc + 4) & 0xF0000000) | ((i.w & 0x3FFFFFF) << 2)
        if op == 3:
            i.writes = {31}
    elif op in (4, 5, 6, 7):
        i.kind = "branch"
        i.reads = {rs, rt} if op in (4, 5) else {rs}
        i.target = (i.pc + 4 + (sx16(i.imm) << 2)) & 0xFFFFFFFF
    elif 8 <= op <= 14:
        i.reads = {rs}; i.writes = {rt}
    elif op == 15:
        i.writes = {rt}
    elif op == 16:
        if rs == 0:
            i.writes = {rt}; i.is_load = True
        elif rs == 4:
            i.reads = {rt}
        elif rs == 16 and i.fn == 16:
            pass
        else:
            i.kind = "bad"
    elif op == 18:
        if rs in (0, 2):
            i.writes = {rt}; i.is_load = True
        elif rs in (4, 6):
            i.reads = {rt}
        elif rs & 16:
            pass
        else:
            i.kind = "bad"
    elif op in LOADS:
        i.reads = {rs} | ({rt} if op in (0x22, 0x26) else set())
        i.writes = {rt}
        i.is_load = True
    elif op in STORES:
        i.reads = {rs, rt}
    elif op == 0x32:
        i.reads = {rs}
    elif op == 0x3A:
        i.reads = {rs}
    else:
        i.kind = "bad"
    i.reads.discard(0)
    i.writes.discard(0)


def has_delay(i):
    return i.kind in ("branch", "jump", "call", "jr", "jalr")


# ---------------------------------------------------------------- emission

def R(n):
    return "0" if n == 0 else "c.r[%d]" % n


def addr_expr(i):
    off = sx16(i.imm)
    base = R(i.rs)
    if off == 0:
        return base
    if i.rs == 0:
        return hexu(off)
    return "%s %s 0x%x" % (base, "+" if off > 0 else "-", abs(off))


def set_reg(rd, expr, side_effect=False):
    if rd == 0:
        return ["_ = %s" % expr] if side_effect else []
    return ["c.r[%d] = %s" % (rd, expr)]


def emit_op(i):
    """Odin statements for a non-control-transfer instruction."""
    op, rs, rt, rd, sa = i.op, i.rs, i.rt, i.rd, i.sa
    if op == 0:
        f = i.fn
        if f == 0:
            return set_reg(rd, "%s << %d" % (R(rt), sa)) if sa else set_reg(rd, R(rt))
        if f == 2:
            return set_reg(rd, "%s >> %d" % (R(rt), sa))
        if f == 3:
            return set_reg(rd, "u32(i32(%s) >> %d)" % (R(rt), sa))
        if f == 4:
            return set_reg(rd, "%s << (%s & 31)" % (R(rt), R(rs)))
        if f == 6:
            return set_reg(rd, "%s >> (%s & 31)" % (R(rt), R(rs)))
        if f == 7:
            return set_reg(rd, "u32(i32(%s) >> (%s & 31))" % (R(rt), R(rs)))
        if f == 16:
            return set_reg(rd, "c.hi")
        if f == 17:
            return ["c.hi = %s" % R(rs)]
        if f == 18:
            return set_reg(rd, "c.lo")
        if f == 19:
            return ["c.lo = %s" % R(rs)]
        if f == 24:
            return ["psx.mult(%s, %s)" % (R(rs), R(rt))]
        if f == 25:
            return ["psx.multu(%s, %s)" % (R(rs), R(rt))]
        if f == 26:
            return ["psx.div(%s, %s)" % (R(rs), R(rt))]
        if f == 27:
            return ["psx.divu(%s, %s)" % (R(rs), R(rt))]
        if f in (32, 33):
            if rt == 0:
                return set_reg(rd, R(rs))
            if rs == 0:
                return set_reg(rd, R(rt))
            return set_reg(rd, "%s + %s" % (R(rs), R(rt)))
        if f in (34, 35):
            return set_reg(rd, "%s - %s" % (R(rs), R(rt)))
        if f == 36:
            return set_reg(rd, "%s & %s" % (R(rs), R(rt)))
        if f == 37:
            if rt == 0:
                return set_reg(rd, R(rs))
            if rs == 0:
                return set_reg(rd, R(rt))
            return set_reg(rd, "%s | %s" % (R(rs), R(rt)))
        if f == 38:
            return set_reg(rd, "%s ~ %s" % (R(rs), R(rt)))
        if f == 39:
            if rs == 0 and rt == 0:
                return set_reg(rd, "0xffffffff")  # ~ of an untyped 0 fails to build
            return set_reg(rd, "~(%s | %s)" % (R(rs), R(rt)))
        if f == 42:
            return set_reg(rd, "i32(%s) < i32(%s) ? 1 : 0" % (R(rs), R(rt)))
        if f == 43:
            return set_reg(rd, "%s < %s ? 1 : 0" % (R(rs), R(rt)))
        if f == 12:
            return ["psx.syscall(%s)" % hexu(i.pc)]
        if f == 13:
            return ["psx.brk(%s, 0x%x)" % (hexu(i.pc), (i.w >> 6) & 0xFFFFF)]
    elif op in (8, 9):
        imm = sx16(i.imm)
        if rs == 0:
            return set_reg(rt, hexu(imm))
        if imm == 0:
            return set_reg(rt, R(rs))
        return set_reg(rt, "%s %s 0x%x" % (R(rs), "+" if imm > 0 else "-", abs(imm)))
    elif op == 10:
        return set_reg(rt, "i32(%s) < %d ? 1 : 0" % (R(rs), sx16(i.imm)))
    elif op == 11:
        return set_reg(rt, "%s < %s ? 1 : 0" % (R(rs), hexu(sx16(i.imm))))
    elif op == 12:
        return set_reg(rt, "%s & 0x%x" % (R(rs), i.imm))
    elif op == 13:
        if rs == 0:
            return set_reg(rt, "0x%x" % i.imm)
        return set_reg(rt, "%s | 0x%x" % (R(rs), i.imm))
    elif op == 14:
        return set_reg(rt, "%s ~ 0x%x" % (R(rs), i.imm))
    elif op == 15:
        return set_reg(rt, hexu(i.imm << 16))
    elif op == 16:
        if rs == 0:
            return set_reg(rt, "psx.mfc0(%d)" % rd, True)
        if rs == 4:
            return ["psx.mtc0(%d, %s)" % (rd, R(rt))]
        if rs == 16 and i.fn == 16:
            return ["psx.rfe()"]
    elif op == 18:
        if rs == 0:
            return set_reg(rt, "psx.gte_read(%d)" % rd, True)
        if rs == 2:
            return set_reg(rt, "psx.gte_read(%d)" % (rd + 32), True)
        if rs == 4:
            return ["psx.gte_write(%d, %s)" % (rd, R(rt))]
        if rs == 6:
            return ["psx.gte_write(%d, %s)" % (rd + 32, R(rt))]
        if rs & 16:
            return ["psx.gte_cmd(0x%x)" % (i.w & 0x1FFFFFF)]
    elif op in LOADS:
        a = addr_expr(i)
        fn = {0x20: "lb", 0x21: "lh", 0x23: "lw", 0x24: "lbu", 0x25: "lhu"}.get(op)
        if fn:
            return set_reg(rt, "psx.%s(%s)" % (fn, a), True)
        fn = "lwl" if op == 0x22 else "lwr"
        return set_reg(rt, "psx.%s(%s, %s)" % (fn, a, R(rt)), True)
    elif op in STORES:
        a = addr_expr(i)
        fn = {0x28: "sb", 0x29: "sh", 0x2A: "swl", 0x2B: "sw", 0x2E: "swr"}[op]
        return ["psx.%s(%s, %s)" % (fn, a, R(rt))]
    elif op == 0x32:
        return ["psx.gte_write(%d, psx.lw(%s))" % (rt, addr_expr(i))]
    elif op == 0x3A:
        return ["psx.sw(%s, psx.gte_read(%d))" % (addr_expr(i), rt)]
    return ["psx.bad_insn(%s, %s)" % (hexu(i.pc), hexu(i.w))]


def branch_cond(i):
    op, rs, rt = i.op, i.rs, i.rt
    if op == 4:
        if rs == rt:
            return "true"
        return "%s == %s" % (R(rs), R(rt))
    if op == 5:
        return "%s != %s" % (R(rs), R(rt))
    if op == 6:
        return "i32(%s) <= 0" % R(rs)
    if op == 7:
        return "i32(%s) > 0" % R(rs)
    # REGIMM
    if rt & 1:
        return "i32(%s) >= 0" % R(rs)
    return "i32(%s) < 0" % R(rs)


# ---------------------------------------------------------------- functions

class Func:
    def __init__(self, entry, end, start=None):
        self.entry = entry
        self.start = entry if start is None else start  # range start
        self.end = end            # exclusive range end
        self.insns = {}           # pc -> Insn (reachable)
        self.labels = {entry}
        self.delay = set()        # delay-slot pcs
        self.exits = set()        # branch/jump targets outside [start, end)
        self.warnings = []


def discover(img, f, extra_labels):
    """Walk reachable code of f inside [start, end). A computed `jr` (not
    `$ra`) with no code pointers into the function can land on any
    instruction, as in a Duff's device, so then every word in the range is
    walked and labelled."""
    inside = lambda a: f.start <= a < f.end
    work = [f.entry] + [a for a in extra_labels if inside(a)]
    f.labels |= {a for a in extra_labels if inside(a)}
    seen = set()
    walk(img, f, work, seen, inside)
    computed = any(i.kind == "jr" and i.rs != 31 for i in f.insns.values())
    if computed and not any(inside(a) for a in extra_labels):
        rest = [a for a in range(f.start, f.end, 4) if a not in seen]
        walk(img, f, rest, seen, inside)
        f.labels |= {a for a in f.insns if a not in f.delay}
    # A delay slot that is also a label needs its successor labelled too.
    for d in list(f.delay):
        if d in f.labels:
            f.labels.add(d + 4)


def walk(img, f, work, seen, inside):
    """Decode reachable instructions from the pcs in work."""
    while work:
        pc = work.pop()
        while inside(pc) and pc not in seen:
            w = img.word(pc)
            if w is None:
                break
            seen.add(pc)
            i = Insn(pc, w)
            f.insns[pc] = i
            if i.kind == "bad":
                break
            if has_delay(i):
                d = pc + 4
                if inside(d) and d not in f.insns:
                    dw = img.word(d)
                    if dw is not None:
                        f.insns[d] = Insn(d, dw)
                        seen.add(d)
                f.delay.add(d)
                if i.kind == "branch":
                    if inside(i.target):
                        f.labels.add(i.target)
                        work.append(i.target)
                    else:
                        f.exits.add(i.target)
                    pc += 8
                    continue
                if i.kind == "jump":
                    if inside(i.target):
                        f.labels.add(i.target)
                        work.append(i.target)
                    else:
                        f.exits.add(i.target)
                    break
                if i.kind in ("call", "jalr"):
                    pc += 8
                    continue
                break  # jr
            if i.kind == "sys" and i.fn == 13 and (i.w >> 6) & 0xFFFFF == 1:
                # break 1 after main: never returns
                break
            pc += 4
        if pc == f.end:
            f.exits.add(pc)  # falls through into the next function


# Patch points: before the instruction at the address, when the Odin
# condition holds, go to the target (a label in the same function) instead.
# For changes inside a function that a whole-function hook cannot reach.
PATCHES = {
    # Map tiles, models: a tile (or part) is skipped unless one of its
    # projected corners lies on the screen, which drops near faces that span
    # it with every corner off it. psx.tiles_unculled skips the test.
    0x80143B84: ("psx.tiles_unculled", 0x80143C64),  # LAYER_SETUP floor
    0x80144B5C: ("psx.tiles_unculled", 0x80144C3C),  # MAP_DRAW
    0x801464C8: ("psx.tiles_unculled", 0x801465A8),  # MODEL_DRAW
    0x80147D84: ("psx.tiles_unculled", 0x80147E64),  # f_8014756c model faces
    0x80148B34: ("psx.tiles_unculled", 0x80148C14),  # f_8014829c model faces
    0x801491EC: ("psx.tiles_unculled", 0x801492CC),  # f_80148efc
}


def trace_stmt(pc):
    """Per-block hook for BOF4_TRACE=block; one bit test when tracing is off."""
    return "if .Block in psx.trace.active {psx.trace_block(%s)}" % hexu(pc)


def emit_func(img, f, out, name=None):
    name = name or "f_%08x" % f.entry
    out.append("%s :: proc() {" % name)
    out.append("\tc := &psx.cpu")
    out.append("\tif c.cycles >= psx.next_event {psx.run_events()}")
    out.append("\tpc: u32 = %s" % hexu(f.entry))
    out.append("\tfor {")
    out.append("\t\tswitch pc {")
    pcs = sorted(f.insns)
    open_case = False     # current case can fall into the next label
    pending = 0           # instructions not yet charged to c.cycles
    body = []

    def flush():
        nonlocal pending
        if pending:
            body.append("c.cycles += %d" % (pending * CYCLES_PER_INSN))
            pending = 0

    def goto(src, t):
        """Statements that transfer control to t from instruction src."""
        if f.start <= t < f.end and t in f.labels:
            s = ["pc = %s" % hexu(t)]
            if t <= src:
                s.append("if c.cycles >= psx.next_event {psx.run_events()}")
            s.append("continue")
            return s
        return ["psx.call(%s)" % hexu(t), "return"]

    def close_case():
        for s in body:
            out.append("\t\t\t" + s)
        body.clear()

    idx = 0
    skip_delay = set()
    while idx < len(pcs):
        pc = pcs[idx]
        idx += 1
        i = f.insns[pc]
        if pc in skip_delay:
            continue
        if pc in f.labels:
            if open_case:
                flush()
                body.append("fallthrough")
            close_case()
            out.append("\t\tcase %s:" % hexu(pc))
            body.append(trace_stmt(pc))
            open_case = True
        elif not open_case:
            # Unreachable by fallthrough and unlabelled: only a delay slot can get here.
            continue
        if pc in PATCHES:
            cond, target = PATCHES[pc]
            if target not in f.labels:
                f.warnings.append("patch target %s is not a label" % hexu(target))
            else:
                flush()
                body.append("if %s {" % cond)
                body.extend("\t" + s for s in goto(pc, target))
                body.append("}")
        pending += 1

        if i.kind in ("alu", "sys", "bad"):
            # Load delay: the next instruction still sees the old register value.
            nxt = f.insns.get(pc + 4)
            if (i.is_load and i.writes and nxt is not None and pc + 4 not in f.labels
                    and not has_delay(nxt) and (pc + 4) not in skip_delay):
                (rt,) = tuple(i.writes)
                lwlr_pair = i.op in (0x22, 0x26) and nxt.op in (0x22, 0x26) and nxt.rt == rt
                if (rt in nxt.reads or rt in nxt.writes) and not lwlr_pair:
                    # The slot instruction reads the old value. If it also
                    # writes rt, its write wins and the loaded value is lost
                    # (the load still happens: I/O reads have side effects).
                    stmts = emit_op(i)
                    body.append("{")
                    body.append("ld := " + stmts[0].split(" = ", 1)[1])
                    body.extend(emit_op(nxt))
                    if rt in nxt.writes:
                        body.append("_ = ld")
                    else:
                        body.append("c.r[%d] = ld" % rt)
                    body.append("}")
                    pending += 1
                    idx += 1
                    continue
            if i.kind == "bad":
                body.append("psx.bad_insn(%s, %s)" % (hexu(pc), hexu(i.w)))
                flush()
                body.append("return")
                open_case = False
                continue
            body.extend(emit_op(i))
            if i.kind == "sys" and i.fn == 13 and (i.w >> 6) & 0xFFFFF == 1:
                flush()
                body.append("return")
                open_case = False
            continue

        # control transfer with delay slot
        d = f.insns.get(pc + 4)
        dstmts = []
        if d is not None:
            if has_delay(d):
                f.warnings.append("branch in delay slot at %s" % hexu(pc + 4))
            else:
                dstmts = emit_op(d)
                pending += 1
        skip_delay.add(pc + 4)
        ret = pc + 8

        if i.kind == "branch":
            link = (i.op == 1 and i.rt & 0x1E == 0x10)
            cond = branch_cond(i)
            body.append("{")
            body.append("t := %s" % cond)
            if link:
                body.append("c.r[31] = %s" % hexu(ret))
            body.extend(dstmts)
            flush()
            if link:
                body.append("if t {psx.call(%s)}" % hexu(i.target))
                body.append("}")
            else:
                body.append("if t {")
                body.extend("\t" + s for s in goto(pc, i.target))
                body.append("}")
                body.append("}")
            if cond == "true" and not link:
                open_case = False
        elif i.kind == "jump":
            body.extend(dstmts)
            flush()
            body.extend(goto(pc, i.target))
            open_case = False
        elif i.kind == "call":
            body.append("c.r[31] = %s" % hexu(ret))
            body.extend(dstmts)
            flush()
            body.append("psx.call(%s)" % hexu(i.target))
        elif i.kind == "jalr":
            body.append("{")
            body.append("t: u32 = %s" % R(i.rs))
            if i.rd:
                body.append("c.r[%d] = %s" % (i.rd, hexu(ret)))
            body.extend(dstmts)
            flush()
            body.append("psx.call(t)")
            body.append("}")
        elif i.kind == "jr":
            if i.rs == 31:
                body.extend(dstmts)
                flush()
                body.append("return")
            else:
                body.append("{")
                body.append("t: u32 = %s" % R(i.rs))
                body.extend(dstmts)
                flush()
                body.append("pc = t")
                body.append("if c.cycles >= psx.next_event {psx.run_events()}")
                body.append("continue")
                body.append("}")
            open_case = False

        if pc + 4 in f.labels and pc + 4 in f.insns:
            # The delay slot is itself a jump target: give it its own case.
            if open_case:
                flush()
                body.append("pc = %s" % hexu(pc + 8))
                body.append("continue")
            close_case()
            out.append("\t\tcase %s:" % hexu(pc + 4))
            body.append(trace_stmt(pc + 4))
            body.extend(dstmts)
            pending += 1
            open_case = True

    if open_case:
        flush()
        body.append("psx.call(%s)" % hexu(f.end))
        body.append("return")
    close_case()
    out.append("\t\tcase:")
    out.append("\t\t\tpsx.jump_unknown(%s, pc)" % hexu(f.start))
    out.append("\t\t\treturn")
    out.append("\t\t}")
    out.append("\t}")
    out.append("}")
    out.append("")
    return name


# ---------------------------------------------------------------- inputs

def load_funcs(path):
    by_space = defaultdict(list)
    for line in open(path):
        p = line.rstrip("\n").split("\t")
        if len(p) < 5 or p[0] == "space":
            continue
        by_space[p[0]].append(int(p[1], 16))
    return by_space


def code_pointers(img, lo, hi):
    """Aligned words anywhere in img that point into [lo, hi)."""
    out = set()
    d = img.data
    for o in range(0, len(d) - 3, 4):
        v = struct.unpack_from("<I", d, o)[0]
        if lo <= v < hi and v & 3 == 0:
            out.add(v)
    return out


def call_targets(img, lo, hi):
    out = set()
    for a in range(lo, hi, 4):
        w = img.word(a)
        if w is not None and w >> 26 == 3:
            out.add(((a + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2))
    return out


def terminator_before(img, e, kinds):
    """True when the code before e (skipping up to four nop padding words)
    ends with an instruction accepted by kinds and its delay slot."""
    p = e - 4
    for _ in range(4):
        if img.word(p) != 0:
            break
        p -= 4
    for q in (p, p - 4):
        if q > e - 8:
            continue  # e would be this instruction's delay slot
        w = img.word(q)
        if w is None:
            return True
        if kinds(Insn(q, w)):
            return True
    return False


def unconditional(i):
    return i.kind in ("jr", "jump") or i.w >> 16 == 0x1000


def plausible_entries(img, entries, calls):
    """Drop listed entries that ordinary code falls through into; Ghidra
    places some mid-function. `jal` targets are always kept."""
    return {e for e in entries if e in calls or terminator_before(img, e, unconditional)}


def address_constants(img, lo, hi):
    """Addresses in [lo, hi) built in code by `lui` + `addiu`/`ori` pairs,
    such as callbacks passed as arguments."""
    out = set()
    upper = {}
    for a in range(img.base, img.base + len(img.data) - 3, 4):
        w = img.word(a)
        op, rs, rt = w >> 26, (w >> 21) & 31, (w >> 16) & 31
        if op == 0x0F:
            upper[rt] = (w & 0xFFFF) << 16
        elif op in (0x09, 0x0D) and rs in upper:
            low = w & 0xFFFF if op == 0x0D else ((w & 0xFFFF) ^ 0x8000) - 0x8000
            v = (upper[rs] + low) & 0xFFFFFFFF
            if lo <= v < hi and v & 3 == 0:
                out.add(v)
    return out


# Words a function may run before its `addiu $sp, $sp, -n` prologue: game
# code often loads a global first (`lui` + load) and tests it after.
MAX_PRE_PROLOGUE = 3
LOAD_OPS = frozenset((0x20, 0x21, 0x23, 0x24, 0x25))  # lb, lh, lw, lbu, lhu


def is_prologue(w):
    return w is not None and w >> 16 == 0x27BD and w & 0x8000


def global_loads(img, a, end):
    """True when [a, end) is `lui`s and loads based on registers those
    `lui`s set, starting with a `lui`: a load of a global. Data such as
    pointers into overlay space decodes as loads, but not based this way."""
    upper = set()
    for q in range(a, end, 4):
        w = img.word(q)
        if w is None:
            return False
        op, rs, rt = w >> 26, (w >> 21) & 31, (w >> 16) & 31
        if op == 0x0F:
            upper.add(rt)
        elif op not in LOAD_OPS or rs not in upper:
            return False
    return bool(upper)


def function_start(img, p, lo):
    """Start of the function whose prologue is at p: p, or the global loads
    of up to MAX_PRE_PROLOGUE words just before it."""
    for k in range(MAX_PRE_PROLOGUE, 0, -1):
        a = p - 4 * k
        if a >= lo and global_loads(img, a, p):
            return a
    return p


def pointer_entries(img, ptrs, lo):
    """Referenced code addresses that begin a function: a prologue, or the
    start of the global loads before one (function_start). Jump table targets
    do not, and splitting at one would turn a loop through it into recursion.
    Functions after a `jr $ra` are covered by return_boundaries."""
    out = set()
    for p in ptrs:
        for k in range(MAX_PRE_PROLOGUE + 1):
            if is_prologue(img.word(p + 4 * k)):
                if k == 0 or function_start(img, p + 4 * k, lo) == p:
                    out.add(p)
                break
    return out


def pointer_leaves(img, ptrs, entries, hi):
    """Functions for referenced code addresses without a prologue, which
    pointer_entries leaves to the preceding function: after an unconditional
    jump, code that returns through `jr $ra`, never leaves itself and never
    touches the stack or makes a call: a leaf function. A jump-table case can
    look the same, but such leaves are also called through function-pointer
    tables (`jalr`), so each gets a function of just its own code,
    overlapping its container, where it stays a label. Cases that end in
    their function's epilogue restore $sp, so they are left out."""
    out = []
    for p in ptrs:
        if not terminator_before(img, p, unconditional):
            continue
        n = bisect.bisect_right(entries, p)
        f = Func(p, entries[n] if n < len(entries) else hi)
        discover(img, f, set())
        insns = f.insns.values()
        if (not f.exits and any(i.kind == "jr" and i.rs == 31 for i in insns) and
                not any(i.kind in ("call", "jalr") or 29 in i.reads | i.writes for i in insns)):
            out.append(f)
    return out


def return_boundaries(img, lo, hi):
    """First non-nop word after each `jr $ra` and its delay slot: where the
    next function usually starts."""
    out = set()
    for q in range(lo, hi - 8, 4):
        if img.word(q) != 0x03E00008:
            continue
        a = q + 8
        while a < hi and img.word(a) == 0:
            a += 4
        if a < hi:
            out.add(a)
    return out


def split_module(img, lo, hi, entries, extra_labels):
    funcs = []
    for n, e in enumerate(entries):
        f = Func(e, entries[n + 1] if n + 1 < len(entries) else hi)
        discover(img, f, extra_labels)
        funcs.append(f)
    return funcs


def build_module(img, lo, hi, entries, extra_labels, fixed=frozenset(), leaf_ptrs=frozenset()):
    """Split [lo, hi) at the entries. An entry the preceding function
    branches past is mid-function and is dropped, unless it is in fixed
    (`jal` targets); it stays a label and gets a secondary function. A branch that still leaves its function for a non-entry
    address (code shared between functions) becomes a tail call, so each such
    target also gets a secondary function entered there and covering its
    container's whole range, so loops back across the target stay inside it.
    Secondary functions overlap their container instead of splitting it.
    Addresses in leaf_ptrs that pointer_leaves accepts get one too."""
    entries = sorted({e for e in entries if lo <= e < hi})
    dropped = set()
    while True:
        funcs = split_module(img, lo, hi, entries, extra_labels | dropped)
        inner = set()
        for n, f in enumerate(funcs[:-1]):
            nxt = funcs[n + 1]
            if nxt.entry not in fixed and any(nxt.entry < t < nxt.end for t in f.exits):
                inner.add(nxt.entry)
        if not inner:
            break
        dropped |= inner
        entries = [e for e in entries if e not in inner]
    known = set(entries)
    work = list(dropped) + [t for f in funcs for t in f.exits]
    while work:
        t = work.pop()
        if t in known or not lo <= t < hi or t & 3:
            continue
        known.add(t)
        n = bisect.bisect_right(entries, t)
        g = Func(t, entries[n] if n < len(entries) else hi, entries[n - 1] if n else lo)
        discover(img, g, extra_labels | dropped)
        funcs.append(g)
        work.extend(g.exits)
    funcs += pointer_leaves(img, [p for p in leaf_ptrs if lo <= p < hi and p not in known], entries, hi)
    funcs.sort(key=lambda f: f.entry)
    return funcs


def write_module(path, pkg, funcs, img, table_name):
    out = ["// Generated by tools/recomp.py. Do not edit.", "package %s" % pkg, "",
           'import "../psx"', ""]
    names = []
    for f in funcs:
        names.append((f.entry, emit_func(img, f, out)))
        for w in f.warnings:
            print("warning %s: %s" % (hexu(f.entry), w), file=sys.stderr)
    out.append("%s := [?]psx.Func_Entry{" % table_name)
    for a, n in names:
        out.append("\t{%s, %s}," % (hexu(a), n))
    out.append("}")
    with open(path, "w") as fp:
        fp.write("\n".join(out) + "\n")


# Instructions per generated overlay package. Odin compiles packages as
# separate LLVM modules (-use-separate-modules), so smaller packages build in
# parallel.
OVL_PACKAGE_INSNS = 50000


def func_key(f):
    """Identity of a function's code: overlays often share identical copies."""
    h = hashlib.sha1()
    for p in sorted(f.insns):
        h.update(struct.pack("<II", p, f.insns[p].w))
    h.update(repr((f.start, f.end, sorted(f.labels))).encode())
    return (f.entry, h.hexdigest()[:8])


def signature(img, f):
    """First code words of f, checked at call time to confirm residency."""
    return [img.word(f.entry + 4 * k) or 0 for k in range(4)]


def load_exe(exe_path):
    raw = open(exe_path, "rb").read()
    text, size = struct.unpack_from("<II", raw, 0x18)
    return Image(text, raw[0x800:0x800 + size])


def overlay_images(ovl_dir):
    """[(name, img)] for every overlay in the manifest."""
    rows = [l.rstrip("\n").split("\t") for l in open(os.path.join(ovl_dir, "manifest.tsv"))][1:]
    out = []
    for r in rows:
        blob = open(os.path.join(ovl_dir, r[0]), "rb").read()
        out.append((r[0][:-4], Image(int(r[1], 16), blob)))
    return out


def program_refs(images):
    """Code addresses referenced anywhere: data words and lui/addiu pairs in
    the executable and all overlays, since overlays call each other and the
    executable through pointers."""
    out = set()
    for img in images:
        out |= code_pointers(img, RAM_LO, RAM_HI) | address_constants(img, RAM_LO, RAM_HI)
    return out


def module_entries(img, lo, hi, listed, refs, known=frozenset()):
    """Entries of the code in [lo, hi) and the jal targets among them.
    Entries in known are certain and skip the plausibility check."""
    calls = call_targets(img, lo, hi)
    inside = {a for a in refs if lo <= a < hi}
    listed = plausible_entries(img, set(listed), calls)
    return listed | set(known) | pointer_entries(img, inside, lo) | return_boundaries(img, lo, hi) | calls, calls


def load_overlays(overlays, spaces, refs):
    """Yield (slot, id, img, funcs) for every overlay."""
    for name, img in overlays:
        slot, hi = img.base, img.base + len(img.data)
        ov_id = img.word(slot)
        ptrs = code_pointers(img, slot, hi)
        # Code may follow a header of strings or tables; its first function
        # can be reached only through pointers built at run time.
        # Header data precedes it, so it skips the fall-through check.
        first = next((a for a in range(slot + 4, hi, 4) if is_prologue(img.word(a))), None)
        known = {function_start(img, first, slot + 4)} if first else set()
        entries, calls = module_entries(img, slot + 4, hi, spaces.get(name, []), refs, known)
        yield slot, ov_id, img, build_module(img, slot + 4, hi, entries, ptrs, calls | known, refs)


def write_overlays(exe_path, ovl_dir, funcs_path, out_dir):
    """Recompile every overlay; identical functions are emitted once."""
    spaces = load_funcs(funcs_path)
    overlays = overlay_images(ovl_dir)
    refs = program_refs([load_exe(exe_path)] + [img for _, img in overlays])
    packages = []      # [(name, out_lines, table_rows)]
    emitted = {}       # func_key -> (package name, proc name)
    cur, size = None, OVL_PACKAGE_INSNS
    total = 0
    for slot, ov_id, img, funcs in load_overlays(overlays, spaces, refs):
        if size >= OVL_PACKAGE_INSNS:
            name = "ovl_%02d" % len(packages)
            cur = (name, ["// Generated by tools/recomp.py. Do not edit.", "package %s" % name, "",
                          'import "../../psx"', ""], [])
            packages.append(cur)
            size = 0
        for f in funcs:
            key = func_key(f)
            if key not in emitted:
                proc = "f_%08x_%s" % key
                emit_func(img, f, cur[1], proc)
                for w in f.warnings:
                    print("warning %s: %s" % (hexu(f.entry), w), file=sys.stderr)
                emitted[key] = (cur[0], proc)
                size += len(f.insns)
                total += len(f.insns)
            pkg, proc = emitted[key]
            ref = proc if pkg == cur[0] else "%s.%s" % (pkg, proc)
            sig = ", ".join(hexu(w) for w in signature(img, f))
            cur[2].append("\t{%s, %s, %s, {%s}, %s}," % (hexu(f.entry), hexu(slot), hexu(ov_id), sig, ref))
    for name, out, rows in packages:
        d = os.path.join(out_dir, name)
        os.makedirs(d, exist_ok=True)
        deps = sorted({r.split(", ")[-1].split(".")[0] for r in rows if "." in r.split(", ")[-1]})
        imports = ['import "../%s"' % p for p in deps]
        out[4:4] = imports + ([""] if imports else [])
        out.append("FUNCS := [?]psx.Ovl_Entry{")
        out.extend(rows)
        out.append("}")
        with open(os.path.join(d, "funcs.odin"), "w") as fp:
            fp.write("\n".join(out) + "\n")
    reg = ["// Generated by tools/recomp.py. Do not edit.", "package rec", "", 'import "../psx"']
    reg += ['import "%s"' % n for n, _, _ in packages]
    reg += ["", "register_overlays :: proc() {"]
    reg += ["\tpsx.register_overlay_funcs(%s.FUNCS[:])" % n for n, _, _ in packages]
    reg += ["}"]
    with open(os.path.join(out_dir, "overlays.odin"), "w") as fp:
        fp.write("\n".join(reg) + "\n")
    print("overlays: %d packages, %d unique functions, %d instructions" % (len(packages), len(emitted), total))


def main():
    mode = sys.argv[1]
    if mode == "exe":
        exe_path, ovl_dir, funcs_path, out_dir = sys.argv[2:6]
        img = load_exe(exe_path)
        spaces = load_funcs(funcs_path)
        refs = program_refs([img] + [o for _, o in overlay_images(ovl_dir)])
        ptrs = code_pointers(img, EXE_CODE_LO, EXE_CODE_HI)
        entries, calls = module_entries(img, EXE_CODE_LO, EXE_CODE_HI, spaces["ram"], refs)
        funcs = build_module(img, EXE_CODE_LO, EXE_CODE_HI, entries, ptrs, calls, refs)
        os.makedirs(out_dir, exist_ok=True)
        write_module(os.path.join(out_dir, "exe.odin"), "rec", funcs, img, "EXE_FUNCS")
        n = sum(len(f.insns) for f in funcs)
        print("exe: %d functions, %d instructions" % (len(funcs), n))
    elif mode == "ovl":
        write_overlays(*sys.argv[2:6])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
