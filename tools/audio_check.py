#!/usr/bin/env python3
"""Check what the host played for dropouts, and the game's audio report.

The played stream is a recording of the output device, for example a
PipeWire null sink's monitor taken with pw-record during a paced run (see
tools/audio_test.sh). A dropout (the host queue ran dry, or the device
thread came late) is a run of silence inside sound: at least `--gap` ms
quieter than `--floor`, with sound on both sides.

With the run's log (BOF4_TRACE=perf), the .Perf audio lines are listed too:
"audio mixed" should be 44100.0 Hz (the host corrects at most 0.5% off it),
the queue's lowest level should stay above 0, and "ran dry" / "dropped"
should be 0 outside fast-forward.

Usage:
  python3 -P tools/audio_check.py played.wav [log]
(-P: tools/dis.py would shadow the standard library's dis module.)
"""

import argparse
import re
import wave

import numpy as np

PERF = re.compile(r"^(\d+) \d+ Perf (.*(?:audio|ran dry|late vblank|fast-forward).*)$")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("played")
    ap.add_argument("log", nargs="?")
    ap.add_argument("--gap", type=float, default=3.0, help="shortest dropout reported (ms)")
    ap.add_argument("--floor", type=float, default=2.0, help="largest sample counted as silent")
    args = ap.parse_args()

    with wave.open(args.played, "rb") as w:
        hz, n = w.getframerate(), w.getnchannels()
        assert w.getsampwidth() == 2, "need s16"
        a = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").reshape(-1, n)
    level = np.abs(a.astype(np.int32)).max(axis=1)
    loud = np.flatnonzero(level > args.floor)
    print(f"played {len(a) / hz:.1f} s at {hz} Hz")
    gaps = 0
    if len(loud):
        # Silent runs between two sounding samples.
        d = np.diff(loud)
        need = int(args.gap * hz / 1000)
        for k in np.flatnonzero(d > need):
            at, length = loud[k] + 1, d[k] - 1
            # Sound on both sides: not a quiet passage or the music's end.
            before = level[max(0, at - hz // 50):at]
            after = level[at + length:at + length + hz // 50]
            if before.mean() > 64 and after.mean() > 64:
                gaps += 1
                print(f"{at / hz:8.3f} s  dropout {length / hz * 1000:.1f} ms")
    print(f"{gaps} dropouts")

    if args.log:
        for line in open(args.log, errors="replace"):
            m = PERF.match(line.rstrip())
            if m:
                print(f"vblank {m[1]:>6}  {m[2]}")


if __name__ == "__main__":
    main()
