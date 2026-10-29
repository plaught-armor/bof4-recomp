# Regression baseline

`run.py` replays recorded sessions and autoplay routes headless (SDL offscreen,
audio to `/dev/null`, unpaced, connected controllers ignored) and compares
every present against a recorded reference. The port writes hashes rather than pictures (`BOF4_DUMP_HASH=1`,
see [debugging.md](../docs/debugging.md)), one line per dump. Each present
gets the window picture and the PS1 frame. Every 150th present also gets
VRAM, and every 300th gets main RAM.

```
python3 tests/run.py list
python3 tests/run.py record [-jN] [case|gl|sw ...]   # write references
python3 tests/run.py check  [-jN] [case|gl|sw ...]   # compare with them
python3 tests/run.py glsw   [-jN] [case ...]         # GL run against the software reference
```

With no names, every case runs in both renderers (`gl`, `sw`). `record` runs
each case twice. It keeps the first run as the reference and marks every
present where the two runs differ as unstable, so `check` skips those. Build
first (`port/build.sh`). Runs go six at a time, gl and sw mixed, each in its
own `local/out/` directory; `-jN` sets how many (1 to 6). Guest time alone
decides every frame, so host load does not change the hashes. A second
`run.py` refuses to start while one is running (lock file `local/run.lock`).

## Local inputs

Everything under `tests/local/` stays out of git, because it comes from the
disc or from saves:

| path | what |
|---|---|
| `local/c1/bof4_slot1.mcd`, `bof4_slot2.mcd` | cards for the route cases (File 04: Sarai, early story) |
| `local/c1/load.rec` | input record that loads File 04 from the title screen |
| `local/maps/1000.blk` | Sarai map block with the added rooftop Z level (`roof` case) |
| `local/replays/<stamp>/` | F12 debug sessions: `input.rec` and `start/` (cards, `bof4.ini`) |
| `local/ref/<case>.<mode>.tsv` | references written by `record` |
| `local/out/` | the last runs: `log.txt`, `trace.log`, `hashes.tsv` |

The routes (`routes/*.txt`, autoplay scripts) and the route configs
(`configs/*.ini`) are tracked. To add a replay case, copy a `port/debug/<stamp>`
session into `local/replays/` and add a `replay_case` line to `CASES` in
`run.py`.

## Reading a failure

`check` prints the presents whose hashes differ and the log checks that
changed (route finished, stair climbs, map check). To see the pictures, rerun
the case by hand with `BOF4_DUMP=<dir> BOF4_DUMP_WINDOW=1 BOF4_DUMP_FROM=<n>`
and without `BOF4_DUMP_HASH`. The environment `run.py` sets is in its `run()`
function.
