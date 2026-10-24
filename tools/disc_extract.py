#!/usr/bin/env python3
"""Extract the files of a PlayStation disc image (raw 2352-byte sectors).

Reads the ISO 9660 file system on the data track and writes every file under
<out_dir>, keeping the disc's directory layout (SYSTEM.CNF, SLUS_013.24,
BIN/...). Each sector contributes its 2048 bytes of user data, the size the
directory records give, also for the XA/STR files whose sectors are Mode 2
Form 2 (the port streams those from the image itself, not from these copies).

Usage: python3 -I disc_extract.py "<Breath of Fire IV (Track 1).bin>" <out_dir>
"""
import os
import struct
import sys

RAW = 2352
USER = 2048
HEADER = 24  # sync (12), header (4), Mode 2 subheader (8)
PVD_SECTOR = 16


def sector(img, lba):
    img.seek(lba * RAW + HEADER)
    data = img.read(USER)
    if len(data) != USER:
        sys.exit("sector %d is past the end of the image" % lba)
    return data


def read_extent(img, lba, size):
    out = bytearray()
    while len(out) < size:
        out += sector(img, lba)
        lba += 1
    return bytes(out[:size])


def records(img, lba, size):
    """The directory records of one directory: (name, lba, size, is_dir)."""
    data = read_extent(img, lba, size)
    pos = 0
    while pos < len(data):
        length = data[pos]
        if length == 0:
            pos = (pos // USER + 1) * USER  # records never cross a sector
            continue
        rec = data[pos:pos + length]
        pos += length
        ext_lba, ext_size = struct.unpack_from("<I", rec, 2)[0], struct.unpack_from("<I", rec, 10)[0]
        flags, name_len = rec[25], rec[32]
        name = rec[33:33 + name_len]
        if name in (b"\x00", b"\x01"):
            continue  # . and ..
        name = name.decode("ascii").split(";")[0]
        yield name, ext_lba, ext_size, bool(flags & 2)


def walk(img, lba, size, out_dir, count):
    os.makedirs(out_dir, exist_ok=True)
    for name, ext_lba, ext_size, is_dir in records(img, lba, size):
        path = os.path.join(out_dir, name)
        if is_dir:
            count = walk(img, ext_lba, ext_size, path, count)
        else:
            with open(path, "wb") as fp:
                fp.write(read_extent(img, ext_lba, ext_size))
            count += 1
    return count


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    with open(sys.argv[1], "rb") as img:
        pvd = sector(img, PVD_SECTOR)
        if pvd[1:6] != b"CD001":
            sys.exit("%s: no ISO 9660 volume (is it a raw 2352-byte BIN?)" % sys.argv[1])
        root = pvd[156:156 + 34]
        lba, size = struct.unpack_from("<I", root, 2)[0], struct.unpack_from("<I", root, 10)[0]
        n = walk(img, lba, size, sys.argv[2], 0)
    print("%d files written to %s" % (n, sys.argv[2]))


if __name__ == "__main__":
    main()
