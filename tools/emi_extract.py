"""Extract unique MIPS code overlays from Breath of Fire IV EMI containers.

EMI layout (little-endian):
  0x00 u32 entry count
  0x04 u32 (always 1)
  0x08 "MATH_TBL"
  0x10 entries, 16 bytes each:
       u32 size
       u32 load address (>= 0x80000000) or data kind (< 0x80000000)
       u32 info: global overlay id for code entries
       u16 type, then ".." padding
  0x800 entry data, each entry padded to a 2 KiB boundary

Usage: python3 -I emi_extract.py <disc/BIN> <out_dir>
Writes <out_dir>/ov_<slot>_<id>.bin and <out_dir>/manifest.tsv, plus
<out_dir>/save_icons.bin (see extract_save_icons).
"""
import collections
import hashlib
import os
import struct
import sys

JR_RA = struct.pack('<I', 0x03e00008)
MIN_RETURNS = 4  # entries with fewer `jr ra` are treated as data...
MAX_ID = 0x10000  # ...unless they open with an overlay header, see is_code


def is_code(addr, info, blob):
    """Small overlays (map event code at 801f0800, battle scripts) may hold
    only one or two functions. They still open with their own id word,
    followed by either an entry table pointing into the overlay or the first
    instruction (a leaf function may start with any instruction, even its
    own `jr ra`). Data blobs sharing the id word (offset tables at 8003e000,
    69800) follow it with a small offset whose high half is zero."""
    returns = blob.count(JR_RA)
    if returns >= MIN_RETURNS:
        return True
    if returns == 0 or info >= MAX_ID or len(blob) < 8:
        return False
    head, second = struct.unpack_from('<II', blob, 0)
    return head == info and second >> 16 != 0


def entries(path):
    d = open(path, 'rb').read()
    count = struct.unpack_from('<I', d, 0)[0]
    off = 0x800
    for i in range(count):
        size, addr, info = struct.unpack_from('<III', d, 0x10 + i * 16)
        yield i, addr, info, d[off:off + size]
        off = (off + size + 0x7ff) & ~0x7ff


# Memory card icons of the 15 save numbers. The save screen uploads entry 3
# of SYSTEM/SAVE.EMI, a 4-bit texture with 64-byte rows, and the save builder
# copies save k's 16x16 icon from VRAM; in the file, icons 0..7 sit side by
# side from ICON_BASE and icons 8..14 the same way ICON_BAND bytes further on.
SAVE_EMI = os.path.join('SYSTEM', 'SAVE.EMI')
ICON_ENTRY = 3
ICON_BASE = 0x7400
ICON_BAND = 0x800
ICON_STRIDE = 64
ICON_ROW = 8
ICON_ROWS = 16
ICONS_PER_BAND = 8
SAVE_ICONS = 15


def extract_save_icons(root, out):
    """Write the icons as save headers hold them: 128 bytes each, in order."""
    tex = [blob for i, _, _, blob in entries(os.path.join(root, SAVE_EMI)) if i == ICON_ENTRY][0]
    icons = bytearray()
    for k in range(SAVE_ICONS):
        base = ICON_BASE + (k // ICONS_PER_BAND) * ICON_BAND + (k % ICONS_PER_BAND) * ICON_ROW
        for r in range(ICON_ROWS):
            icons += tex[base + r * ICON_STRIDE:base + r * ICON_STRIDE + ICON_ROW]
    open(os.path.join(out, 'save_icons.bin'), 'wb').write(icons)


def main(root, out):
    os.makedirs(out, exist_ok=True)
    seen = collections.OrderedDict()  # sha1 -> [slot, ids, sources, blob]
    for dp, _, fs in sorted(os.walk(root)):
        for fn in sorted(fs):
            if not fn.endswith('.EMI'):
                continue
            path = os.path.join(dp, fn)
            for i, addr, info, blob in entries(path):
                if addr < 0x80000000 or not is_code(addr, info, blob):
                    continue
                h = hashlib.sha1(blob).hexdigest()
                rec = seen.setdefault(h, [addr, set(), [], blob])
                assert rec[0] == addr, (path, i)
                rec[1].add(info)
                rec[2].append('%s#%d' % (os.path.relpath(path, root), i))
    with open(os.path.join(out, 'manifest.tsv'), 'w') as m:
        m.write('file\tslot\tsize\tids\tsha1\tsources\n')
        for h, (addr, ids, srcs, blob) in seen.items():
            name = 'ov_%08x_%03d.bin' % (addr, min(ids))
            open(os.path.join(out, name), 'wb').write(blob)
            m.write('%s\t%08x\t%d\t%s\t%s\t%s\n' % (
                name, addr, len(blob), ','.join(map(str, sorted(ids))), h, ' '.join(srcs)))
    extract_save_icons(root, out)
    print('%d unique overlays' % len(seen))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
