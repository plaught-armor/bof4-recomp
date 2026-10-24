// Map the disc file indices of BoF4 (the table at 0x80172c10 in
// SLUS_013.24) to ISO paths. Prints: index  lba  path
package tools

FILE_TABLE_USAGE :: "Usage: bof4tools file-table <track1.bin> <SLUS_013.24>"

FILE_TABLE_EXE_BASE :: 0x800f8800
FILE_TABLE :: 0x80172c10

file_table_main :: proc(args: []string) {
	usage(args, FILE_TABLE_USAGE, 2)
	img := image_open(args[0])
	root, size := iso_root(img)
	files: map[int]string
	file_table_walk(img, root, size, "", &files)
	exe := read_file(args[1])
	off := FILE_TABLE - FILE_TABLE_EXE_BASE + 0x800
	for i := 0;; i += 1 {
		lba := int(u32le(exe, off + i * 4))
		if lba == 0 && i > 0 || lba >= img.sectors {
			break
		}
		print("%03x\t%d\t%s", i, lba, files[lba] or_else "?")
	}
}

file_table_walk :: proc(img: Image, lba, size: int, prefix: string, files: ^map[int]string) {
	for r in iso_records(img, lba, size) {
		path := concat(prefix, r.name)
		if r.is_dir {
			file_table_walk(img, r.lba, r.size, concat(path, "/"), files)
		} else {
			files[r.lba] = path
		}
	}
}
