#!/usr/bin/env python3
"""Convert a BoF4 input.rec from before ps:core (no V line, I masks in the
game's byte-swapped layout) to a version 1 ps:core record, in place."""
import sys

for path in sys.argv[1:]:
    lines = open(path).read().splitlines()
    if lines and lines[0].startswith("V "):
        print(path, "already converted")
        continue
    out = ["V 1"]
    for line in lines:
        f = line.split()
        if f and f[0] == "I":
            m = int(f[2], 16)
            f[2] = "%x" % (((m & 0xff) << 8) | (m >> 8))
            line = " ".join(f)
        out.append(line)
    open(path, "w").write("\n".join(out) + "\n")
    print(path, "converted")
