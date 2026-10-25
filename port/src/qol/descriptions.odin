// Gear descriptions that name what the battle code does but the US text
// leaves out (`[text] descriptions`). Each weapon, armor and accessory has its
// own description id in the 0x4000 bank (weapon record +10, armor and
// accessory record +8), so a rewrite swaps MESSAGE_TEXT's answer for that id.
// Every effect here was read from the code, not taken from a fan hack; see
// docs/battle.md "Item descriptions".
//
// Strings in the bank share their endings, so none can be edited in place:
// the new text goes to a slot of its own past the bank's end. The bank is
// loaded at 0x80017000 in camp, shops and battle alike, but other banks load
// there too, so a rewrite fires only when the vanilla text at the game's
// pointer is the one the rewrite was written against.
package qol

import "core:hash"

import cpu "ps:psx/cpu"

@(private = "file")
DESCRIPTION_BANK :: 2 // MESSAGE_TEXT's bank number (id >> 13) for item descriptions
// The bank (21874 bytes from 0x80017000) ends at 0x8001c572. No EMI entry
// loads between there and the item names at 0x80021800, and RAM dumps in camp
// and battle show the gap all zero.
@(private = "file")
TEXT_AT :: 0x8001d000
@(private = "file")
TEXT_MAX :: 0x1000
// Bytes of the vanilla text hashed to recognise it (every rewritten one is
// longer).
@(private = "file")
VANILLA_PREFIX :: 24

@(private = "file")
Description :: struct {
	id:      u16,
	vanilla: u32, // FNV-1a of the vanilla text's first VANILLA_PREFIX bytes
	text:    string,
}

// Codes: 0x01 new line, 0x07 n a parameter (1 Pwr/Def, 2 Wgt, 6 element),
// 0x05 2 .. 0x04 6 a coloured skill name (0x09 n), 0x19 lo hi ends with
// string lo | hi << 8 (0x4014 "Pwr Wgt  Ranged", 0x405e "Def Wgt Blessed
// armor"). A line holds about 34 characters, a number about 3.
@(private = "file")
DESCRIPTIONS :: [?]Description {
	{0x40d4, 0x2e7d6efe, "Pwr\x07\x01 Wgt\x07\x02  x1.5 vs. Dragons\x01Has same effect as \x05\x02\x09&\x04\x06."}, // weapon 19 Dragon Blade
	{0x40d5, 0xf9b131a3, "Pwr\x07\x01 Wgt\x07\x02  Holy attack +1 Hits\x01Has same effect as \x05\x02\x095\x04\x06."}, // weapon 20 Royal Sword
	{0x40d7, 0x039a5b04, "Pwr\x07\x01 Wgt\x07\x02  x2 dmg at full HP,\x01less as HP falls. Drains 1/16 HP."}, // weapon 22 Cursed Sword
	{0x40dd, 0x9183de75, "Pwr\x07\x01 Wgt\x07\x02\x01x1.5 damage to Dragons."}, // weapon 28 Cleaver
	{0x40de, 0xb1978490, "Pwr\x07\x01 Wgt\x07\x02 \x07\x06 +1 Hits \x05\x02\x09\x07\x04\x06\x01Pwr +1 per 20 battles, up to +50."}, // weapon 29 Render
	{0x40e9, 0xe64742a8, "Pwr\x07\x01 Wgt\x07\x02 Ranged \x07\x06 \x05\x02\x09,\x04\x06\x01Slightly resists Holy and Death."}, // weapon 40 BlessedStaff
	{0x40ea, 0x66e7ba50, "Pwr\x07\x01 Wgt\x07\x02 Ranged \x05\x02\x091\x04\x06\x01Resists Status and Death attacks."}, // weapon 41 Ouroboros
	{0x40fa, 0xc19755ac, "Dmg x1.25 if foe's level is higher\x01Pwr\x07\x01 Wgt\x07\x02  otherwise x0.75."}, // weapon 57 Linked Pole
	{0x4109, 0xcbe64965, "Tracks its target: never misses.\x01\x19\x14@"}, // weapon 72 Homing Bomb
	{0x410e, 0x85d55596, "Pwr\x07\x01 Wgt\x07\x02        Ranged attack\x01x1.5 damage to Demons."}, // weapon 77 Ghostbuster
	{0x41e8, 0xffb65c51, "Pwr\x07\x01 Wgt\x07\x02    +1 Hits\x01Drains 1/8 dmg; hits ally 1 in 16."}, // weapon 84 Slayer
	{0x4203, 0xeb9d70e0, "God-killer: x3 vs. Ryu and Fou-lu.\x01Pwr\x07\x01 Wgt\x07\x02"}, // weapon 86 Dragonslayer
	{0x406f, 0x108e56f2, "Resists Mind, Status and Death.\x01\x19^@"}, // armor 15 Mist Armor
	{0x4087, 0x82540728, "Slightly resists Mind/Status/Death\x01\x19^@"}, // armor 39 Holy Robe
	{0x4089, 0x3d94671a, "Resists Mind, Status and Death.\x01\x19^@"}, // armor 41 Diana'sDress
	{0x4228, 0x29e2f284, "Def\x07\x01 Wgt\x07\x02   Strong vs. Fire,\x01weak vs. Water."}, // armor 59 Fire Rig
	{0x4229, 0x29e2f284, "Def\x07\x01 Wgt\x07\x02   Strong vs. Wind,\x01weak vs. Earth."}, // armor 60 Whirlwind
	{0x422a, 0x39b1226f, "Def\x07\x01 Wgt\x07\x02  Strong vs. Water,\x01weak vs. Fire."}, // armor 61 Water Rig
	{0x422b, 0x39b1226f, "Def\x07\x01 Wgt\x07\x02  Strong vs. Earth,\x01weak vs. Wind."}, // armor 62 Earth Rig
	{0x4092, 0xe075de37, "Def\x07\x01 Wgt\x07\x02      Immune to Death\x01attacks."}, // acc 7 Divine Helm
	{0x4096, 0xa6e82926, "Slightly resists Mind/Status/Death\x01\x19^@"}, // acc 11 Dragon Helm
	{0x40af, 0xa513d8a1, "Holy stone; increases Healing\x01magic to max. Absorbs Holy."}, // acc 36 Topaz Tear
}

@(private = "file")
descriptions: struct {
	message_text: cpu.Func_Proc,
	slot:         [len(DESCRIPTIONS)]u32,
}

@(private)
descriptions_init :: proc() -> bool {
	at := u32(TEXT_AT)
	for d, i in DESCRIPTIONS {
		descriptions.slot[i] = at
		at += u32(len(d.text)) + 1
	}
	assert(at <= TEXT_AT + TEXT_MAX, "description text past its buffer")
	descriptions.message_text = cpu.hook(MESSAGE_TEXT, message_text) or_return
	return true
}

@(private = "file")
message_text :: proc() {
	id := cpu.state.r[4] & 0xffff
	descriptions.message_text()
	if !config.text_descriptions || id >> 13 != DESCRIPTION_BANK {
		return
	}
	vanilla := cpu.state.r[2]
	for d, i in DESCRIPTIONS {
		if u32(d.id) != id {
			continue
		}
		if !in_ram(vanilla) || hash.fnv32a(cpu.mem_slice(vanilla, VANILLA_PREFIX)) != d.vanilla {
			return
		}
		at := descriptions.slot[i]
		for b, k in transmute([]u8)d.text {
			cpu.sb(at + u32(k), u32(b))
		}
		cpu.sb(at + u32(len(d.text)), 0)
		cpu.state.r[2] = at
		return
	}
}
