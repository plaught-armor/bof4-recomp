"""Put a raw Breath of Fire IV save into a PS1 memory card image (.mcd).

A raw save is the 0x1880-byte file the game writes: 0x180-byte card header,
then the game region; byte 0x184f is the XOR of every byte before it. The
Windows release stores saves in exactly this form (BOF4-NN.DAT), so its saves
load in the port, as do saves extracted from other card images.

The save is stored as BASLUS-01324BOF4<NN>US, NN = save number - 1, the name
the US game's load screen lists as that number. A missing card image is
created blank; an existing save of the same number is replaced.

Usage: python3 -I save_to_mcd.py <save.dat> <card.mcd> <save number 1-15>
"""
import os
import struct
import sys

CARD_SIZE = 128 * 1024
FRAME = 128
BLOCK = 0x2000
BLOCKS = 16
SAVE_SIZE = 0x1880
CHECKSUM = 0x184F
DIR_FREE = 0xA0
DIR_FIRST = 0x51
DIR_NONE = 0xFFFF
NAME = "BASLUS-01324BOF4%02dUS"


def xor(data):
    x = 0
    for b in data:
        x ^= b
    return x


def seal(card, n):
    """Write frame n's checksum byte."""
    f = n * FRAME
    card[f + FRAME - 1] = xor(card[f:f + FRAME - 1])


def blank_card():
    card = bytearray(CARD_SIZE)
    card[0:2] = b"MC"
    seal(card, 0)
    for n in range(1, BLOCKS):
        struct.pack_into("<IIH", card, n * FRAME, DIR_FREE, 0, DIR_NONE)
        seal(card, n)
    for n in range(16, 36):
        struct.pack_into("<IIH", card, n * FRAME, 0xFFFFFFFF, 0, DIR_NONE)
        seal(card, n)
    card[63 * FRAME:64 * FRAME] = card[0:FRAME]
    return card


def dir_name(card, n):
    return bytes(card[n * FRAME + 0x0A:n * FRAME + 0x1E]).split(b"\0")[0].decode("ascii", "replace")


def free_block(card, name):
    """Block to hold `name`: its current block, or the first free one."""
    for n in range(1, BLOCKS):
        state = struct.unpack_from("<I", card, n * FRAME)[0]
        if state == DIR_FIRST and dir_name(card, n) == name:
            if struct.unpack_from("<I", card, n * FRAME + 4)[0] != BLOCK:
                sys.exit("%s already exists with more than one block" % name)
            return n
    for n in range(1, BLOCKS):
        if struct.unpack_from("<I", card, n * FRAME)[0] & 0xF0 == DIR_FREE:
            return n
    sys.exit("card is full")


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    save = open(sys.argv[1], "rb").read()
    number = int(sys.argv[3])
    if not 1 <= number <= 15:
        sys.exit("save number must be 1-15")
    if len(save) != SAVE_SIZE:
        sys.exit("save is %d bytes, expected %d" % (len(save), SAVE_SIZE))
    if xor(save[:CHECKSUM]) != save[CHECKSUM]:
        sys.exit("save checksum does not match; file is damaged or not a BoF4 save")
    path = sys.argv[2]
    card = bytearray(open(path, "rb").read()) if os.path.exists(path) else blank_card()
    if len(card) != CARD_SIZE or card[0:2] != b"MC":
        sys.exit("%s is not a 128 KiB raw card image" % path)
    name = NAME % (number - 1)
    n = free_block(card, name)
    card[n * FRAME:(n + 1) * FRAME] = bytes(FRAME)
    struct.pack_into("<IIH", card, n * FRAME, DIR_FIRST, BLOCK, DIR_NONE)
    card[n * FRAME + 0x0A:n * FRAME + 0x0A + len(name)] = name.encode("ascii")
    seal(card, n)
    card[n * BLOCK:(n + 1) * BLOCK] = save + bytes(BLOCK - SAVE_SIZE)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(card)
    os.replace(tmp, path)
    print("%s: block %d holds %s" % (path, n, name))


main()
