#!/usr/bin/env python3
"""Prepare a checkout from your own copy of the disc, then build the port.

Needs "Breath of Fire IV.cue" and its two .bin tracks (US release,
SLUS-01324) in this folder. Extracts the disc's files to disc/, its code
overlays to overlays/, recompiles the game's code into port/src/rec, and
runs port/build.sh (port\\build.bat on Windows); arguments pass through to
it. Steps whose output is already there are skipped, except the recompile,
which takes seconds.
"""
import hashlib
import os
import subprocess
import sys

BIN = "Breath of Fire IV (Track 1).bin"
TRACKS = ["Breath of Fire IV.cue", BIN, "Breath of Fire IV (Track 2).bin"]
EXE = os.path.join("disc", "SLUS_013.24")
EXE_SHA1 = "4a658dca8775b569ae876ceecf5742b46eecff58"


def run(*args):
    subprocess.run([sys.executable, "-I", *args], check=True)


def recomp(mode):
    # The recompiler warns about each branch in a delay slot it handles; the
    # counts at the end are what matter.
    p = subprocess.run(
        [sys.executable, "-I", "tools/recomp.py", mode, EXE, "overlays",
         "tools/funcs.tsv", "port/src/rec"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in p.stdout.splitlines():
        if not line.startswith("warning"):
            print(line)
    if p.returncode != 0:
        sys.exit(p.returncode)


def main():
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    for f in TRACKS:
        if not os.path.isfile(f):
            sys.exit(f'missing "{f}": put your disc image (cue + both bin tracks) here')

    if not os.path.isfile(EXE):
        run("tools/disc_extract.py", BIN, "disc")
    with open(EXE, "rb") as f:
        if hashlib.sha1(f.read()).hexdigest() != EXE_SHA1:
            sys.exit(f"{EXE} is not the US release's executable (SLUS-01324)")
    if not os.path.isfile(os.path.join("overlays", "manifest.tsv")):
        run("tools/emi_extract.py", os.path.join("disc", "BIN"), "overlays")

    recomp("exe")
    recomp("ovl")

    if os.name == "nt":
        subprocess.run(["cmd", "/c", os.path.join("port", "build.bat"), *sys.argv[1:]], check=True)
        print(r"built port\bof4.exe: run it from port\ (cd port && bof4)")
    else:
        subprocess.run(["sh", "port/build.sh", *sys.argv[1:]], check=True)
        print("built port/bof4: run it from port/ (cd port && ./bof4)")


if __name__ == "__main__":
    main()
