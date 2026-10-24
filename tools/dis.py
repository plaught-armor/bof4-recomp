#!/usr/bin/env python3
"""Disassemble a range of a PS1 code file with jump/branch targets as
addresses and lui/addiu (ori, loads, stores) constants resolved.

Needs llvm-mc (LLVM) on the PATH.

Usage: python3 -I dis.py <file> <load address hex> <start hex> <end hex>
  python3 -I tools/dis.py overlays/ov_801cc800_015.bin 801cc800 801d1298 801d1400
For the executable, strip its 0x800-byte header first or pass
base = load address - 0x800 (SLUS_013.24 loads at 0x80010000, so 8000f800).
"""
import re, struct, subprocess, sys
path, base, lo, hi = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16), int(sys.argv[4], 16)
d = open(path, 'rb').read()
words = [struct.unpack_from('<I', d, a - base)[0] for a in range(lo, hi, 4)]
src = '\n'.join(' '.join('0x%02x' % b for b in struct.pack('<I', w)) for w in words)
r = subprocess.run(['llvm-mc', '--disassemble', '-triple=mipsel', '-mcpu=mips1'], input=src, capture_output=True, text=True)
good = [l.strip().replace('\t', ' ') for l in r.stdout.splitlines() if l.strip() and not l.strip().startswith('.text')]
bad = {int(m) - 1 for m in re.findall(r'<stdin>:(\d+):\d+: warning: invalid instruction', r.stderr)}
it = iter(good)
lines = ['.word 0x%08x' % words[i] if i in bad else next(it) for i in range(len(words))]
hi_reg = {}
for i, (w, l) in enumerate(zip(words, lines)):
    pc = lo + 4 * i
    op = w >> 26
    note = ''
    if op in (2, 3):
        t = ((w & 0x3ffffff) << 2) | (pc & 0xf0000000)
        l = re.sub(r'\d+$', '%08x' % t, l)
    elif op in (1, 4, 5, 6, 7):
        off = (w & 0xffff) - (0x10000 if w & 0x8000 else 0)
        t = pc + 4 + off * 4
        l = re.sub(r'-?\d+$', '%08x' % t, l)
    elif op == 15:
        hi_reg[(w >> 16) & 31] = (w & 0xffff) << 16
    elif op in (9, 13, 32, 33, 35, 36, 37, 40, 41, 43):
        rs = (w >> 21) & 31
        if rs in hi_reg:
            imm = w & 0xffff
            v = hi_reg[rs] | imm if op == 13 else (hi_reg[rs] + (imm - (0x10000 if imm & 0x8000 else 0))) & 0xffffffff
            note = '  ; %08x' % v
    print('%08x  %s%s' % (pc, l, note))
