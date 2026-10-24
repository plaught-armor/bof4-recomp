# Wizard Mode mod: what it changes

Reference notes on the fan "BoF4 Wizard Mode" hard mod (USA disc only; a
demo that runs up to the Maman fight). Read from the PPF patch
`Some equipment raises AP.ppf` (PPF3.0, PPF-Studio v1.01, undo data
included; 40390 records, all undo bytes match a clean USA image). This page
describes the changes only; none of the mod's data or text is shipped with
the port.

Sources:
- https://gamefaqs.gamespot.com/boards/196818-breath-of-fire-iv/80928437
- https://gamefaqs.gamespot.com/boards/196818-breath-of-fire-iv/80519675

Its stated aims: magic and combos matter, new enemy AI, reworked spells,
equipment and text, elemental weaknesses count for more, all equipment gives
Wisdom.

Field meanings below come from [battle.md](battle.md) where they were
already decoded; ones marked *guess* were read from the values alone.

## Files touched

| File | What changes |
|---|---|
| GAME.EMI entry 0 (0x8018d800) | item/weapon/armor/accessory, skill, growth and master tables; entry grows 0x141a0 -> 0x1425c (code appended) |
| GAME.EMI entry 1 (0x801aa000) | code/data |
| INIT.EMI entry 6 (0x80021800..0x80023704) | item and skill names; entry 0 (VRAM) |
| AB000_00.EMI entries 3/4 | text at 0x80010000 / 0x80017000 |
| SHOP, SGAMEN, CAMP, MASTER, MSHOP, COMMU03 | help/description text at 0x80017000 (about 3.8 KB each) |
| BTLMOVE.EMI (0x801cc800) | battle code, entry grows |
| BTLEND, BTLCOMD | battle end / command code |
| BWORLD AREAB*, BOSS* | enemy records (0x801f5800), plus the 0x801aa000 and 0x801cc800 entries (AI) |
| BMAGIC MAGIC*.EMI | 2 bytes each |
| some WORLD area files | field data |

## Items

- Healing Herb price 10 -> 75.
- Bombs hit much harder and cost more (Void Sphere / Dynamite power 6 -> 30,
  Taser 12 -> 50).
- Ginseng, Dragon Scale, Headband price 100 -> 10.

## Weapons (14-byte table 0x8019a154)

- +6 (formerly "unknown, 0..0x10") is raised on every weapon to about its
  attack or more: Rune Staff 2 -> 250, Royal Sword 220, Render 225,
  Ouroboros 200. Most likely the weapon's **Wisdom bonus** (matches the
  "all equipment gives Wisdom" aim). Not yet verified in game. The
  unmodded stat rebuild reads no table byte for Wisdom (it adds Wisdom by
  item id, see [battle.md](battle.md) Weapons), so the mod's appended code
  would have to read this byte (and armor +5 below).
- +7 high nibble 1 -> 2 on most one-hit weapons (Ouroboros 0x13 -> 0x33).
  Meaning of that nibble now uncertain (hit count vs something else).
- Some attack raised: King's Sword 12 -> 25, PointedStick 2 -> 50,
  Render 50 -> 100.

## Armor and accessories

- +5 is probably Wisdom: Mage's Robes 3 -> 30, Fancy Dress 2 -> 8, Wisdom
  Ring 2 -> 60, Medallion 0 -> 30, Shaman's Ring 0 -> 15.
- Renames: Life Armor -> Bleu Dress (equippable by all, mask 0xff), Cupid's
  Lyre -> Venus' Harp, Ivory Bangle -> Myria's Key.
- Toothpick equip mask 0x08 -> 0xff.

## Skills (table 0x8019add0)

- Targeting byte: single-target 98 -> 110, all-target 3 -> 103.
- Attack spells (power/AP): Flare/Sever/Frost 15/3 -> 21/5; Inferno
  80/10 -> 84/30; Ice Blast/Stone Pillar 40/5 -> 42/15; Fireblast/Cyclone
  AP 6 -> 12; Typhoon/Blizzard/Quake AP 12 -> 25.
