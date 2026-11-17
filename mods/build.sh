#!/bin/sh
# Build the mods in this directory: each subdirectory with a mod.tsv gets
# its mod.elf, compiled against the game's mod API in mods/api (written by
# setup). Names pick mods; none builds every one. A mod is C or Odin
# (ps-recomp's mods/build.sh): it needs clang, ld.lld and llvm-nm, and
# odin and llc for Odin. To use a mod, copy its directory (mod.tsv and
# mod.elf) into port/mods/.
#
#   sh mods/build.sh [mod ...]
set -eu
cd "$(dirname "$0")"
recomp=${PS_RECOMP:-../ps-recomp}
[ -f api/mod_api.h ] || {
	echo "mods/build.sh: no mods/api/mod_api.h: run setup first" >&2
	exit 1
}
if [ $# -eq 0 ]; then
	set -- $(for t in */mod.tsv; do dirname "$t"; done)
fi
for m in "$@"; do
	sh "$recomp/mods/build.sh" api "$m"
	echo "built mods/$m/mod.elf"
done
