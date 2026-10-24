#!/usr/bin/env python3
"""Extract a field map's data block, take it apart for editing, put it back.

The block is the EMI entry a map file loads at 0x80069800 (layout in
docs/field.md, "Map geometry", "Floors" and "Edited maps"). The port loads an
edited block from BOF4_MAPS=<dir>/<map>.blk in place of the disc's.

Usage:
  python3 -I map_block.py extract <disc BIN dir> <map> <out.blk>
      <map> in hex (0201); writes the disc's block.
  python3 -I map_block.py unpack <in.blk> <dir>
      writes the block's parts: header.bin, layer<n>.json (tile grid, ground
      heights, polygons), group<n>.bin (model groups), attrs<n>.bin
      (attribute grids), floor<n>.json (floor descriptors and their placed
      models), extra.bin (the +0x124 table, when there is one), colours.bin.
  python3 -I map_block.py pack <dir> <out.blk>
      builds a block from those parts, laying them out again; parts may
      change size. A missing part file leaves its table entry empty; a part
      numbered past the header's count (attrs1.bin in a block with one
      grid) raises the count.
  python3 -I map_block.py cells <in.blk> <floors.json> <out.blk>
      writes the "cells" rows of each floor of a BOF4_FLOORDUMP file into the
      floor's attribute grid. Floors that share a grid must agree.

Ground: a ground tile (flags bit 0) has four corner heights in units of 16
(corners (x,z) (x+1,z) (x,z+1) (x+1,z+1)); GROUND and the drawn quad both
follow them. Limits: the block must stay at most 0x1a000 bytes (the party's
models load at 0x80083800). Cell kinds (high nibble): 0x0 floor, 0x1 wall,
0xa exit, 0xc stair; see docs/field.md "Collision grid".
"""
import json, os, struct, sys

MAP_DATA = 0x80069800
MAX_SIZE = 0x83800 - 0x69800
AREA = {0x1000: 'M', 0x0200: 'S', 0x0400: 'D', 0x0800: 'E'}
HEADER = 0x134
# Offset tables: name, count byte, table offset, slots, part file suffix.
TABLES = [('layer', 0, 0x04, 8, '.json'), ('group', 1, 0x24, 32, '.bin'),
          ('attrs', 2, 0xa4, 8, '.bin'), ('floor', 3, 0xc4, 8, '.json')]
# Single offsets after the tables: +0x124 (optional) and the colour table.
SINGLES = [('extra', 0x124), ('colours', 0x128)]


def emi_path(bin_dir, m):
    for bit, letter in AREA.items():
        if m & bit:
            return os.path.join(bin_dir, 'WORLD', 'AREA%s%03d.EMI' % (letter, m & 0xff))
    sys.exit('map %04x: no area bit' % m)


def extract(bin_dir, m, out):
    d = open(emi_path(bin_dir, m), 'rb').read()
    off = 0x800
    for i in range(struct.unpack_from('<I', d, 0)[0]):
        size, addr = struct.unpack_from('<II', d, 0x10 + 16 * i)
        if addr == MAP_DATA:
            open(out, 'wb').write(d[off:off + size])
            print('%s: %d bytes' % (out, size))
            return
        off += (size + 0x7ff) & ~0x7ff
    sys.exit('map %04x: no block entry' % m)


def u32(b, at):
    return struct.unpack_from('<I', b, at)[0]


# ---------------------------------------------------------------- parts

def parts(b):
    """The block's parts in block order: (name, header word offset, bytes)."""
    places = []
    for name, count_at, table, slots, suffix in TABLES:
        for i in range(min(b[count_at], slots)):
            at = u32(b, table + 4 * i)
            if at:
                places.append(('%s%d%s' % (name, i, suffix), table + 4 * i, at))
    for name, word in SINGLES:
        at = u32(b, word)
        if at:
            places.append((name + '.bin', word, at))
    ats = [p[2] for p in places]
    assert ats == sorted(ats) and ats[0] == HEADER, 'parts out of order'
    ends = ats[1:] + [len(b)]
    return [(n, w, b[at:end]) for (n, w, at), end in zip(places, ends)]


