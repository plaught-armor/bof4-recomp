// SIO0 (0x1f801040-0x1f80104f): controller port 1 and the pad on it.
// Memory cards and port 2 answer as absent.
//
// The pad is a digital pad (ID 0x41), or a DualShock when rumble is enabled
// (pad_set_rumble). The DualShock follows the SCPH-1200 protocol: it answers
// the 0x42 poll like a digital pad until the game switches it to analog mode
// (ID 0x73, sticks after the buttons), and accepts the config-mode commands
// 0x43..0x4f (ID 0xf3) libpad sends to identify it and to map the motors.
// Each transaction is: 0x01 address, command (reply = ID), 0x00 (reply 0x5a),
// then argument bytes, each answered by one data byte. The controller state
// lives outside `sio` because an SIO reset does not reset the pad.
package psx

import "ps:core"

@(private)
SIO_ACK_DELAY :: 400
// Data bytes after the 0x5a byte: digital pad, analog mode and config mode.
@(private)
PAD_DATA_DIGITAL :: 2
@(private)
PAD_DATA_FULL :: 6
// Motor map entries (command 0x4d): which motor a poll argument byte drives.
@(private)
MOTOR_SMALL :: 0x00
@(private)
MOTOR_LARGE :: 0x01
@(private)
MOTOR_NONE :: 0xff

@(private)
sio: struct {
	ctrl:   u32,
	mode:   u32,
	baud:   u32,
	rx:     u8,
	rx_full: bool,
	// Byte position within the current pad transaction; -1 when no device answers.
	step:   int,
	ack:    bool,
	irq:    bool,
}

@(private)
pad: struct {
	dualshock: bool,
	analog:    bool,
	config:    bool,
	// Command byte of the current transaction and its reply data.
	cmd:       u8,
	data:      [PAD_DATA_FULL]u8,
	size:      int,
	motor_map: [PAD_DATA_FULL]u8,
	small:     bool,
	large:     u8,
}

// Enable or disable the DualShock with its motors; strength 0 keeps the plain
// digital pad. Call before the game starts.
pad_set_rumble :: proc(strength: f64) {
	pad.dualshock = strength > 0
	pad.motor_map = MOTOR_NONE
	core.input.rumble_strength = f32(clamp(strength, 0, 1))
}

@(private)
pad_id :: proc() -> u8 {
	switch {
	case pad.config:
		return 0xf3
	case pad.analog:
		return 0x73
	}
	return 0x41
}

@(private)
pad_response :: proc(tx: u8) -> (u8, bool) {
	switch sio.step {
	case 0:
		if tx != 0x01 {
			sio.step = -1
			return 0xff, false
		}
		return 0xff, true
	case 1:
		return pad_command(tx)
	case 2:
		return 0x5a, true
	}
	k := sio.step - 3
	if k >= pad.size {
		return 0xff, false
	}
	rx := pad.data[k]
	pad_argument(k, tx)
	return rx, k + 1 < pad.size
}

// The command byte: pick the reply data. Returns the ID byte.
@(private)
pad_command :: proc(cmd: u8) -> (u8, bool) {
	pad.cmd = cmd
	pad.data = {}
	pad.size = PAD_DATA_FULL
	id := pad_id()
	if pad.config {
		return id, pad_config_reply(cmd)
	}
	if cmd != 0x42 && !(cmd == 0x43 && pad.dualshock) {
		return id, false
	}
	b := ~pad_game()
	pad.data[0] = u8(b >> 8)
	pad.data[1] = u8(b)
	if !pad.analog {
		pad.size = PAD_DATA_DIGITAL
		return id, true
	}
	s := sticks()
	pad.data[2] = stick_byte(s.right.x)
	pad.data[3] = stick_byte(s.right.y)
	pad.data[4] = stick_byte(s.left.x)
	pad.data[5] = stick_byte(s.left.y)
	return id, true
}

// Stick axis -1..1 as the pad's 0x00..0xff with 0x80 at rest.
@(private)
stick_byte :: proc(v: f32) -> u8 {
	return u8(clamp(128 + v * 128, 0, 255))
}

