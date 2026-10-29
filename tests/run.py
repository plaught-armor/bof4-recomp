#!/usr/bin/env python3
"""Regression baseline for the port: replays and autoplay routes, headless.

Every case runs the port with BOF4_DUMP_HASH, so each present's window
picture, PS1 frame, and periodic RAM and VRAM become hash lines rather than
files. `record` runs each case twice, keeps the first run's hashes as the
reference in tests/local/ref/, and marks as unstable every present at which the two
runs differ (host timing, such as the preload child, decides some frames).
Presents the old reference marked stay marked, so a flake seen once is not
lost on a re-record; delete the reference to start the marks afresh.
`check` runs each case once and compares it with its reference.

    python3 tests/run.py list
    python3 tests/run.py record [-jN] [case|mode ...]
    python3 tests/run.py check  [-jN] [case|mode ...]
    python3 tests/run.py glsw   [-jN] [case ...]    # GL against software reference
    python3 tests/run.py near   [-jN] [case|mode ...]  # GPU run against software, live

A case name selects one case, a mode (gl, sw, vk) narrows to that renderer,
and no names means every case in gl and sw (vk has no references yet).

`near` runs each case in software and on a GPU backend (gl, vk; no mode
means both) at once, each streaming its dumps whole down a pipe
(BOF4_DUMP_FD), and compares them as they come. RAM and VRAM must match
exactly. The window and PS1 frame pictures may differ by a little: a pixel
whose largest channel difference is 1 or 2 is counted, and one off by more
is listed in out/<case>.near.<mode>.tsv. A run passes when no picture has
more pixels off by 1-2 than NEAR_SMALL allows and none is off by more.
Presents unstable in either reference are skipped. Each near run takes two
pool slots. Runs go to a pool of N instances at
once (default and most 6, gl and sw mixed; -j1 runs them one at a time). Every
run has its own out directory, and guest time alone decides each frame, so
the load the pool puts on the host does not change the hashes. Inputs that
come from the disc or from saves (cards, replays, edited map blocks) live in
tests/local/, which is not tracked; see tests/README.md.
"""

import fcntl
import os
import re
import shutil
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parent
PORT = ROOT / "port"
LOCAL = TESTS / "local"
REF = LOCAL / "ref"
OUT = LOCAL / "out"
JOBS = 6

MODES = {
    "gl": {"BOF4_GPU": "gl", "SDL_HINT_EGL_DEVICE": os.environ.get("SDL_HINT_EGL_DEVICE", "1")},
    "sw": {"BOF4_GPU": "sw"},
    "vk": {"BOF4_GPU": "vk"},
}
# The modes run when none is named, and a GPU mode's line in the log when it
# came up (none means it fell back to software).
DEFAULT_MODES = ["gl", "sw"]
GPU_UP = {"gl": "filled on the GPU", "vk": "GPU: vk"}
# Dumps compared near (pictures); every other kind must match exactly.
PICTURES = ("frame", "window")
# Lines of out/<case>.near.<mode>.tsv at most.
NEAR_LIST = 100000
# Pixels off by 1 or 2 one picture may have: the most gl had against sw on
# the cases (street, present 3476, 2026-10-29); the window is the frame
# scaled 2x. Every gl pixel off by more was a real difference (Δ up to 60+),
# so none is allowed.
NEAR_SMALL = {"frame": 55, "window": 220}

# Log checks: (label, pattern). The recorded value is the number of log lines
# matching the pattern, or with a group, the last match of that group.
STAIR = ("stair climbs", r"autoplay: climbed the stair at 2,8 to layer 1")
DONE = ("route done", r"autoplay: (done) at present")
PANIC = ("panics", r"panic|without being kept")


def route_case(route, config, env, checks, timeout=300):
    return {
        "cards": LOCAL / "c1",
        "replay": LOCAL / "c1" / "load.rec",
        "config": TESTS / "configs" / config,
        "route": TESTS / "routes" / route,
        "env": {"BOF4_CHEAT": "1", "BOF4_TRACE": "game", **env},
        "checks": [PANIC, *checks],
        "timeout": timeout,
    }


def replay_case(stamp, timeout=600):
    d = LOCAL / "replays" / stamp
    return {
        "cards": d / "start",
        "replay": d / "input.rec",
        "config": d / "start" / "bof4.ini",
        "route": TESTS / "routes" / "replay_end.txt",
        "env": {},
        "checks": [PANIC],
        "timeout": timeout,
    }