def layer_json(d):
    width, rows, row_at, tile_at, ref_at, poly_at = struct.unpack_from('<HHIIII', d, 0)
    assert row_at == 0x14 and tile_at == row_at + 4 * rows
    l = {'width': width,
         'rows': [list(struct.unpack_from('<BBH', d, row_at + 4 * i)) for i in range(rows)],
         'tiles': [], 'refs': [], 'polys': []}
    for at in range(tile_at, ref_at, 16):
        t = d[at:at + 16]
        tile = {'heights': list(struct.unpack_from('<4b', t, 4)),
                'colors': list(struct.unpack_from('<4H', t, 8))}
        if t[0] & 1:
            tile.update(flags=t[0], ref=t[1], page=t[2], cell=t[3])
        else:
            count2, first = struct.unpack_from('<HH', t, 0)
            tile.update(polys=[first, count2 >> 1], low=count2 & 1)
        l['tiles'].append(tile)
    for at in range(ref_at, poly_at, 4):
        l['refs'].append(list(struct.unpack_from('<HH', d, at)))
    for at in range(poly_at, len(d), 32):
        p = struct.unpack_from('<3bb3bB3bB3bB8B4H', d, at)
        l['polys'].append({'v': [list(p[0:3]), list(p[4:7]), list(p[8:11]), list(p[12:15])],
                           'texture': p[3], 'flags': p[7], 'spare': [p[11], p[15]],
                           'uv': [list(p[16:18]), list(p[18:20]), list(p[20:22]), list(p[22:24])],
                           'colors': list(p[24:28])})
    return l


def layer_bytes(l):
    rows = l['rows']
    tile_at = 0x14 + 4 * len(rows)
    ref_at = tile_at + 16 * len(l['tiles'])
    poly_at = ref_at + 4 * len(l['refs'])
    out = bytearray(struct.pack('<HHIIII', l['width'], len(rows), 0x14, tile_at, ref_at, poly_at))
    for r in rows:
        out += struct.pack('<BBH', *r)
    for t in l['tiles']:
        if 'polys' in t:
            first, count = t['polys']
            out += struct.pack('<HH', count << 1 | t.get('low', 0), first)
        else:
            out += bytes([t['flags'], t['ref'], t['page'], t['cell']])
        out += struct.pack('<4b4H', *t['heights'], *t['colors'])
    for r in l['refs']:
        out += struct.pack('<HH', *r)
    for p in l['polys']:
        v = p['v']
        out += struct.pack('<3bb3bB3bB3bB8B4H', *v[0], p['texture'], *v[1], p['flags'], *v[2], p['spare'][0],
                           *v[3], p['spare'][1], *[c for uv in p['uv'] for c in uv], *p['colors'])
    return bytes(out)


MODEL = '<BBBBHHHBB'
MODEL_KEYS = ['group', 'colours', 'flags', 'pad', 'x', 'y', 'z', 'pad2', 'octants']


def floor_json(d):
    f = {'layer': d[0], 'attrs': d[1], 'flags': d[3], 'models': []}
    for i in range(d[2]):
        f['models'].append(dict(zip(MODEL_KEYS, struct.unpack_from(MODEL, d, 4 + 12 * i))))
    if len(d) > 4 + 12 * d[2]:
        f['tail'] = d[4 + 12 * d[2]:].hex()
    return f


def floor_bytes(f):
    out = bytearray([f['layer'], f['attrs'], len(f['models']), f['flags']])
    for m in f['models']:
        out += struct.pack(MODEL, *[m[k] for k in MODEL_KEYS])
    return bytes(out) + bytes.fromhex(f.get('tail', ''))


def encode(name, data):
    if name.startswith('layer'):
        return json.dumps(layer_json(data), separators=(',', ':')).encode()
    if name.startswith('floor'):
        return json.dumps(floor_json(data), indent=1).encode()
    return data


