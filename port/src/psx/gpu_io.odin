// GPU ports: GP0 command FIFO with VRAM transfers, GP1 display control,
// GPUSTAT and GPUREAD.
package psx

import "core:fmt"

import "ps:core"

// Displayed VRAM region derived from GP1 state.
display: struct {
	x, y, w, h: i32,
	enabled:    bool,
	// 24-bit color: VRAM rows hold packed RGB888 bytes.
	depth24:    bool,
}

@(private)
Vram_Xfer :: struct {
	x, y, w, h: i32,
	// Pixel index within the rectangle.
	pos:        i32,
}

@(private)
gp: struct {
	cmd:      [dynamic]u32,
	// Words still expected for the command in `cmd` (0: none in progress).
	need:     int,
	polyline: bool,
	upload:   Vram_Xfer,
	uploading: bool,
	download: Vram_Xfer,
	downloading: bool,
	read_latch: u32,
	dma_dir:  u32,
	// GP1(05..08) display registers.
	disp_x, disp_y: i32,
	hrange:   [2]i32,
	vrange:   [2]i32,
	mode:     u32,
	enabled:  bool,
	odd:      bool,
}

@(private)
xfer_rect :: proc(w1, w2: u32) -> Vram_Xfer {
	w := i32(((w2 & 0xffff) - 1) & 0x3ff) + 1
	h := i32((((w2 >> 16) & 0xffff) - 1) & 0x1ff) + 1
	return {x = i32(w1 & 0x3ff), y = i32((w1 >> 16) & 0x1ff), w = w, h = h}
}

@(private)
upload_pixel :: proc(t: ^Vram_Xfer, p: u16) -> bool {
	x := t.x + t.pos % t.w
	y := t.y + t.pos / t.w
	raster_sync()
	if !(gpu.check_mask && vram_at(x, y)^ & 0x8000 != 0) {
		vram_put(x, y, gpu.set_mask ? p | 0x8000 : p)
	}
	t.pos += 1
	return t.pos < t.w * t.h
}

gp0_write :: proc(w: u32) {
	if gp.uploading {
		gp.uploading = upload_pixel(&gp.upload, u16(w)) && upload_pixel(&gp.upload, u16(w >> 16))
		return
	}
	if gp.need == 0 && !gp.polyline {
		op := w >> 24
		clear(&gp.cmd)
		switch {
		case op >> 5 == 2 && op & 0x08 != 0:
			gp.polyline = true
		case op >> 5 == 5 || op >> 5 == 6:
			gp.need = 3
		case:
			gp.need = cmd_len(op)
		}
	}
	append(&gp.cmd, w)
	if gp.polyline {
		// Terminator only counts after the first two vertices.
		if len(gp.cmd) >= 3 && w & 0xf000f000 == 0x50005000 {
			gp.polyline = false
			gp0_exec(gp.cmd[:])
		}
		return
	}
	gp.need -= 1
	if gp.need > 0 {
		return
	}
	gp0_command(gp.cmd[:])
}

@(private)
gp0_command :: proc(cmd: []u32) {
	if .Gpu in core.trace.active {
		core.tracef(.Gpu, "gp0 %x", cmd)
	}
	switch cmd[0] >> 29 {
	case 5:
		gp.upload = xfer_rect(cmd[1], cmd[2])
		gp.uploading = true
	case 6:
		gp.download = xfer_rect(cmd[1], cmd[2])
		gp.downloading = true
		hi_only_read(i32(gp.download.x), i32(gp.download.y), i32(gp.download.w), i32(gp.download.h))
	case:
		switch cmd[0] >> 24 {
		case 0x01, 0x00, 0x1f:
		// cache clear, nop, IRQ request
		case:
			gp0_exec(cmd)
		}
	}
}