TOWN = {"BOF4_WARP": "1000.0:26,32"}
CASES = {
    # Walk round Sarai (1000): tiles, models, third-person camera.
    "town": route_case("town.txt", "d2.ini", TOWN, [DONE]),
    # Tavern 0201.2 stairs up to the gallery floor.
    "tavern": route_case("tavern.txt", "d2.ini", {"BOF4_WARP": "0201.2:4,8"}, [STAIR]),
    # Three town doors in and out with instant doors.
    "doors": route_case("doors.txt", "d2.ini", TOWN, [("map changes", r"autoplay: mode 2 map")]),
    # The added rooftop Z level on an edited 1000 block, native map drawing
    # checked against the game's own (BOF4_MAPCHECK). Third-person off: drawn
    # in 3D, the two differ by design and the check skips them.
    "roof": route_case("roof.txt", "d2flat.ini",
                       {**TOWN, "BOF4_MAPS": str(LOCAL / "maps"), "BOF4_MAPCHECK": "1", "BOF4_AUTO_TRACE": "1"},
                       [("map check", r"(\d+ drawings.*differ.*)")]),
    # The door route again with smooth motion off.
    "video": route_case("video.txt", "d2off.ini", TOWN, []),
    # Recorded play sessions (F12 debug sessions), replayed to their end.
    "bar": replay_case("20261025-090339"),
    "street": replay_case("20261025-095816"),
    "portrait": replay_case("20261025-103918"),
}


def run(name, mode, out, stream=None):
    """One headless run of a case; returns (hashes, checks, rc). With
    `stream`, the write end of a pipe, the dumps go down it whole instead of
    as hash lines (the hashes come back empty), and it is closed here."""
    case = CASES[name]
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    # The game writes its config and cards back: every run gets fresh copies.
    shutil.copy(case["config"], out / "bof4.ini")
    shutil.copy(case["cards"] / "bof4_slot1.mcd", out / "s1.mcd")
    shutil.copy(case["cards"] / "bof4_slot2.mcd", out / "s2.mcd")
    env = {
        **os.environ,
        "SDL_VIDEODRIVER": "offscreen",
        "SDL_AUDIODRIVER": "disk",
        "SDL_DISKAUDIOFILE": "/dev/null",
        # Live pads still reach a headless window and merge with replayed
        # input: a connected controller made runs differ. Ignore them all.
        "SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT": "0x0000/0x0000",
        "BOF4_FAST": "1",
        "BOF4_DEVICE": "keyboard",
        "BOF4_CONFIG": str(out / "bof4.ini"),
        "BOF4_MCD": str(out / "s1.mcd"),
        "BOF4_MCD2": str(out / "s2.mcd"),
        "BOF4_REPLAY": str(case["replay"]),
        "BOF4_DEBUG_DIR": str(out),
        "BOF4_TRACE_FILE": str(out / "trace.log"),
        "BOF4_AUTO": str(case["route"]),
        "BOF4_DUMP": str(out),
        "BOF4_DUMP_HASH": "1",
        "BOF4_DUMP_WINDOW": "1",
        "BOF4_DUMP_EVERY": "1",
        "BOF4_DUMP_RAM": "300",
        **case["env"],
        **MODES[mode],
    }
    if stream is not None:
        del env["BOF4_DUMP_HASH"]
        env["BOF4_DUMP_FD"] = str(stream)
    with open(out / "log.txt", "w") as log:
        try:
            p = subprocess.Popen([str(PORT / "bof4")], cwd=PORT, env=env, stdout=log,
                                 stderr=subprocess.STDOUT, pass_fds=() if stream is None else (stream,))
        finally:
            if stream is not None:
                os.close(stream)
        try:
            rc = p.wait(timeout=case["timeout"])
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait()
            rc = "timeout"
    text = (out / "log.txt").read_text(errors="replace")
    if mode in GPU_UP and GPU_UP[mode] not in text:
        rc = f"{rc}, {mode} fell back to software"
    return read_hashes(out / "hashes.tsv"), log_checks(case["checks"], text), rc


def missing(name):
    """The local inputs a case needs that are not there."""
    case = CASES[name]
    return [p for p in (case["cards"] / "bof4_slot1.mcd", case["replay"]) if not p.exists()]


