#!/usr/bin/env python3
"""Example: give map 1000 a new drawn layer (docs/field.md, Adding a drawn
layer).

Takes an unpacked block (map_block.py unpack) and writes a copy with layer 3:
a raised platform and ramp of new tiles with stone side walls, walked as
floor 3 (its own attribute grid 1), stairs from floor 0 at x 17.

    python3 -I tools/map_block.py unpack mods/1000.blk work/1000
    python3 -I tools/add_layer_1000.py work/1000 work/1000-l3
    python3 -I tools/map_block.py pack work/1000-l3 mods/1000.blk
"""
import json, shutil, os, sys
src, dst = sys.argv[1], sys.argv[2]
shutil.rmtree(dst, ignore_errors=True); shutil.copytree(src, dst)
H = 12  # platform height, steps of 16 drawing units
def tile(h): return {'heights': h, 'colors': [21139] * 4, 'flags': 7, 'ref': 255, 'page': 196, 'cell': 0}
row = [tile([0, 6, 0, 6]), tile([6, H, 6, H])] + [tile([H] * 4) for _ in range(3)]
tiles = row + [dict(t) for t in row]
# Side walls (stone, layer 2's texture slot 4): per side, its two corners
# along the edge (bottom a, bottom b, top a, top b, outward facing) and the
# tile heights at them.
SIDES = {'-z': ((0, 0), (16, 0), 0, 1), '+z': ((16, 16), (0, 16), 3, 2),
         '+x': ((16, 0), (16, 16), 1, 3), '-x': ((0, 16), (0, 0), 2, 0)}
def wall(side, h):
    a, b, ha, hb = SIDES[side]
    return {'v': [[a[0], 0, a[1]], [b[0], 0, b[1]], [a[0], h[ha], a[1]], [b[0], h[hb], b[1]]],
            'texture': 4, 'flags': 0, 'spare': [9, 0],
            'uv': [[31, 143], [0, 143], [31, 143 - 2 * h[ha]], [0, 143 - 2 * h[hb]]],
            'colors': [26423 if side[0] == '-' else 16913] * 4}
refs, polys = [], []
for i, t in enumerate(tiles):
    x, z = 9 + i % 5, 15 + i // 5
    sides = ['-z' if z == 15 else '+z'] + (['+x'] if x == 13 else [])
    t.update(ref=len(refs), page=0x04)
    refs.append([len(sides), len(polys)])
    polys += [wall(s, t['heights']) for s in sides]
layer = {'width': 14, 'rows': [[0, 0, 0]] * 15 + [[9, 5, 0], [9, 5, 5]],
         'tiles': tiles, 'refs': refs, 'polys': polys}
json.dump(layer, open(dst + '/layer3.json', 'w'))
json.dump({'layer': 3, 'attrs': 1, 'flags': 1, 'models': []}, open(dst + '/floor3.json', 'w'))
f0 = json.load(open(dst + '/floor0.json')); f0['flags'] = 0x7; json.dump(f0, open(dst + '/floor0.json', 'w'), indent=1)
W, D = 28, 34
a1 = bytearray([0x10] * (W * D))
for z in range(30, 34):
    for x in range(18, 28):
        a1[z * W + x] = 0
for z in (31, 32, 33):
    a1[z * W + 18] = 0xc7
open(dst + '/attrs1.bin', 'wb').write(a1)
a0 = bytearray(open(dst + '/attrs0.bin', 'rb').read())
for z in (31, 32, 33):
    assert a0[z * 50 + 17] == 0, hex(a0[z * 50 + 17])
    a0[z * 50 + 17] = 0xc1
open(dst + '/attrs0.bin', 'wb').write(a0)
