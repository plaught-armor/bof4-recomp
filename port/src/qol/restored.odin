// Equipment and items the US release never hands out (docs/battle.md, "Never-
// granted items"), sold in shops with `[field] restored_items`: Cray's Pole,
// the Slayer, Wassail + and Draught +. Ershin's armor 49-69, the Spanner, the
// Speed, Reflex and Sight Seeds, Wassail and Draught are not among them: the
// junk smith forges the armor, Gyosil gives the Spanner and the faerie
// village grows the rest.
//
// SHOP_COPY copies the shop's (id, kind) pairs from the table in the SHOP
// overlay into the buy list, as they are; the list's count was set
// from the table just before. After it, the shop's added goods go on the end
// of the list and the count grows. The list scrolls past 8 rows, and nothing
// in the game reads the bytes after it. The table is checked against the
// vanilla hash (pairs only: one shop's count is rewritten in place) before
// anything is added.
//
// The cut goods' table prices never had to fit a shop: the Slayer, which
// sometimes attacks allies, costs twice the Slicer, so it is repriced under
// the Slicer. The drinks and Pole already fit their siblings. The rows
// are captured when they hash to vanilla and swapped like balance.odin's
// tables, so turning the option off restores them at once. Prices are sell
// prices; the buy price is twice the table's.
package qol

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:strconv"

import cpu "ps:psx/cpu"

import "ps:core"

@(private = "file")
SHOP_ID :: 0x12
@(private = "file")
SHOP_COPY :: 0x801af694
@(private = "file")
SHOP_INDEX :: 0x8011a909 // u8
@(private = "file")
SHOP_TABLE :: 0x801af9a8 // 32 bytes a shop: u8 count, u8 0, then (id, kind) pairs
@(private = "file")
SHOP_SIZE :: 32
@(private = "file")
SHOP_COUNT :: 41
@(private = "file")
SHOP_TABLE_HASH :: 0x6acd65b4 // FNV-1a with each count zeroed
@(private = "file")
BUY_LIST :: 0x801e8aa8 // (id, kind) bytes
@(private = "file")
BUY_COUNT :: 0x8011dc83 // the list window's count (window 0x8011dc5c + 24, +15)

@(private = "file")
GAME_ID :: 0x0e
@(private = "file")
WEAPONS :: 0x8019a154 // 14 bytes per weapon, u16 price at +12

// A run of rows in one of GAME's equipment tables whose prices change.
@(private = "file")
Repricing :: struct {
	table:        u32,
	row_size:     u32,
	price_at:     u32,
	first:        u32,
	hash:         u32, // FNV-1a of the vanilla rows
	prices:       []u16,
	using backup: Captured,
}

@(private = "file")
Captured :: struct {
	captured: bool,
	vanilla:  [MAX_REPRICED]u8,
	patched:  [MAX_REPRICED]u8,
}

@(private = "file")
MAX_REPRICED :: 14

// Item kinds in shop lists.
@(private = "file")
Kind :: enum u8 {
	Item,
	Weapon,
	Armor,
	Accessory,
}

@(private = "file")
Good :: struct {
	kind: Kind,
	id:   u8,
}

@(private = "file")
Added :: struct {
	shop:  u8,
	goods: []Good,
}

// Late shops: 36 is AREAM018's (1012), 38 a hidden seller in AREAD004 (script
// op a0 sets it). Nothing opens shop 37 (docs/battle.md, "Shops by map").
@(private = "file")
ADDED := [?]Added {
	{36, {{.Weapon, 53}, {.Item, 108}, {.Item, 110}}},
	{38, {{.Weapon, 84}}},
}

// Sell prices (half the buy price).
@(private = "file")
REPRICED := [?]Repricing {
	{
		table = WEAPONS,
		row_size = 14,
		price_at = 12,
		first = 84,
		hash = 0x609b87fc,
		prices = {
			8000, // Slayer: 80, two hits, sometimes attacks allies (Slicer 78 10000z, Pole 66 8000z)
		},
	},
}

@(private = "file")
restored: struct {
	copy:     cpu.Func_Proc,
	forced:   bool, // BOF4_SHOP=<index>: every shop opens as that one (testing)
	force:    u32,
}

@(private)
restored_init :: proc() -> bool {
	copy_fn, ok := cpu.hook_overlay(SHOP_COPY, SLOT_MENU, SHOP_ID, shop_copy)
	if !ok {
		fmt.eprintf("qol: restored items function %08x not found\n", SHOP_COPY)
		return false
	}
	restored.copy = copy_fn
	if v, found := os.lookup_env("BOF4_SHOP", context.temp_allocator); found {
		n, n_ok := strconv.parse_uint(v)
		restored.forced = n_ok && n < SHOP_COUNT
		restored.force = u32(n)
	}
	return true
}

@(private)
restored_vblank :: proc() {
	if cpu.r32(SLOT_GAME) != GAME_ID {
		return
	}
	for &r in REPRICED {
		reprice(&r)
	}
}

@(private = "file")
reprice :: proc(r: ^Repricing) {
	size := r.row_size * u32(len(r.prices))
	live := cpu.mem_slice(r.table + r.first * r.row_size, size)
	vanilla, patched := r.vanilla[:size], r.patched[:size]
	if !r.captured {
		if hash.fnv32a(live) != r.hash {
			return
		}
		copy(vanilla, live)
		copy(patched, live)
		for price, i in r.prices {
			at := patched[u32(i) * r.row_size + r.price_at:]
			at[0], at[1] = u8(price), u8(price >> 8)
		}
		r.captured = true
	}
	want, other := patched, vanilla
	if !config.field_restored_items {
		want, other = other, want
	}
	if mem.compare(live, other) == 0 {
		copy(live, want)
	}
}

@(private = "file")
shop_copy :: proc() {
	if restored.forced {
		cpu.sb(SHOP_INDEX, restored.force)
		cpu.sb(BUY_COUNT, cpu.lbu(SHOP_TABLE + restored.force * SHOP_SIZE))
	}
	restored.copy()
	if !config.field_restored_items {
		return
	}
	shop := cpu.lbu(SHOP_INDEX)
	goods: []Good
	for a in ADDED {
		if u32(a.shop) == shop {
			goods = a.goods
		}
	}
	if goods == nil || !shop_table_vanilla() {
		return
	}
	count := cpu.lbu(BUY_COUNT)
	for g, i in goods {
		at := BUY_LIST + (count + u32(i)) * 2
		cpu.sb(at, u32(g.id))
		cpu.sb(at + 1, u32(g.kind))
	}
	cpu.sb(BUY_COUNT, count + u32(len(goods)))
	if .Game in core.trace.active {
		core.tracef(.Game, "restored: shop %d gets %d more goods", shop, len(goods))
	}
}

@(private = "file")
shop_table_vanilla :: proc() -> bool {
	table: [SHOP_COUNT * SHOP_SIZE]u8
	copy(table[:], cpu.mem_slice(SHOP_TABLE, u32(len(table))))
	for s in 0 ..< SHOP_COUNT {
		table[s * SHOP_SIZE] = 0
		table[s * SHOP_SIZE + 1] = 0
	}
	return hash.fnv32a(table[:]) == SHOP_TABLE_HASH
}
