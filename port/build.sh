#!/bin/sh
# Build the port: optimized with debug info. Set BOF4_OPT=none for an
# unoptimized build; other flags pass through, e.g. ./build.sh -sanitize:address
# -debug would also turn on vendor:OpenGL's GL_DEBUG, which calls glGetError
# after every GL call (a driver round trip each); BOF4_GL_DEBUG=true keeps it.
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
odin build src -out:bof4 -use-separate-modules -debug -o:"${BOF4_OPT:-speed}" -microarch:"${BOF4_ARCH:-native}" -define:GL_DEBUG="${BOF4_GL_DEBUG:-false}" -collection:ps="${PS_RECOMP:-../ps-recomp}" -define:ENV_PREFIX=BOF4_ "$@"