def log_checks(checks, text):
    lines = text.splitlines()
    got = {}
    for label, pattern in checks:
        r = re.compile(pattern)
        hits = [m for m in map(r.search, lines) if m]
        got[label] = hits[-1].group(1) if r.groups and hits else str(len(hits))
    return got


def read_hashes(path):
    """{(kind, present): hash}, for the dumps a run wrote."""
    out = {}
    if path.exists():
        for line in path.read_text().splitlines():
            kind, present, h = line.split("\t")
            out[(kind, int(present))] = h
    return out


def ref_path(name, mode):
    return REF / f"{name}.{mode}.tsv"


def write_ref(name, mode, hashes, unstable, checks, rc):
    """Reference file: '#' header lines, then kind, present, hash and a '?'
    on presents that differed between the two recording runs."""
    lines = [f"# {name} ({mode}): exit {rc}"]
    lines += [f"#check\t{k}\t{v}" for k, v in checks.items()]
    for key in sorted(hashes, key=lambda k: (k[1], k[0])):
        mark = "\t?" if key in unstable else ""
        lines.append(f"{key[0]}\t{key[1]}\t{hashes[key]}{mark}")
    ref_path(name, mode).write_text("\n".join(lines) + "\n")


def read_ref(name, mode):
    path = ref_path(name, mode)
    if not path.exists():
        return None
    hashes, unstable, checks = {}, set(), {}
    for line in path.read_text().splitlines():
        f = line.split("\t")
        if f[0] == "#check":
            checks[f[1]] = f[2]
        elif not line.startswith("#"):
            key = (f[0], int(f[1]))
            hashes[key] = f[2]
            if len(f) > 3:
                unstable.add(key)
    return hashes, unstable, checks


def compare(a, b, skip=frozenset()):
    """Keys whose hashes differ, and keys only one side has."""
    differ = sorted((k for k in a.keys() & b.keys() if a[k] != b[k] and k not in skip), key=lambda k: (k[1], k[0]))
    only = sorted((k for k in a.keys() ^ b.keys() if k not in skip), key=lambda k: (k[1], k[0]))
    return differ, only


def spans(keys):
    """Presents as a short list of ranges: '12-15, 40'."""
    presents = sorted({k[1] for k in keys})
    out, i = [], 0
    while i < len(presents):
        j = i
        while j + 1 < len(presents) and presents[j + 1] == presents[j] + 1:
            j += 1
        out.append(str(presents[i]) if i == j else f"{presents[i]}-{presents[j]}")
        i = j + 1
    return ", ".join(out[:12]) + (" ..." if len(out) > 12 else "")


# Each action submits its runs to the pool and returns a function that waits
# for them and reports, so the reports print in order while the runs overlap.

def record(pool, name, mode):
    first = pool.submit(run, name, mode, OUT / f"{name}.{mode}.1")
    second = pool.submit(run, name, mode, OUT / f"{name}.{mode}.2")
    return lambda: record_report(name, mode, first.result(), second.result())


def record_report(name, mode, first, second):
    (a, checks, rc), (b, checks2, rc2) = first, second
    differ, only = compare(a, b)
    old = read_ref(name, mode)
    kept = old[1] & a.keys() if old else set()
    write_ref(name, mode, a, set(differ) | set(only) | kept, checks, rc)
    last = max((k[1] for k in a), default=0)
    note = "" if checks == checks2 else f"; checks differ between runs: {checks} / {checks2}"
    print(f"{name}.{mode}: exit {rc}/{rc2}, {len(a)} dumps to present {last}, "
          f"{len({k[1] for k in differ + only})} unstable presents ({spans(differ + only) or 'none'}), "
          f"{len({k[1] for k in kept})} kept from the old reference, "
          f"checks {checks}{note}")
    return True


def check(pool, name, mode):
    ref = read_ref(name, mode)
    if ref is None:
        return lambda: print(f"{name}.{mode}: no reference, run record first") or False
    got = pool.submit(run, name, mode, OUT / f"{name}.{mode}")
    return lambda: check_report(name, mode, ref, got.result())


