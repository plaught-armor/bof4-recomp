#!/usr/bin/env python3
"""Print the field map connection graph from the map overlays.

Each map's overlay (slot 0x801f0800) holds its exit table: a pointer to
per-section list pointers, each list 12-byte entries ended by s16 -1 (layout
in docs/field.md). The table is found by its shape, so a map whose table is
not found prints "none".

Usage: python3 -I exit_graph.py <overlays dir>
Output per map: the EMI files carrying the overlay, then one line per exit:
  s<section> -> <map>.<section> at (<x>,<z>) len <cells> flags <+3> to (<x>,<z>)
"""
import struct, sys, re
O = sys.argv[1]
BASE = 0x801f0800
man = {}
for l in open(O + '/manifest.tsv'):
    f = l.split('\t')
    if f[0].startswith('ov_801f0800_'):
        man[f[0]] = f[5].split()
def lists(d):
    end = BASE + len(d)
    inb = lambda p: BASE <= p < end - 3
    w = lambda p: struct.unpack_from('<I', d, p - BASE)[0]
    def exitlist(p):
        out = []
        for _ in range(80):
            if p + 12 > end: return None
            e = d[p - BASE:p - BASE + 12]
            dest = struct.unpack_from('<h', e)[0]
            if dest == -1: return out
            if not (dest == -2 or 0 <= dest < 3 or (dest & 0xfe00) in (0x200, 0x400, 0x800, 0x1000) and (dest & 0x1ff) < 200 or dest & 0xfe00 == 0):
                return None
            if e[2] > 16: return None
            out.append(e); p += 12
        return None
    best = None
    for o in range(BASE, end - 3, 4):
        t = w(o)
        if not inb(t) or t & 3: continue
        secs = []
        q = t
        while inb(q) and len(secs) < 32:
            p = w(q)
            if p == 0: secs.append([]); q += 4; continue
            if not inb(p): break
            l = exitlist(p)
            if l is None: break
            secs.append(l); q += 4
        n = sum(len(s) for s in secs)
        if n and (best is None or n > best[0]):
            best = (n, o, t, secs)
    return best
for f, names in sorted(man.items(), key=lambda x: x[1][0]):
    d = open(O + '/' + f, 'rb').read()
    b = lists(d)
    if not b: print(names[0], 'none'); continue
    n, o, t, secs = b
    print(' '.join(x.split('/')[-1].split('.')[0] for x in names), 'base %x tab %x' % (o, t))
    for i, s in enumerate(secs):
        for e in s:
            print('  s%d -> %04x.%d at (%d,%d) len %d flags %02x to (%d,%d)' % (i, struct.unpack_from('<H', e)[0], e[2], e[4], e[5], e[10], e[3], struct.unpack_from('<h', e, 6)[0] // 256, struct.unpack_from('<h', e, 8)[0] // 256))
