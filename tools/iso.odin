// The ISO 9660 file system on the data track of a raw (2352-byte sector)
// disc image, for disc-extract and file-table.
package tools

import "core:os"
import "core:strings"

RAW_SECTOR :: 2352
USER_SIZE :: 2048
// Sync (12), header (4), Mode 2 subheader (8).
USER_OFFSET :: 24
PVD_SECTOR :: 16

Image :: struct {
	path:    string,
	file:    ^os.File,
	sectors: int,
}

Iso_Record :: struct {
	name:   string,
	lba:    int,
	size:   int,
	is_dir: bool,
}

image_open :: proc(path: string) -> Image {
	f, err := os.open(path)
	if err != nil {
		fail("%s: %v", path, err)
	}
	size, _ := os.file_size(f)
	return {path, f, int(size) / RAW_SECTOR}
}

// The user data of sector `lba`.
image_sector :: proc(img: Image, lba: int, buf: []u8) {
	n, _ := os.read_at(img.file, buf[:USER_SIZE], i64(lba) * RAW_SECTOR + USER_OFFSET)
	if n != USER_SIZE {
		fail("sector %d is past the end of the image", lba)
	}
}

image_extent :: proc(img: Image, lba, size: int) -> []u8 {
	sectors := (size + USER_SIZE - 1) / USER_SIZE
	data := make([]u8, sectors * USER_SIZE)
	for i in 0 ..< sectors {
		image_sector(img, lba + i, data[i * USER_SIZE:])
	}
	return data[:size]
}

// The root directory's extent, from the primary volume descriptor.
iso_root :: proc(img: Image) -> (lba, size: int) {
	pvd: [USER_SIZE]u8
	image_sector(img, PVD_SECTOR, pvd[:])
	if string(pvd[1:6]) != "CD001" {
		fail("%s: no ISO 9660 volume (is it a raw 2352-byte BIN?)", img.path)
	}
	return int(u32le(pvd[:], 156 + 2)), int(u32le(pvd[:], 156 + 10))
}

// The records of one directory, less . and .., in disc order.
iso_records :: proc(img: Image, lba, size: int) -> []Iso_Record {
	data := image_extent(img, lba, size)
	recs: [dynamic]Iso_Record
	pos := 0
	for pos < len(data) {
		length := int(data[pos])
		if length == 0 {
			pos = (pos / USER_SIZE + 1) * USER_SIZE // records never cross a sector
			continue
		}
		rec := data[pos:pos + length]
		pos += length
		name := string(rec[33:33 + int(rec[32])])
		if name == "\x00" || name == "\x01" {
			continue
		}
		if semi := strings.index_byte(name, ';'); semi >= 0 {
			name = name[:semi]
		}
		append(&recs, Iso_Record{strings.clone(name), int(u32le(rec, 2)), int(u32le(rec, 10)), rec[25] & 2 != 0})
	}
	return recs[:]
}