// Reply data of a config-mode command; false when the pad ignores it.
@(private)
pad_config_reply :: proc(cmd: u8) -> bool {
	switch cmd {
	case 0x42, 0x43, 0x44, 0x4f:
	case 0x45:
		pad.data = {0x03, 0x02, u8(pad.analog), 0x02, 0x01, 0x00}
	case 0x47:
		pad.data = {0x00, 0x00, 0x02, 0x00, 0x01, 0x00}
	case 0x4d:
		pad.data = pad.motor_map
	case 0x46, 0x4c:
		// Filled once the selector argument arrives (pad_argument).
	case 0x40, 0x41, 0x48, 0x49, 0x4a, 0x4b, 0x4e:
	case:
		return false
	}
	return true
}

// One argument byte, sent while data byte k goes back.
@(private)
pad_argument :: proc(k: int, tx: u8) {
	switch {
	case pad.cmd == 0x42 && !pad.config && pad.dualshock:
		pad_motor_byte(k, tx)
	case pad.cmd == 0x43 && k == 0:
		pad.config = tx == 0x01
	case !pad.config:
	case pad.cmd == 0x44 && k == 0:
		pad.analog = tx == 0x01
	case pad.cmd == 0x46 && k == 0:
		pad.data[2] = 0x01
		if tx == 0 {
			pad.data[3], pad.data[4], pad.data[5] = 0x02, 0x00, 0x0a
		} else {
			pad.data[3], pad.data[4], pad.data[5] = 0x01, 0x01, 0x14
		}
	case pad.cmd == 0x4c && k == 0:
		pad.data[3] = tx == 0 ? 0x04 : 0x07
	case pad.cmd == 0x4d:
		pad.motor_map[k] = tx
	}
}

// A poll argument byte drives the motor the map gives it: the small motor
// is on or off (bit 0), the large one takes a speed 0..255.
@(private)
pad_motor_byte :: proc(k: int, tx: u8) {
	small, large := pad.small, pad.large
	switch pad.motor_map[k] {
	case MOTOR_SMALL:
		pad.small = tx & 1 != 0
	case MOTOR_LARGE:
		pad.large = tx
	case:
		return
	}
	if .Sio in core.trace.active && (small != pad.small || large != pad.large) {
		core.tracef(.Sio, "motor small %v large %d", pad.small, pad.large)
	}
	pad_rumble(pad.small, pad.large)
}

@(private)
sio_transfer :: proc(tx: u8) {
	if .Sio in core.trace.active {
		core.tracef(.Sio, "tx %02x step %d ctrl %x ra=%x", tx, sio.step, sio.ctrl, cpu.r[31])
	}
	sio.rx_full = true
	selected := sio.ctrl & 0x2 != 0
	if !selected || sio.ctrl & 0x2000 != 0 || sio.step < 0 {
		sio.rx = 0xff
		return
	}
	rx, ack := pad_response(tx)
	if .Sio in core.trace.active {
		core.tracef(.Sio, "rx %02x ack %v", rx, ack)
	}
	sio.rx = rx
	if sio.step >= 0 {
		sio.step += 1
	}
	if ack {
		schedule(.Sio, SIO_ACK_DELAY)
	}
}

@(private)
sio_event :: proc() {
	if .Sio in core.trace.active {
		core.tracef(.Sio, "ack ctrl %x", sio.ctrl)
	}
	sio.ack = true
	if sio.ctrl & 0x1000 != 0 {
		sio.irq = true
		irq_raise(.Sio0)
	}
}

sio0_read :: proc(reg, size: u32) -> u32 {
	switch reg {
	case 0:
		v := sio.rx
		sio.rx = 0xff
		sio.rx_full = false
		return u32(v)
	case 4:
		s: u32 = 0x5 // TX ready, TX finished
		if sio.rx_full {
			s |= 0x2
		}
		if sio.ack {
			s |= 0x80
			sio.ack = false
		}
		if sio.irq {
			s |= 0x200
		}
		return s
	case 8:
		return sio.mode
	case 0xa:
		return sio.ctrl
	case 0xe:
		return sio.baud
	}
	return 0
}

sio0_write :: proc(reg, v, size: u32) {
	switch reg {
	case 0:
		sio_transfer(u8(v))
	case 8:
		sio.mode = v & 0xffff
	case 0xa:
		if v & 0x40 != 0 {
			sio = {}
			return
		}
		if v & 0x10 != 0 {
			sio.irq = false
		}
		if v & 0x2 == 0 || (v ~ sio.ctrl) & 0x2000 != 0 {
			sio.step = 0
		}
		sio.ctrl = v & ~u32(0x50)
	case 0xe:
		sio.baud = v & 0xffff
	}
}