def check_report(name, mode, ref, result):
    want, unstable, want_checks = ref
    got, checks, rc = result
    differ, only = compare(want, got, unstable)
    bad_checks = {k: (want_checks.get(k), v) for k, v in checks.items() if want_checks.get(k) != v}
    ok = not differ and not only and not bad_checks
    print(f"{name}.{mode}: {'ok' if ok else 'FAIL'} (exit {rc}, {len(got)} dumps, "
          f"{len(unstable)} unstable skipped)")
    if differ:
        print(f"  {len(differ)} dumps differ at presents {spans(differ)}")
    if only:
        print(f"  {len(only)} dumps on one side only, presents {spans(only)}")
    for k, (w, g) in bad_checks.items():
        print(f"  check {k}: want {w}, got {g}")
    return ok


def glsw(pool, name, _mode):
    """GL run against the software reference: the two renderers should draw
    the same pictures, so this reports where they do not."""
    ref = read_ref(name, "sw")
    if ref is None:
        return lambda: print(f"{name}: no sw reference, run record first") or False
    got = pool.submit(run, name, "gl", OUT / f"{name}.glsw")
    return lambda: glsw_report(name, ref, got.result())


def glsw_report(name, ref, result):
    want, unstable, _ = ref
    got, _, rc = result
    differ, only = compare(want, got, unstable)
    print(f"{name} gl vs sw: exit {rc}, {len(differ)} dumps differ ({spans(differ) or 'none'}), "
          f"{len(only)} on one side only")
    return not differ and not only


def near(pool, name, mode):
    """Software and `mode` runs of a case at once, their dumps compared as
    they stream; see the module notes."""
    refs = [r for r in (read_ref(name, "sw"), read_ref(name, mode)) if r]
    skip = set().union(*(r[1] for r in refs))
    got = pool.submit(near_run, name, mode, skip)
    return lambda: near_report(name, mode, got.result())


def near_run(name, mode, skip):
    results, readers, threads = {}, [], []
    for m in ("sw", mode):
        r, w = os.pipe()
        readers.append(open(r, "rb"))
        out = OUT / f"{name}.near.{m}"
        threads.append(threading.Thread(target=lambda m=m, w=w, out=out: results.__setitem__(m, run(name, m, out, w))))
        threads[-1].start()
    near = Near(OUT / f"{name}.near.{mode}.tsv", skip)
    try:
        near.compare(*readers)
    finally:
        # Drain both to the end, so neither run blocks writing to a pipe no
        # one reads, then wait for them.
        for f in readers:
            while f.read(1 << 20):
                pass
            f.close()
        for t in threads:
            t.join()
        near.close()
    return near, results["sw"][2], results[mode][2]


def dumps(f):
    """(kind, present, data) for each dump a run streams."""
    while head := f.readline():
        kind, present, size = head.decode().split("\t")
        data = f.read(int(size))
        if len(data) != int(size):
            return
        yield kind, int(present), data


def ppm(data):
    """A P6 picture as an h x w x 3 array."""
    magic, w, h, top, rest = data.split(maxsplit=4)
    assert magic == b"P6" and top == b"255"
    return np.frombuffer(rest, np.uint8).reshape(int(h), int(w), 3)


class Near:
    """Two dump streams compared as they come, in present order."""

    def __init__(self, path, skip):
        self.skip = skip
        self.list = open(path, "w")
        self.listed = 0
        self.only = []
        self.exact_off = []
        self.shape_off = []
        # kind: [compared, frames off, Δ1-2 pixels, Δ>2 pixels, (most Δ1-2 in one frame, present)]
        self.stats = {}

    def close(self):
        self.list.close()

    def compare(self, a, b):
        pending = ({}, {})
        last = [0, 0]
        streams = [dumps(a), dumps(b)]
        live = [True, True]
        while any(live):
            for side in (0, 1):
                if not live[side]:
                    continue
                d = next(streams[side], None)
                if d is None:
                    live[side] = False
                    last[side] = 1 << 62
                    continue
                kind, present, data = d
                last[side] = present
                key = (kind, present)
                other = pending[1 - side]
                if key in other:
                    pair = (data, other.pop(key)) if side == 0 else (other.pop(key), data)
                    if key not in self.skip:
                        self.pair(kind, present, *pair)
                else:
                    pending[side][key] = data
            # A dump the other stream is past has no partner.
            for side in (0, 1):
                for key in [k for k in pending[side] if k[1] < last[1 - side]]:
                    del pending[side][key]
                    if key not in self.skip:
                        self.only.append(key)
        for side in (0, 1):
            self.only += [k for k in pending[side] if k not in self.skip]

    def pair(self, kind, present, sw, gpu):
        s = self.stats.setdefault(kind, [0, 0, 0, 0, (0, 0)])
        s[0] += 1
        if sw == gpu:
            return
        s[1] += 1
        if kind not in PICTURES:
            self.exact_off.append((kind, present))
            return
        a, b = ppm(sw), ppm(gpu)
        if a.shape != b.shape:
            self.shape_off.append((kind, present))
            return
        d = np.abs(a.astype(np.int16) - b).max(axis=2)
        small = int(np.count_nonzero((d > 0) & (d <= 2)))
        ys, xs = np.nonzero(d > 2)
        s[2] += small
        s[3] += len(ys)
        s[4] = max(s[4], (small, present))
        for y, x in zip(ys.tolist(), xs.tolist()):
            if self.listed < NEAR_LIST:
                self.list.write(f"{kind}\t{present}\t{x}\t{y}\t{a[y, x].tolist()}\t{b[y, x].tolist()}\n")
            self.listed += 1


