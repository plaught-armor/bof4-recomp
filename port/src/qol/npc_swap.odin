// Debug aid: with BOF4_NPC_SPRITE=<from>:<to>[:<x>,<z>] (sprite ids in hex,
// tile x/z in decimal), every NPC spawned with sprite <from> gets sprite <to>
// instead, and stands at x,z when given. Used to look at the
// sprites a map's sprite table lists (map file entry 0x8004e000) but no NPC
// ever shows: warp to the map and swap one of its NPCs for them.
//
// FLD_MAIN's NPC init 0x801e0598 (a0 the NPC slot, a1 the 13-byte spawn
// record) reads the sprite id from u16 record +1; the record sits in the map
// overlay, so it is rewritten there before the original runs. Bytes +3/+4
// are the tile x/z. Every NPC spawned is logged (sprite, tile, script), so
// a swap of 0:0 lists a map's NPCs.
package qol

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import cpu "ps:psx/cpu"

@(private = "file")
NPC_INIT :: 0x801e0598

@(private = "file")
npc_swap: struct {
	init:     cpu.Func_Proc,
	from, to: u16,
	x, z:     u8,
	moved:    bool,
}

@(private)
npc_swap_init :: proc() -> bool {
	spec := os.get_env("BOF4_NPC_SPRITE", context.temp_allocator)
	if spec == "" {
		return true
	}
	from, _, rest := strings.partition(spec, ":")
	to, _, place := strings.partition(rest, ":")
	f, ok_f := strconv.parse_uint(from, 16)
	t, ok_t := strconv.parse_uint(to, 16)
	ok_p := true
	if place != "" {
		xs, _, zs := strings.partition(place, ",")
		x, ok_x := strconv.parse_uint(xs, 10)
		z, ok_z := strconv.parse_uint(zs, 10)
		ok_p = ok_x && ok_z && x <= 0xff && z <= 0xff
		npc_swap.x, npc_swap.z, npc_swap.moved = u8(x), u8(z), true
	}
	if !ok_f || !ok_t || !ok_p || f > 0xffff || t > 0xffff {
		fmt.eprintln("BOF4_NPC_SPRITE: expected <from>:<to>[:<x>,<z>], sprite ids in hex; got", spec)
		return false
	}
	npc_swap.from, npc_swap.to = u16(f), u16(t)
	ok: bool
	npc_swap.init, ok = hook_field(NPC_INIT, npc_init)
	return ok
}

@(private = "file")
npc_init :: proc() {
	record := cpu.state.r[5]
	fmt.printfln("npc sprite %x at %d,%d script %d", cpu.lbu(record + 1) | cpu.lbu(record + 2) << 8,
		cpu.lbu(record + 3), cpu.lbu(record + 4), cpu.lbu(record + 12))
	if cpu.lbu(record + 1) | cpu.lbu(record + 2) << 8 == u32(npc_swap.from) {
		cpu.sb(record + 1, u32(npc_swap.to) & 0xff)
		cpu.sb(record + 2, u32(npc_swap.to) >> 8)
		if npc_swap.moved {
			cpu.sb(record + 3, u32(npc_swap.x))
			cpu.sb(record + 4, u32(npc_swap.z))
		}
	}
	npc_swap.init()
}
