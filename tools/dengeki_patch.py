"""Build the Dengeki Store Restoration v1.0 files for the port.

Usage: python3 -I dengeki_patch.py <patch dir> <disc dir> <out dir>

<patch dir> is the "dengeki store v1.0" folder of the fan patch (Navarchos,
Ratty, FlamePurge), <disc dir> the extracted disc (holds BIN/WORLD), <out dir>
the port's dengeki/ folder. Writes AREAD068.EMI and AREAS052.EMI with the
English text. The patch's Windows programs are not run: this does what its
pipeline does, read from their code:

- resources/*.xdelta are VCDIFF (RFC 3284) deltas with xdelta3's LZMA
  secondary compression, decoded here.
- AREAD068: AREAD068.EMI.xdelta, then AREAD068_palette.xdelta on the result
  (adds a 64-byte colour table entry before the last entry).
- AREAS052: AREAS052.EMI.xdelta, then dengeki_transfer0.exe's step: a 14th
  entry (type 3, VRAM texture, 0x1800 bytes) cut from AREAM000.EMI, 0x20 and
  0x10 rows of 0x14 bytes at 0xa6028 and 0xa7028 (row stride 0x40), each
  written as 4 zero bytes, the row twice, 0x14 zero bytes.
- dengeki_transfer1.exe moves the disc's later files in the executable's file
  table (+1 sector after AREAD068, +3 after AREAS052) to make room; the port
  serves both files past the disc's end instead (qol/dengeki.odin).
"""
import lzma
import os
import struct
import sys
import zlib


def code_table():
    """RFC 3284 default instruction code table: (kind, size, mode) pairs,
    kind 1 ADD, 2 COPY, 3 RUN, 0 none."""
    t = [((3, 0, 0), (0, 0, 0))]
    t.append(((1, 0, 0), (0, 0, 0)))
    t += [((1, s, 0), (0, 0, 0)) for s in range(1, 18)]
    for m in range(9):
        t.append(((2, 0, m), (0, 0, 0)))
        t += [((2, s, m), (0, 0, 0)) for s in range(4, 19)]
    for m in range(6):
        t += [((1, a, 0), (2, c, m)) for a in range(1, 5) for c in range(4, 7)]
    for m in range(6, 9):
        t += [((1, a, 0), (2, 4, m)) for a in range(1, 5)]
    t += [((2, 4, m), (1, 1, 0)) for m in range(9)]
    assert len(t) == 256
    return t


CODES = code_table()


class Reader:
    def __init__(self, data):
        self.data, self.pos = data, 0

    def byte(self):
        self.pos += 1
        return self.data[self.pos - 1]

    def var(self):
        v = 0
        while True:
            c = self.byte()
            v = v << 7 | c & 0x7f
            if not c & 0x80:
                return v

    def take(self, n):
        self.pos += n
        return self.data[self.pos - n:self.pos]

    def done(self):
        return self.pos >= len(self.data)


def secondary(section):
    r = Reader(section)
    size = r.var()
    # xdelta3 flushes each section's xz stream but does not finish it.
    out = lzma.LZMADecompressor(lzma.FORMAT_XZ).decompress(section[r.pos:])
    if len(out) != size:
        sys.exit("dengeki_patch: bad secondary section")
    return out


def vcdiff(source, patch):
    r = Reader(patch)
    if r.take(4) != b"\xd6\xc3\xc4\x00":
        sys.exit("dengeki_patch: not a VCDIFF file")
    flags = r.byte()
    if flags & 1:
        r.byte()  # secondary compressor id (2, LZMA)
    if flags & 2:
        sys.exit("dengeki_patch: custom code tables are not supported")
    if flags & 4:
        r.take(r.var())  # xdelta3 application header (file names)
    out = bytearray()
    while not r.done():
        win = r.byte()
        seg = b""
        if win & 3:
            length, at = r.var(), r.var()
            seg = (source if win & 1 else out)[at:at + length]
        r.var()  # delta encoding length
        target_len = r.var()
        compressed = r.byte()
        lens = r.var(), r.var(), r.var()
        adler = r.take(4) if win & 4 else None  # xdelta3 extension
        data, inst, addr = (r.take(n) for n in lens)
        data = secondary(data) if compressed & 1 else data
        inst = secondary(inst) if compressed & 2 else inst
        addr = secondary(addr) if compressed & 4 else addr
        d, i, a = Reader(data), Reader(inst), Reader(addr)
        near, same, next_near = [0] * 4, [0] * 768, 0
        target = bytearray()
        while not i.done():
            for kind, size, mode in CODES[i.byte()]:
                if kind == 0:
                    continue
                if size == 0:
                    size = i.var()
                if kind == 1:
                    target += d.take(size)
                elif kind == 3:
                    target += bytes([d.byte()]) * size
                else:
                    here = len(seg) + len(target)
                    if mode == 0:
                        at = a.var()
                    elif mode == 1:
                        at = here - a.var()
                    elif mode < 6:
                        at = near[mode - 2] + a.var()
                    else:
                        at = same[(mode - 6) * 256 + a.byte()]
                    near[next_near] = at
                    next_near = (next_near + 1) % 4
                    same[at % 768] = at
                    for k in range(at, at + size):
                        target.append(seg[k] if k < len(seg) else target[k - len(seg)])
        if len(target) != target_len:
            sys.exit("dengeki_patch: bad window length")
        if adler is not None and zlib.adler32(target) != int.from_bytes(adler, "big"):
            sys.exit("dengeki_patch: checksum mismatch (not the US disc?)")
        out += target
    return bytes(out)


def add_texture(store, m000):
    """dengeki_transfer0.exe: append entry 14 to the store's EMI."""
    out = bytearray(store[:0xe0])
    out += struct.pack("<IIII", 0x1800, 0x1e080200, 0, 0x2e2e0003)
    out += store[0xf0:0x800]
    at = 0x800
    for i in range(13):
        size = (struct.unpack_from("<I", store, (i + 1) * 16)[0] + 0x7ff) & ~0x7ff
        out += store[at:at + size]
        at += size
    for start, rows, pad in ((0xa6028, 0x20, 0x800), (0xa7028, 0x10, 0x400)):
        for k in range(rows):
            row = m000[start + k * 0x40:start + k * 0x40 + 0x14]
            out += bytes(4) + row + row + bytes(0x14)
        out += bytes(pad)
    out[0] = 14
    return bytes(out)


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    res = os.path.join(sys.argv[1], "resources")
    world = os.path.join(sys.argv[2], "BIN", "WORLD")
    out = sys.argv[3]

    def read(*path):
        with open(os.path.join(*path), "rb") as f:
            return f.read()

    d068 = vcdiff(read(world, "AREAD068.EMI"), read(res, "AREAD068.EMI.xdelta"))
    d068 = vcdiff(d068, read(res, "AREAD068_palette.xdelta"))
    s052 = vcdiff(read(world, "AREAS052.EMI"), read(res, "AREAS052.EMI.xdelta"))
    s052 = add_texture(s052, read(world, "AREAM000.EMI"))
    os.makedirs(out, exist_ok=True)
    for name, data in (("AREAD068.EMI", d068), ("AREAS052.EMI", s052)):
        with open(os.path.join(out, name), "wb") as f:
            f.write(data)
        print(os.path.join(out, name), len(data))


if __name__ == "__main__":
    main()