gpu_read :: proc() -> u32 {
	if !gp.downloading {
		return gp.read_latch
	}
	raster_sync()
	t := &gp.download
	v: u32
	for k in u32(0) ..< 2 {
		if t.pos < t.w * t.h {
			v |= u32(vram_at(t.x + t.pos % t.w, t.y + t.pos / t.w)^) << (16 * k)
			t.pos += 1
		}
	}
	if t.pos >= t.w * t.h {
		gp.downloading = false
	}
	gp.read_latch = v
	return v
}

gpu_stat :: proc() -> u32 {
	s: u32 = 0x1c000000 // ready for command, VRAM read, DMA block
	s |= u32(gpu.tex_x / 64) | u32(gpu.tex_y / 256) << 4 | gpu.abr << 5 | gpu.tp << 7
	s |= (gp.mode & 0x3f) << 17 | ((gp.mode >> 6) & 1) << 16
	if gpu.dither {
		s |= 1 << 9
	}
	if gpu.set_mask {
		s |= 1 << 11
	}
	if gpu.check_mask {
		s |= 1 << 12
	}
	if !gp.enabled {
		s |= 1 << 23
	}
	s |= gp.dma_dir << 29
	switch gp.dma_dir {
	case 1, 2:
		s |= 1 << 25
	case 3:
		s |= 1 << 25
	}
	if gp.odd {
		s |= 1 << 31
	}
	return s
}

gp1_write :: proc(v: u32) {
	if .Gpu in core.trace.active {
		core.tracef(.Gpu, "gp1 %08x", v)
	}
	switch v >> 24 {
	case 0x00:
		gp.enabled = false
		gp.dma_dir = 0
		gp.need = 0
		gp.polyline = false
		gp.uploading = false
		gp.downloading = false
		gpu = {}
		gpu.x2, gpu.y2 = 1023, 511
	case 0x01:
		gp.need = 0
		gp.polyline = false
		gp.uploading = false
	case 0x03:
		gp.enabled = v & 1 == 0
	case 0x04:
		gp.dma_dir = v & 3
	case 0x05:
		gp.disp_x = i32(v & 0x3fe)
		gp.disp_y = i32((v >> 10) & 0x1ff)
	case 0x06:
		gp.hrange = {i32(v & 0xfff), i32((v >> 12) & 0xfff)}
	case 0x07:
		gp.vrange = {i32(v & 0x3ff), i32((v >> 10) & 0x3ff)}
	case 0x08:
		gp.mode = v & 0xff
	case 0x10:
		gp.read_latch = gpu_info(v & 0xf)
	}
	update_display()
}

@(private)
gpu_info :: proc(what: u32) -> u32 {
	switch what {
	case 2:
		return gpu.tw_mask_x | gpu.tw_mask_y << 5 | gpu.tw_off_x << 10 | gpu.tw_off_y << 15
	case 3:
		return u32(gpu.x1) | u32(gpu.y1) << 10
	case 4:
		return u32(gpu.x2) | u32(gpu.y2) << 10
	case 5:
		return (u32(gpu.off_x) & 0x7ff) | (u32(gpu.off_y) & 0x7ff) << 11
	case 7:
		return 2
	}
	return gp.read_latch
}

// Set the display start, as GP1 0x05 does: a switch of machine puts back the
// one its world was noted with.
display_start :: proc(x, y: i32) {
	gp.disp_x, gp.disp_y = x & 0x3fe, y & 0x1ff
	update_display()
}

@(private)
update_display :: proc() {
	widths := [4]i32{256, 320, 512, 640}
	w := widths[gp.mode & 3]
	if gp.mode & 0x40 != 0 {
		w = 368
	}
	lines := gp.vrange[1] - gp.vrange[0]
	if lines <= 0 || lines > 256 {
		lines = 240
	}
	if gp.mode & 0x24 == 0x24 {
		lines *= 2
	}
	display.x = gp.disp_x
	display.y = gp.disp_y
	display.w = w
	display.h = lines
	display.enabled = gp.enabled
	display.depth24 = gp.mode & 0x10 != 0
}

gpu_vblank :: proc() {
	gp.odd = !gp.odd
}
