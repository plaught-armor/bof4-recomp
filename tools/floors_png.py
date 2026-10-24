#!/usr/bin/env python3
"""Draw the floors of a BOF4_FLOORDUMP map file as PNG pictures.

The port writes <map>.json with BOF4_FLOORDUMP=<dir> (see docs/field.md,
Floors). For each floor this writes <out>/<map>_f<floor>.png, one pixel block
per attribute cell: grey by ground height (black lowest, white highest over
the whole map), tinted by the cell's kind (high nibble): red walls (0x1x),
blue exits (0xax), green stairs (0xcx), yellow anything else not plain floor.

Usage: python3 -I floors_png.py <map>.json <out dir> [pixels per cell, 4]
"""
import json, os, struct, sys, zlib

TINT = {0x1: (1.0, 0.35, 0.35), 0xa: (0.4, 0.5, 1.0), 0xc: (0.4, 1.0, 0.4)}


def png(path, w, h, rows):
    def chunk(kind, data):
        c = kind + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c))
    raw = b''.join(b'\0' + bytes(r) for r in rows)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(raw, 9)))
        f.write(chunk(b'IEND', b''))


def main():
    m = json.load(open(sys.argv[1]))
    out = sys.argv[2]
    k = int(sys.argv[3]) if len(sys.argv) > 3 else 4
    os.makedirs(out, exist_ok=True)
    heights = [g for f in m['floors'] for row in f['ground'] for g in row]
    lo, hi = min(heights), max(heights)
    span = max(hi - lo, 1)
    for f in m['floors']:
        rows = []
        for cells, ground in zip(f['cells'], f['ground']):
            line = []
            for cell, g in zip(cells.split(), ground):
                a = int(cell, 16)
                v = 0.25 + 0.75 * (g - lo) / span
                t = TINT.get(a >> 4, (1.0, 1.0, 1.0) if a >> 4 == 0 else (1.0, 1.0, 0.4))
                line += [min(255, int(255 * v * c)) for c in t] * k
            rows += [line] * k
        path = os.path.join(out, '%s_f%d.png' % (m['map'], f['floor']))
        png(path, f['width'] * k, f['depth'] * k, rows)
        print(path, 'ground %d..%d' % (min(min(r) for r in f['ground']), max(max(r) for r in f['ground'])))


main()
