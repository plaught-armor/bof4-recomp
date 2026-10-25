// CD-ROM controller (0x1f801800-0x1f801803) reading raw 2352-byte sectors
// from the BIN/CUE image.
package psx

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "ps:core"

@(private)
SECTOR_SIZE :: 2352
@(private)
PREGAP :: 150

// Command timings in CPU cycles.
@(private)
ACK_DELAY :: 25_000
@(private)
DONE_DELAY :: 120_000
@(private)
SEEK_DELAY :: 250_000
@(private)
READ_RETRY :: 2_000

@(private)
Track :: struct {
	file:    ^os.File,
	start:   u32, // first LBA
	sectors: u32,
}

@(private)
Cd_Int :: struct {
	kind:  u8,
	bytes: [dynamic]u8,
	delay: u64,
}

@(private)
cd: struct {
	tracks:   [dynamic]Track,
	index:    u32,
	params:   [dynamic]u8,
	response: [dynamic]u8,
	resp_pos: int,
	queue:    [dynamic]Cd_Int,
	// The BIOS boot leaves every drive interrupt enabled and the game never
	// sets them, so the drive starts that way (zero made
	// libcd's first command time out, a black screen of about 950 frames).
	int_en:   u8,
	int_flag: u8,
	busy:     bool,
	motor:    bool,
	reading:  bool,
	playing:  bool,
	mode:     u8,
	setloc:   u32,
	lba:      u32,
	sector:   [SECTOR_SIZE]u8,
	// Sector being read out through the data FIFO.
	fifo:     [SECTOR_SIZE]u8,
	data:     []u8,
	data_pos: int,
	// A sector arrived since the data FIFO was last loaded.
	fresh:    bool,
	// The last movie (STR) video sector read: its LBA and frame number.
	movie_lba:   u32,
	movie_frame: u32,
}

// Open the disc described by a CUE sheet with one BINARY file per track.
cdrom_open :: proc(cue_path: string) -> bool {
	cd.int_en = 0x1f
	text, err := os.read_entire_file(cue_path, context.allocator)
	if err != nil {
		fmt.eprintln("cdrom: cannot read", cue_path)
		return false
	}
	dir := filepath.dir(cue_path)
	lba: u32 = 0
	s := string(text)
	for line in strings.split_lines_iterator(&s) {
		l := strings.trim_space(line)
		if !strings.has_prefix(l, "FILE ") {
			continue
		}
		q1 := strings.index_byte(l, '"')
		q2 := strings.last_index_byte(l, '"')
		if q1 < 0 || q2 <= q1 {
			fmt.eprintln("cdrom: bad FILE line:", l)
			return false
		}
		path, _ := filepath.join({dir, l[q1 + 1:q2]}, context.allocator)
		f, ferr := os.open(path)
		if ferr != nil {
			fmt.eprintln("cdrom: cannot open", path)
			return false
		}
		size, _ := os.file_size(f)
		if len(cd.tracks) > 0 {
			lba += PREGAP
		}
		n := u32(size / SECTOR_SIZE)
		append(&cd.tracks, Track{f, lba, n})
		lba += n
	}
	return len(cd.tracks) > 0
}

// User data of a Mode 2 Form 1 sector: 2048 bytes after the 24-byte header.
DISC_DATA :: 2048
@(private = "file")
DISC_DATA_AT :: 24

// Read the user data of whole sectors from lba on into buf, a multiple of
// DISC_DATA long, outside of the drive's emulated timing (for port features
// that read game files themselves).
disc_read :: proc(lba: u32, buf: []u8) -> bool {
	assert(len(buf) % DISC_DATA == 0, "disc read not in whole sectors")
	raw: [SECTOR_SIZE]u8
	for i in 0 ..< len(buf) / DISC_DATA {
		if !read_sector(lba + u32(i), raw[:]) {
			return false
		}
		copy(buf[i * DISC_DATA:(i + 1) * DISC_DATA], raw[DISC_DATA_AT:DISC_DATA_AT + DISC_DATA])
	}
	return true
}

// Sectors that are not on the image: the qol package returns the 2048 bytes
// of user data of an added sector (one past the disc's end), or nil.
sector_hook: proc(lba: u32) -> []u8

