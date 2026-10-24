#!/bin/sh
# Prepare a checkout from your own copy of the disc, then build the port.
#
# Needs "Breath of Fire IV.cue" and its two .bin tracks (US release,
# SLUS-01324) in this folder. Builds the tools, extracts the disc's files to
# disc/, its code overlays to overlays/, recompiles the game's code into
# port/src/rec, and runs port/build.sh; arguments pass through to it. Steps
# whose output is already there are skipped, except the recompile, which
# takes seconds.
set -e
cd "$(dirname "$0")"
sh tools/build.sh
tools/bof4tools setup
sh port/build.sh "$@"
echo "built port/bof4: run it from port/ (cd port && ./bof4)"
