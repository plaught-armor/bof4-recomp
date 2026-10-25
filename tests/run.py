#!/usr/bin/env python3
"""Regression baseline for the port: replays and autoplay routes, headless.

Every case runs the port with BOF4_DUMP_HASH, so each present's window
picture, PS1 frame, and periodic RAM and VRAM become hash lines rather than
files. `record` runs each case twice, keeps the first run's hashes as the
reference in tests/local/ref/, and marks as unstable every present at which the two
runs differ (host timing, such as the preload child, decides some frames).
`check` runs each case once and compares it with its reference.

    python3 tests/run.py list
    python3 tests/run.py record [case|mode ...]
    python3 tests/run.py check  [case|mode ...]
    python3 tests/run.py glsw   [case ...]    # GL against software reference

A case name selects one case, a mode (gl, sw) narrows to that renderer, and
no names means every case in both modes. Inputs that come from the disc or
from saves (cards, replays, edited map blocks) live in tests/local/, which is
not tracked; see tests/README.md. Run nothing else on the machine meanwhile:
instances never run in parallel, and load changes the unstable frames.
"""

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parent
PORT = ROOT / "port"
LOCAL = TESTS / "local"
REF = LOCAL / "ref"
OUT = LOCAL / "out"

MODES = {
    "gl": {"BOF4_GL": "1", "SDL_HINT_EGL_DEVICE": os.environ.get("SDL_HINT_EGL_DEVICE", "1")},
    "sw": {"BOF4_GL": "0"},
}

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
        "env": {"BOF4_CHEAT": "1", "BOF4_TRACE": "qol", **env},
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


def run(name, mode, out):
    """One headless run of a case; returns (hashes, checks, rc)."""
    case = CASES[name]
    for need in (case["cards"] / "bof4_slot1.mcd", case["replay"]):
        if not need.exists():
            sys.exit(f"{name}: missing {need} (see tests/README.md)")
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
    with open(out / "log.txt", "w") as log:
        try:
            rc = subprocess.run([str(PORT / "bof4")], cwd=PORT, env=env, stdout=log,
                                stderr=subprocess.STDOUT, timeout=case["timeout"]).returncode
        except subprocess.TimeoutExpired:
            rc = "timeout"
    text = (out / "log.txt").read_text(errors="replace")
    if mode == "gl" and "filled on the GPU" not in text:
        rc = f"{rc}, GL fell back to software"
    return read_hashes(out / "hashes.tsv"), log_checks(case["checks"], text), rc


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


def record(name, mode):
    a, checks, rc = run(name, mode, OUT / f"{name}.{mode}.1")
    b, checks2, rc2 = run(name, mode, OUT / f"{name}.{mode}.2")
    differ, only = compare(a, b)
    write_ref(name, mode, a, set(differ) | set(only), checks, rc)
    last = max((k[1] for k in a), default=0)
    note = "" if checks == checks2 else f"; checks differ between runs: {checks} / {checks2}"
    print(f"{name}.{mode}: exit {rc}/{rc2}, {len(a)} dumps to present {last}, "
          f"{len({k[1] for k in differ + only})} unstable presents ({spans(differ + only) or 'none'}), "
          f"checks {checks}{note}")
    return True


def check(name, mode):
    ref = read_ref(name, mode)
    if ref is None:
        print(f"{name}.{mode}: no reference, run record first")
        return False
    want, unstable, want_checks = ref
    got, checks, rc = run(name, mode, OUT / f"{name}.{mode}")
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


def glsw(name, _mode):
    """GL run against the software reference: the two renderers should draw
    the same pictures, so this reports where they do not."""
    ref = read_ref(name, "sw")
    if ref is None:
        print(f"{name}: no sw reference, run record first")
        return False
    want, unstable, _ = ref
    got, _, rc = run(name, "gl", OUT / f"{name}.glsw")
    differ, only = compare(want, got, unstable)
    print(f"{name} gl vs sw: exit {rc}, {len(differ)} dumps differ ({spans(differ) or 'none'}), "
          f"{len(only)} on one side only")
    return not differ and not only


def main():
    args = sys.argv[1:]
    if not args or args[0] not in ("list", "record", "check", "glsw"):
        sys.exit(__doc__)
    if args[0] == "list":
        for name, case in CASES.items():
            print(f"{name:10} {case['route'].name:16} {case['config'].name}")
        return
    names = [a for a in args[1:] if a in CASES] or list(CASES)
    modes = [a for a in args[1:] if a in MODES] or list(MODES)
    unknown = [a for a in args[1:] if a not in CASES and a not in MODES]
    if unknown:
        sys.exit(f"unknown case or mode: {' '.join(unknown)}")
    if subprocess.run(["pgrep", "-x", "bof4"], capture_output=True).returncode == 0:
        sys.exit("bof4 is already running; instances never run in parallel")
    REF.mkdir(exist_ok=True)
    action = {"record": record, "check": check, "glsw": glsw}[args[0]]
    if args[0] == "glsw":
        modes = ["gl"]
    ok = all([action(n, m) for n in names for m in modes])
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