@(private)
read_sector :: proc(lba: u32, buf: []u8) -> bool {
	if sector_hook != nil {
		if data := sector_hook(lba); data != nil {
			// A Mode 2 Form 1 data sector: sync, header, subheader, data.
			for &b in buf[:12] {
				b = 0xff
			}
			buf[0], buf[11] = 0, 0
			buf[12], buf[13], buf[14] = msf(lba)
			buf[15] = 2
			copy(buf[16:24], []u8{0, 0, 0x08, 0, 0, 0, 0x08, 0})
			copy(buf[DISC_DATA_AT:DISC_DATA_AT + DISC_DATA], data)
			return true
		}
	}
	for t in cd.tracks {
		if lba >= t.start && lba < t.start + t.sectors {
			n, err := os.read_at(t.file, buf, i64(lba - t.start) * SECTOR_SIZE)
			return err == nil && n == SECTOR_SIZE
		}
	}
	return false
}

@(private)
bcd :: #force_inline proc(v: u32) -> u8 {return u8((v / 10) << 4 | (v % 10))}
@(private)
unbcd :: #force_inline proc(v: u8) -> u32 {return u32(v >> 4) * 10 + u32(v & 0xf)}

@(private)
stat_byte :: proc() -> u8 {
	s: u8 = 0
	if cd.motor {
		s |= 0x02
	}
	if cd.reading {
		s |= 0x20
	}
	if cd.playing {
		s |= 0x80
	}
	return s
}

@(private)
queue_int :: proc(kind: u8, delay: u64, bytes: ..u8) {
	it := Cd_Int {
		kind  = kind,
		delay = delay,
	}
	append(&it.bytes, ..bytes)
	if .Cdrom in core.trace.active {
		core.tracef(.Cdrom, "queue int%d delay %d %x", kind, delay, bytes)
	}
	append(&cd.queue, it)
	if len(cd.queue) == 1 && cd.int_flag == 0 {
		schedule(.Cdrom, delay)
	}
}

@(private)
cdrom_event :: proc() {
	if len(cd.queue) == 0 || cd.int_flag != 0 {
		return
	}
	it := cd.queue[0]
	ordered_remove(&cd.queue, 0)
	clear(&cd.response)
	append(&cd.response, ..it.bytes[:])
	delete(it.bytes)
	cd.resp_pos = 0
	cd.int_flag = it.kind
	cd.busy = false
	if cd.int_en & it.kind != 0 {
		irq_raise(.Cdrom)
	}
}

// The movie (STR) frame most recently read from disc, and the LBA of its
// sector, which tells the movies apart; meaningful while movie_playing.
// Frames are read a little ahead of being shown.
movie_position :: proc() -> (lba, frame: u32) {
	return cd.movie_lba, cd.movie_frame
}

// Run when the drive starts reading at lba (data or XA); the qol package
// uses it to see which game file is being loaded.
read_start_hook: proc(lba: u32)

// Run after the drive's data is moved into RAM by DMA: the RAM address and
// byte count; the qol package uses it to see where a map's files land.
dma_cdrom_hook: proc(addr, size: u32)

@(private)
start_read :: proc() {
	cd.lba = cd.setloc
	if read_start_hook != nil {
		read_start_hook(cd.lba)
	}
	cd.reading = true
	cd.playing = false
	unschedule(.Cdrom_Read)
	schedule(.Cdrom_Read, SEEK_DELAY)
}

// The drive is reading data for the CPU. Real-time XA audio does not count.
@(private)
cd_loading :: proc() -> bool {
	return cd.reading && cd.mode & 0x40 == 0
}

@(private)
sector_cycles :: proc() -> u64 {
	return cd.mode & 0x80 != 0 ? CPU_HZ / 150 : CPU_HZ / 75
}

@(private)
cdrom_read_event :: proc() {
	if !cd.reading {
		return
	}
	if cd.int_flag != 0 || len(cd.queue) != 0 {
		schedule(.Cdrom_Read, READ_RETRY)
		return
	}
	if !read_sector(cd.lba, cd.sector[:]) {
		fmt.eprintfln("cdrom: read past end of disc at LBA %d", cd.lba)
		cd.reading = false
		queue_int(5, 0, stat_byte() | 0x01, 0x04)
		return
	}
	if .Cdrom in core.trace.active {
		core.tracef(.Cdrom, "sector lba %d", cd.lba)
	}
	// A movie's video sectors (data sectors to the drive) begin 60 01 01 80,
	// with the frame number at +8.
	submode := cd.sector[18]
	data := cd.sector[DISC_DATA_AT:]
	if (^u32le)(&data[0])^ == 0x80010160 {
		cd.movie_lba = cd.lba
		cd.movie_frame = u32((^u32le)(&data[8])^)
	}
	cd.lba += 1
	cd.fresh = true
	schedule(.Cdrom_Read, sector_cycles())
	// Real-time XA audio goes to the SPU, not the CPU.
	if cd.mode & 0x40 != 0 && submode & 0x04 != 0 {
		xa_sector(cd.sector[:])
		return
	}
	queue_int(1, 0, stat_byte())
}

