// Extract the files of a PlayStation disc image (raw 2352-byte sectors).
//
// Reads the ISO 9660 file system on the data track and writes every file
// under <out_dir>, keeping the disc's directory layout (SYSTEM.CNF,
// SLUS_013.24, BIN/...). Each sector contributes its 2048 bytes of user
// data, the size the directory records give, also for the XA/STR files whose
// sectors are Mode 2 Form 2 (the port streams those from the image itself,
// not from these copies).
package tools

DISC_EXTRACT_USAGE :: `Usage: bof4tools disc-extract "<Breath of Fire IV (Track 1).bin>" <out_dir>`

disc_extract_main :: proc(args: []string) {
	usage(args, DISC_EXTRACT_USAGE, 2)
	n := disc_extract(args[0], args[1])
	print("%d files written to %s", n, args[1])
}

disc_extract :: proc(bin, out_dir: string) -> int {
	img := image_open(bin)
	lba, size := iso_root(img)
	return disc_extract_dir(img, lba, size, out_dir)
}

disc_extract_dir :: proc(img: Image, lba, size: int, out_dir: string) -> int {
	make_dirs(out_dir)
	count := 0
	for r in iso_records(img, lba, size) {
		path := join(out_dir, r.name)
		if r.is_dir {
			count += disc_extract_dir(img, r.lba, r.size, path)
		} else {
			data := image_extent(img, r.lba, r.size)
			write_file(path, data)
			delete(data)
			count += 1
		}
	}
	return count
}
