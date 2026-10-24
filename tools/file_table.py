"""Map BoF4 disc file indices (table at 0x80172c10 in SLUS_013.24) to ISO paths.

Usage: python3 -I file_table.py <track1.bin> <SLUS_013.24>
Prints: index  lba  path
"""
import struct
import sys

SECTOR = 2352
USER = 24  # Mode 2 Form 1 user data offset
EXE_BASE = 0x800f8800
TABLE = 0x80172c10


def read_sector(f, lba):
    f.seek(lba * SECTOR + USER)
    return f.read(2048)


def walk(f, lba, size, prefix, out):
    data = b''.join(read_sector(f, lba + i) for i in range((size + 2047) // 2048))
    off = 0
    while off < len(data):
        n = data[off]
        if n == 0:
            off = (off // 2048 + 1) * 2048
            continue
        rec = data[off:off + n]
        ext, length = struct.unpack_from('<I', rec, 2)[0], struct.unpack_from('<I', rec, 10)[0]
        flags, nlen = rec[25], rec[32]
        name = rec[33:33 + nlen]
        if name not in (b'\0', b'\1'):
            path = prefix + name.decode('ascii').split(';')[0]
            if flags & 2:
                walk(f, ext, length, path + '/', out)
            else:
                out[ext] = path
        off += n


def main(bin_path, exe_path):
    f = open(bin_path, 'rb')
    pvd = read_sector(f, 16)
    root = pvd[156:156 + 34]
    files = {}
    walk(f, struct.unpack_from('<I', root, 2)[0], struct.unpack_from('<I', root, 10)[0], '', files)
    exe = open(exe_path, 'rb').read()
    off = TABLE - EXE_BASE + 0x800
    f.seek(0, 2)
    sectors = f.tell() // SECTOR
    i = 0
    while True:
        lba = struct.unpack_from('<I', exe, off + i * 4)[0]
        if lba == 0 and i > 0 or lba >= sectors:
            break
        print('%03x\t%d\t%s' % (i, lba, files.get(lba, '?')))
        i += 1


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