- Combos now cost AP: the 25/50/100-power tiers cost 10/20/40 AP, the
  4-element 100-power tier 80 AP; Mjollnir 200 power / 90 AP.
- Buffs: Might/Protect/Speed/Inspire 5 AP; Shield renamed Exalt, 15 AP;
  Barrier 50 AP.
- Heals (AP): Rejuvenate 18, Restore 36, Vitalize 30, Vigor 60, Raise
  Dead 9, Resurrect 45, Purify 1, Palliate 70, Benediction 80.
- Debuffs (SwordBreaker etc.) 5-10 AP.
- Magic Ball 250 power / 60 AP.
- Others reworked: Shadowwalk, Super Combo, Double Blow 30 AP, Triple Blow
  60, Oracle 60, the Strikes 50-70, Resist 99, Celerity 99.
- Fou-Lu's spells renamed and reworked (Jeh, Hwajeh S, AhryuP'ung S,
  Pa Bing'ah S, Patoh Pah S).
- Enemy skills changed (Syphon, Gloom, Cheering, ...).

## Level-up growth (table 0x8019bbf8)

- EXP per level unchanged.
- HP gains much higher for everyone (Fou-Lu's total L1-99 gain 3657 ->
  7657).
- Wisdom gains up for most characters.
- Cray AP total 110 -> 136; Ershin AP 205 -> 237 with less Def.
- Level-up skill lists fully rewritten. Every character learns combos and
  Fou-Lu spells. Ryu: Shield 5, Hwa 9, Cyclone 11, Magma 13, Jeh 19,
  Hwajeh 29, Supernova 33. Fou-Lu: Palliate 1, Celerity 2, Douse 3,
  Stardrop 4.

## Master bonuses (table 0x8019de28)

Masters 1-12 changed; bonuses now trade stats against each other, e.g.
master 2: HP/AP/Pwr/Def/Agl/Wis [8,0,0,0,0,0] -> [-12,2,2,-2,-1,3].

## Enemies (BWORLD records, 0x108 bytes)

175 records in the area and boss files change, 36 distinct enemies (the
demo only reaches the early game).

- HP (u32 +0x28) up about 7x (median), e.g. Mage Goo 200 -> 550, Cap
  170 -> 1100, NutTroop 120 -> 6400, Army Bat 8 -> 4250.
- Zenny (+0x10) and EXP (+0x12) mostly unchanged; bosses that paid no
  zenny now pay some.
- The u16s at +0x2c..+0x36 also change (*guess*: +0x2c AP, then attack,
  defence, agility, wisdom-type stats); bosses get large rises in the last
  one (Maman 10 -> 100, Kham 220 -> 700).
- Most of +0x40..+0x62 change on many records (*guess*: resistances /
  elemental weakness bytes) along with the trailing action bytes (+0xc0..).
- Bosses:

| Boss | Zenny | HP |
|---|---|---|
| Maman | 450 -> 1500 | 3600 -> 28500 |
| Skulfish | 291 -> 1000 | 2400 -> 19000 |
| Joh | 0 -> 2000 | 1200 -> 2600 |
| Ymechaf | 0 -> 2000 | 6000 -> 45000 |
| Kahn | 0 -> 1000 | 3000 -> 45500 |
| Kham | 0 | 15000 -> 175000 |
| Khafu | 0 | 20000 -> 500000 |
| Bilboa (AREAB036) | 80 -> 100 | 2500 -> 200000 |

## Not yet looked at

- The code appended to GAME.EMI entry 0, the BTLMOVE/BTLEND/BTLCOMD code
  changes, and the AI entries in the area/boss files.
- The 2-byte BMAGIC changes.
- In-game checks of weapon +6 / armor +5 = Wisdom and the weapon +7 nibble.