def decode(name, text):
    if name.startswith('layer'):
        return layer_bytes(json.loads(text))
    if name.startswith('floor'):
        return floor_bytes(json.loads(text))
    return text


def unpack(src, out_dir):
    b = open(src, 'rb').read()
    os.makedirs(out_dir, exist_ok=True)
    open(os.path.join(out_dir, 'header.bin'), 'wb').write(b[:HEADER])
    ps = parts(b)
    for name, _, data in ps:
        open(os.path.join(out_dir, name), 'wb').write(encode(name, data))
    print('%s: %d parts' % (out_dir, len(ps)))


def build(header, part):
    """A block from its header and part(name) -> bytes or None."""
    h = bytearray(header)
    out = bytearray()
    at = HEADER
    for name, count_at, table, slots, suffix in TABLES:
        # A part past the header's count (an added floor or grid) raises it.
        for i in range(h[count_at], slots):
            if part('%s%d%s' % (name, i, suffix)) is not None:
                h[count_at] = i + 1
        for i in range(slots):
            data = part('%s%d%s' % (name, i, suffix)) if i < h[count_at] else None
            struct.pack_into('<I', h, table + 4 * i, at if data is not None else 0)
            if data is not None:
                out += data + bytes(-len(data) % 4)
                at = HEADER + len(out)
    for name, word in SINGLES:
        data = part(name + '.bin')
        struct.pack_into('<I', h, word, at if data is not None else 0)
        if data is not None:
            out += data + bytes(-len(data) % 4)
            at = HEADER + len(out)
    return bytes(h) + bytes(out)


def pack(src_dir, out):
    def part(name):
        path = os.path.join(src_dir, name)
        return decode(name, open(path, 'rb').read()) if os.path.exists(path) else None
    b = build(open(os.path.join(src_dir, 'header.bin'), 'rb').read(), part)
    if len(b) > MAX_SIZE:
        sys.exit('block is %d bytes, at most %d' % (len(b), MAX_SIZE))
    open(out, 'wb').write(b)
    print('%s: %d bytes' % (out, len(b)))


def cells(src, floors_json, out):
    b = bytearray(open(src, 'rb').read())
    floors = json.load(open(floors_json))['floors']
    written = {}
    for f in floors:
        i = f['floor']
        if i >= b[3]:
            sys.exit('floor %d: block has %d' % (i, b[3]))
        desc = u32(b, 0xc4 + 4 * i)
        layer, attrs = b[desc], b[desc + 1]
        grid = u32(b, 0x04 + 4 * layer)
        across, down = struct.unpack_from('<HH', b, grid)
        across, down = across * 2, down * 2
        rows = [bytes(int(c, 16) for c in r.split()) for r in f['cells']]
        if len(rows) != down or any(len(r) != across for r in rows):
            sys.exit('floor %d: cells must be %dx%d' % (i, across, down))
        data = b''.join(rows)
        if attrs in written and written[attrs] != data:
            sys.exit('floor %d: grid %d shared with another floor, cells differ' % (i, attrs))
        written[attrs] = data
        at = u32(b, 0xa4 + 4 * attrs)
        b[at:at + len(data)] = data
    if len(b) > MAX_SIZE:
        sys.exit('block is %d bytes, at most %d' % (len(b), MAX_SIZE))
    open(out, 'wb').write(b)
    print('%s: %d grids written' % (out, len(written)))


if __name__ == '__main__':
    cmd = sys.argv[1:2]
    if cmd == ['extract'] and len(sys.argv) == 5:
        extract(sys.argv[2], int(sys.argv[3], 16), sys.argv[4])
    elif cmd == ['unpack'] and len(sys.argv) == 4:
        unpack(sys.argv[2], sys.argv[3])
    elif cmd == ['pack'] and len(sys.argv) == 4:
        pack(sys.argv[2], sys.argv[3])
    elif cmd == ['cells'] and len(sys.argv) == 5:
        cells(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        sys.exit(__doc__)
