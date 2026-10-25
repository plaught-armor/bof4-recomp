// Prepare a checkout from your own copy of the disc: extract the disc's
// files to disc/, its code overlays to overlays/, and recompile the game's
// code into port/src/rec. Runs from the top of the checkout, as setup.sh and
// setup.bat do before they build the port. Steps whose output is already
// there are skipped, except the recompile, which takes seconds.
package tools

import "core:os"
import "ps:recomp/mips"
import "ps:recomp/r3000"

SETUP_USAGE :: `Usage: bof4tools setup
  Run from the top of the checkout, next to "Breath of Fire IV.cue" and its
  two .bin tracks (US release, SLUS-01324).`

SETUP_BIN :: "Breath of Fire IV (Track 1).bin"
SETUP_TRACKS :: [?]string{"Breath of Fire IV.cue", SETUP_BIN, "Breath of Fire IV (Track 2).bin"}
SETUP_EXE :: "disc/SLUS_013.24"
SETUP_EXE_SHA1 :: "4a658dca8775b569ae876ceecf5742b46eecff58"

setup_main :: proc(args: []string) {
	usage(args, SETUP_USAGE, 0)
	for f in SETUP_TRACKS {
		if !os.is_file(f) {
			fail(`missing "%s": put your disc image (cue + both bin tracks) here`, f)
		}
	}
	if !os.is_file(SETUP_EXE) {
		print("%d files written to disc", disc_extract(SETUP_BIN, "disc"))
		flush()
	}
	if sha1_hex(read_file(SETUP_EXE)) != SETUP_EXE_SHA1 {
		fail("%s is not the US release's executable (SLUS-01324)", SETUP_EXE)
	}
	if !os.is_file("overlays/manifest.tsv") {
		print("%d unique overlays", emi_extract("disc/BIN", "overlays"))
		flush()
	}
	// The recompiler warns about each branch in a delay slot it handles;
	// the counts it prints are what matter here.
	o := mips.load_options("tools/recomp.tsv")
	o.values["quiet"] = "true"
	r3000.generate(o)
}