def near_report(name, mode, result):
    near, rc_sw, rc = result
    pictures = all(near.stats[k][3] == 0 and near.stats[k][4][0] <= NEAR_SMALL[k] for k in PICTURES if k in near.stats)
    ok = pictures and not near.only and not near.exact_off and not near.shape_off and rc_sw == 0 and rc == 0
    print(f"{name} {mode} near sw: {'ok' if ok else 'FAIL'} (exit {rc_sw}/{rc})")
    for kind, (n, off, small, big, (most, at)) in sorted(near.stats.items()):
        line = f"  {kind}: {n} compared, {off} off"
        if kind in PICTURES and off:
            line += f", {small} pixels off by 1-2 (most {most} at present {at}, {NEAR_SMALL[kind]} allowed), {big} off by more"
        print(line)
    if near.exact_off:
        print(f"  {len(near.exact_off)} RAM or VRAM dumps differ at presents {spans(near.exact_off)}")
    if near.shape_off:
        print(f"  {len(near.shape_off)} pictures differ in size at presents {spans(near.shape_off)}")
    if near.only:
        print(f"  {len(near.only)} dumps on one side only, presents {spans(near.only)}")
    if near.listed > NEAR_LIST:
        print(f"  {near.listed} pixels off by more than 2, the first {NEAR_LIST} listed")
    return ok


def main():
    args = sys.argv[1:]
    if not args or args[0] not in ("list", "record", "check", "glsw", "near"):
        sys.exit(__doc__)
    if args[0] == "list":
        for name, case in CASES.items():
            print(f"{name:10} {case['route'].name:16} {case['config'].name}")
        return
    jobs = JOBS
    for a in [a for a in args[1:] if re.fullmatch(r"-j\d+", a)]:
        jobs = int(a[2:])
        args.remove(a)
    if not 1 <= jobs <= JOBS:
        sys.exit(f"-j takes 1 to {JOBS}")
    names = [a for a in args[1:] if a in CASES] or list(CASES)
    modes = [a for a in args[1:] if a in MODES] or (["gl", "vk"] if args[0] == "near" else DEFAULT_MODES)
    unknown = [a for a in args[1:] if a not in CASES and a not in MODES]
    if unknown:
        sys.exit(f"unknown case or mode: {' '.join(unknown)}")
    gone = [f"{n}: missing {p}" for n in names for p in missing(n)]
    if gone:
        sys.exit("\n".join(gone) + "\n(see tests/README.md)")
    REF.mkdir(exist_ok=True)
    # Two invocations would write the same out directories and stack two
    # pools on the host: the second one refuses while the first holds this.
    lock = open(LOCAL / "run.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit(f"another run.py is running in {LOCAL}")
    action = {"record": record, "check": check, "glsw": glsw, "near": near}[args[0]]
    if args[0] == "glsw":
        modes = ["gl"]
    if args[0] == "near":
        if "sw" in modes:
            sys.exit("near compares gl or vk with sw")
        jobs = max(1, jobs // 2)
    with ThreadPoolExecutor(jobs) as pool:
        reports = [action(pool, n, m) for n in names for m in modes]
        ok = all([report() for report in reports])
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