@(private)
cdrom_command :: proc(c: u8) {
	p := cd.params[:]
	if .Cdrom in core.trace.active {
		core.tracef(.Cdrom, "command %02x params %x", c, p)
	}
	cd.busy = true
	switch c {
	case 0x01:
		queue_int(3, ACK_DELAY, stat_byte())
	case 0x02:
		if len(p) >= 3 {
			cd.setloc = (unbcd(p[0]) * 60 + unbcd(p[1])) * 75 + unbcd(p[2]) - PREGAP
		}
		queue_int(3, ACK_DELAY, stat_byte())
	case 0x03:
		cd.motor = true
		cd.playing = true
		queue_int(3, ACK_DELAY, stat_byte())
	case 0x06, 0x1b:
		cd.motor = true
		queue_int(3, ACK_DELAY, stat_byte())
		start_read()
	case 0x07:
		cd.motor = true
		queue_int(3, ACK_DELAY, stat_byte())
		queue_int(2, DONE_DELAY, stat_byte())
	case 0x08:
		cd.reading, cd.playing = false, false
		queue_int(3, ACK_DELAY, stat_byte())
		cd.motor = false
		queue_int(2, DONE_DELAY, stat_byte())
	case 0x09:
		queue_int(3, ACK_DELAY, stat_byte())
		cd.reading, cd.playing = false, false
		queue_int(2, DONE_DELAY, stat_byte())
	case 0x0a:
		cd.mode = 0
		cd.reading, cd.playing = false, false
		cd.motor = true
		queue_int(3, ACK_DELAY, stat_byte())
		queue_int(2, DONE_DELAY, stat_byte())
	case 0x0b, 0x0c:
		xa_set_muted(c == 0x0b)
		queue_int(3, ACK_DELAY, stat_byte())
	case 0x0d:
		if len(p) >= 2 {
			xa_set_filter(p[0], p[1])
		}
		queue_int(3, ACK_DELAY, stat_byte())
	case 0x0e:
		if len(p) >= 1 {
			cd.mode = p[0]
		}
		queue_int(3, ACK_DELAY, stat_byte())
	case 0x0f:
		queue_int(3, ACK_DELAY, stat_byte(), cd.mode, 0, 0, 0)
	case 0x10:
		h := cd.sector[12:20]
		queue_int(3, ACK_DELAY, h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
	case 0x11:
		cdrom_getlocp()
	case 0x13:
		queue_int(3, ACK_DELAY, stat_byte(), 1, bcd(u32(len(cd.tracks))))
	case 0x14:
		cdrom_gettd(len(p) > 0 ? unbcd(p[0]) : 0)
	case 0x15, 0x16:
		cd.reading, cd.playing = false, false
		cd.motor = true
		cd.lba = cd.setloc
		queue_int(3, ACK_DELAY, stat_byte())
		queue_int(2, SEEK_DELAY, stat_byte())
	case 0x19:
		queue_int(3, ACK_DELAY, 0x94, 0x09, 0x19, 0xc0)
	case 0x1a:
		queue_int(3, ACK_DELAY, stat_byte())
		queue_int(2, DONE_DELAY, 0x02, 0x00, 0x20, 0x00, 'S', 'C', 'E', 'A')
	case 0x1c:
		queue_int(3, ACK_DELAY, stat_byte())
	case 0x1e:
		queue_int(3, ACK_DELAY, stat_byte())
		queue_int(2, DONE_DELAY, stat_byte())
	case:
		fmt.eprintfln("cdrom: unknown command %#02x", c)
		queue_int(5, ACK_DELAY, stat_byte() | 0x01, 0x40)
	}
	clear(&cd.params)
}

@(private)
msf :: proc(lba: u32) -> (u8, u8, u8) {
	a := lba + PREGAP
	return bcd(a / 4500), bcd((a / 75) % 60), bcd(a % 75)
}

@(private)
cdrom_getlocp :: proc() {
	cur := cd.lba > 0 ? cd.lba - 1 : 0
	track: u32 = 1
	start: u32 = 0
	for t, i in cd.tracks {
		if cur >= t.start {
			track = u32(i + 1)
			start = t.start
		}
	}
	rm, rs, rf := msf(cur - start - PREGAP if cur - start >= PREGAP else 0)
	am, as_, af := msf(cur)
	queue_int(3, ACK_DELAY, bcd(track), 1, rm, rs, rf, am, as_, af)
}

@(private)
cdrom_gettd :: proc(track: u32) {
	lba: u32
	switch {
	case track == 0:
		last := cd.tracks[len(cd.tracks) - 1]
		lba = last.start + last.sectors
	case int(track) <= len(cd.tracks):
		lba = cd.tracks[track - 1].start
	case:
		queue_int(5, ACK_DELAY, stat_byte() | 0x01, 0x10)
		return
	}
	m, s, _ := msf(lba)
	queue_int(3, ACK_DELAY, stat_byte(), m, s)
}

@(private)
load_data_fifo :: proc(want: bool) {
	if !want {
		cd.data = nil
		cd.data_pos = 0
		return
	}
	// Requesting data while the FIFO still holds bytes continues where the
	// last transfer stopped: libcd reads the header and the payload with
	// separate DMAs. A new sector loads only once the FIFO is drained.
	if cd.data != nil && cd.data_pos < len(cd.data) {
		return
	}
	if !cd.fresh && cd.data != nil {
		return
	}
	cd.fresh = false
	// The FIFO is its own buffer: the drive keeps reading into cd.sector
	// while the CPU drains the previous sector.
	cd.fifo = cd.sector
	if cd.mode & 0x20 != 0 {
		cd.data = cd.fifo[12:SECTOR_SIZE]
	} else {
		cd.data = cd.fifo[24:24 + 2048]
	}
	cd.data_pos = 0
}

@(private)
data_byte :: proc() -> u8 {
	if cd.data_pos >= len(cd.data) {
		return 0
	}
	b := cd.data[cd.data_pos]
	cd.data_pos += 1
	return b
}

cdrom_read :: proc(reg: u32) -> u32 {
	switch reg {
	case 0:
		s := u8(cd.index)
		if len(cd.params) == 0 {
			s |= 0x08
		}
		if len(cd.params) < 16 {
			s |= 0x10
		}
		if cd.resp_pos < len(cd.response) {
			s |= 0x20
		}
		if cd.data_pos < len(cd.data) {
			s |= 0x40
		}
		if cd.busy {
			s |= 0x80
		}
		return u32(s)
	case 1:
		if cd.resp_pos < len(cd.response) {
			b := cd.response[cd.resp_pos]
			cd.resp_pos += 1
			return u32(b)
		}
		return 0
	case 2:
		return u32(data_byte())
	}
	if cd.index & 1 == 0 {
		return 0xe0 | u32(cd.int_en)
	}
	return 0xe0 | u32(cd.int_flag)
}

cdrom_write :: proc(reg, v: u32) {
	b := u8(v)
	switch reg {
	case 0:
		cd.index = v & 3
		return
	case 1:
		switch cd.index {
		case 0:
			cdrom_command(b)
		case 3:
			xa_set_volume(2, b)
		}
	case 2:
		switch cd.index {
		case 0:
			if len(cd.params) < 16 {
				append(&cd.params, b)
			}
		case 1:
			cd.int_en = b & 0x1f
		case 2:
			xa_set_volume(0, b)
		case 3:
			xa_set_volume(3, b)
		}
	case 3:
		switch cd.index {
		case 0:
			load_data_fifo(b & 0x80 != 0)
		case 1:
			cdrom_ack(b)
		case 2:
			xa_set_volume(1, b)
		case 3:
			xa_apply(b)
		}
	}
}

@(private)
cdrom_ack :: proc(b: u8) {
	cd.int_flag &= ~(b & 0x1f)
	if b & 0x40 != 0 {
		clear(&cd.params)
	}
	if cd.int_flag == 0 && len(cd.queue) > 0 {
		schedule(.Cdrom, max(cd.queue[0].delay / 4, 500))
	}
}

dma_cdrom :: proc(c: ^Dma_Channel) {
	n := dma_words(c)
	a := c.madr & 0x1ffffc
	for _ in 0 ..< n {
		w := u32(data_byte()) | u32(data_byte()) << 8 | u32(data_byte()) << 16 | u32(data_byte()) << 24
		w32(a, w)
		a += 4
	}
	if dma_cdrom_hook != nil {
		dma_cdrom_hook(0x80000000 | c.madr & 0x1ffffc, n * 4)
	}
}
