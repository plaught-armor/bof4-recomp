#!/bin/sh
# Build the port, optimized. A first argument `debug` adds debug info
# (-debug). Set BOF4_OPT=none for an unoptimized build; other flags pass
# through, e.g. ./build.sh -sanitize:address
# BOF4_ARCH picks the CPU target. The default, native, uses everything the
# build machine's CPU has (AVX2, AVX-512 where present), so the binary may
# not start on another machine. For a build to hand to others use
# BOF4_ARCH=x86-64-v3 (AVX2: Intel from 2013, AMD from 2015) or
# BOF4_ARCH=x86-64 (any 64-bit x86).
# PS_RECOMP names the ps-recomp checkout (the emulated PS1 in psx, and the
# shared core: trace, capture, PNG, environment); the default is the
# repository root's ps-recomp/.
set -e
cd "$(dirname "$0")"
debug=
if [ "${1:-}" = debug ]; then
	debug=-debug
	shift
fi
odin build src -out:bof4 -use-separate-modules $debug -o:"${BOF4_OPT:-speed}" -microarch:"${BOF4_ARCH:-native}" -collection:ps="${PS_RECOMP:-../ps-recomp}" -define:ENV_PREFIX=BOF4_ "$@"
