#!/bin/sh
# Build the checkout's tools into tools/bof4tools (see main.odin).
set -e
cd "$(dirname "$0")"
odin build . -out:bof4tools -o:speed
