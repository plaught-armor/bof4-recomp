#!/usr/bin/env python3
"""Print the field state held in a 2 MiB main RAM dump.

Shows the map and section, the collision tables, the current section's
exits, the party objects and the NPC pool. Layouts are in docs/field.md.

RAM dumps come from the port: BOF4_DUMP=<dir> BOF4_DUMP_RAM=<presents>
writes <dir>/ram_*.bin, BOF4_RAMDUMP=<file> one at exit.

Usage: python3 -I field_state.py <ram.bin> [--grid] [--layer=N]
  --grid also prints the leader's layer of the collision grid, one hex
  attribute byte per cell ('..' for 0); --layer=N prints layer N instead.
"""
import struct
import sys

MAP_ID = 0x8011C944
SECTION = 0x8011C946
MAP_BLOCK = 0x8011C954
EXITS = 0x80116BE8
OBJECTS = 0x80116FB0
OBJECT_SIZE = 0xFC
LEADER_INDEX = 0x801172AF
NPCS = 0x801172B0
NPC_SIZE = 200
NPC_COUNT = 32
CAM_YAW = 0x8013818E


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 1:
        sys.exit(__doc__)
    ram = open(args[0], "rb").read()

    def u8(a):
        return ram[a & 0x1FFFFF]

    def u16(a):
        return struct.unpack_from("<H", ram, a & 0x1FFFFF)[0]

    def s16(a):
        return struct.unpack_from("<h", ram, a & 0x1FFFFF)[0]

    def u32(a):
        return struct.unpack_from("<I", ram, a & 0x1FFFFF)[0]

    def s32(a):
        return struct.unpack_from("<i", ram, a & 0x1FFFFF)[0]

    def in_ram(p):
        return 0x80000000 <= p < 0x80200000

    section = u8(SECTION)
    leader = OBJECTS + u8(LEADER_INDEX) * OBJECT_SIZE
    print("map %04x section %d camera yaw %d" % (u16(MAP_ID), section, u16(CAM_YAW)))

    blk = u32(MAP_BLOCK)
    if in_ram(blk):
        print("map block %08x: grids %d, attribute arrays %d, layers %d" % (blk, u8(blk), u8(blk + 2), u8(blk + 3)))

    base = u32(EXITS)
    if in_ram(base) and in_ram(u32(base)):
        p = u32(u32(base) + 4 * section)
        print("exits of section %d:" % section)
        while in_ram(p) and s16(p) != -1:
            print(
                "  to %04x.%d  cells (%d,%d) x%d along %s  arrive (%.1f,%.1f) facing %d"
                % (u16(p), u8(p + 2), u8(p + 4), u8(p + 5), u8(p + 10), "z" if u8(p + 3) & 1 else "x",
                   s16(p + 6) / 256, s16(p + 8) / 256, u8(p + 11) & 7)
            )
            p += 12

    def show(tag, b):
        pos = b + 12
        print(
            "  %s id %3d state %3d/%d  cell %7.2f %7.2f  height %6.2f  layer %d"
            % (tag, u8(b + 1), u8(b + 4), u8(b + 5), s32(pos) / 65536, s32(pos + 8) / 65536,
               s32(pos + 4) / 65536, u8(pos + 12))
        )

    print("party objects:")
    for i in range(4):
        b = OBJECTS + i * OBJECT_SIZE
        if u8(b):
            show("P%d%s" % (i, "*" if b == leader else " "), b)
    print("NPCs:")
    for i in range(NPC_COUNT):
        b = NPCS + i * NPC_SIZE
        if u8(b):
            show("N%-2d" % i, b)

    if "--grid" in sys.argv and in_ram(blk):
        layer = section + u8(leader + 24)
        for arg in sys.argv:
            if arg.startswith("--layer="):
                layer = section + int(arg[8:])
        desc = blk + u32(blk + 0xC4 + 4 * layer)
        grid = blk + u32(blk + 4 + 4 * u8(desc))
        attrs = blk + u32(blk + 0xA4 + 4 * u8(desc + 1))
        w, h = u16(grid) * 2, u16(grid + 2) * 2
        print("grid of layer %d: %dx%d cells" % (layer, w, h))
        for z in range(h):
            print("".join("%02x" % u8(attrs + z * w + x) if u8(attrs + z * w + x) else ".." for x in range(w)))


if __name__ == "__main__":
    main()
