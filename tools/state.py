"""Build the live game state (what the phone shows) from the .ksd saves.

    python tools/state.py [--saves DIR] [--world N] [--character N] [--out FILE]

Item records, as decoded from player_character and entity_chunk00:
    u8 slot, u32 item id, u16 count, u8 flags, then one field per flag bit in this order:
    0x01 u8 item level | 0x02 u32 durability, u32 max durability | 0x04 8 bytes, fill (water pouch)
    | 0x08 u32 colour palette item id (dyed armour, e.g. Icy Brook) | 0x10 u8, u8 (meaning unknown, kept
    as "tier") | 0x20 the gem socket: u32 gem item id (0 = empty), u8 (7 on a socketed Gem of Bleeding)
A container is a run of valid records whose slots increase.

A flag bit not listed here (the game added 0x08 for dyes in 2026) can't be skipped, as its size is unknown: the
record is dropped and its container cut short. That is never silent: build() returns a "warnings" list, which
the agent serves and the app shows.
"""
import argparse
import bisect
import json
import re
import pathlib
import struct
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import world as W  # noqa: E402
from ksd import Save  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
import saves as saves_mod  # noqa: E402

# the most recently used save folder on this PC (tools/saves.py); the agent lets the phone pick another
STEAM_SAVES = (saves_mod.folders() or [saves_mod.steam_dir()])[0]
FIELDS = ((0x01, 1), (0x02, 8), (0x04, 8), (0x08, 4), (0x10, 2), (0x20, 5))
KNOWN_FLAGS = 0x3F


def jsonl(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


class GameData:
    def __init__(self, export):
        self.items = {int(i["item_id"], 16): i for i in jsonl(export / "items.jsonl")}
        self.recipes = {int(r["recipe_id"], 16) for r in jsonl(export / "recipes.jsonl")}
        self.skills = {int(n["node_id"], 16): n for n in jsonl(export / "skills.jsonl")}
        # equipment slot type per item (Armour_Head, Glider, ...), for telling cosmetics from worn gear
        path = export / "item_stats.jsonl"
        self.slot = {f"{int(st['item_id'], 16):08x}": st["slot"] for st in jsonl(path)} if path.exists() else {}


# The equipment panel in order: the five cosmetic (look) slots, the five worn armour slots, then rings, shield,
# grappling hook, glider and backpack. The save lists only the filled ones, in this order, numbered without gaps
# (checked: a backup with a 4-piece Explorer look before a 5-piece worn set numbers them 0-8), so the slot byte
# alone can't tell a look from a worn piece; matching the list against the panel from the end can. Any armour
# goes in a look slot (the item stays the same), so a piece with no worn piece of its type after it counts as
# worn: a lone cosmetic helmet over no real one would read as worn, which is rare.
ARMOUR = ("Armour_Head", "Armour_UpperBody", "Armour_Arms", "Armour_LowerBody", "Armour_Feet")
PANEL = [("look", a) for a in ARMOUR] + [("worn", a) for a in ARMOUR] + \
    [("worn", s) for s in ("Armour_Ring", "Armour_Ring", "Shield", "HookShot", "Glider", "Backpack")]


def mark_cosmetics(equipment, slot_of):
    """Set "cosmetic": true on the equipment records in look slots (see PANEL)."""
    at = len(PANEL)
    for rec in reversed(equipment):
        kind = slot_of.get(rec["item"])
        k = next((k for k in range(at - 1, -1, -1) if PANEL[k][1] == kind), None)
        if k is None:
            WARNINGS.add(f"equipment in an unknown slot ({kind or rec['item']}): cosmetics may count as worn")
            for r in equipment:
                r.pop("cosmetic", None)
            return
        if PANEL[k][0] == "look":
            rec["cosmetic"] = True
        at = k


def read_record(b, o, items, allow_empty=False):
    """Item record at o, or None. Returns (record dict, next offset).

    allow_empty: accept count 0 (an emptied slot inside a typed container)."""
    if o + 8 > len(b):
        return None
    slot = b[o]
    (item_id,) = struct.unpack_from("<I", b, o + 1)
    (count,) = struct.unpack_from("<H", b, o + 5)
    flags = b[o + 7]
    if item_id not in items or flags & ~KNOWN_FLAGS:
        return None
    # a real stack never exceeds the item's stack size; this rejects placed-object headers and noise
    if not (0 if allow_empty else 1) <= count <= max(items[item_id].get("max_stack") or 1, 1):
        return None
    rec = {"slot": slot, "item": f"{item_id:08x}", "count": count}
    p = o + 8
    for bit, size in FIELDS:
        if not flags & bit:
            continue
        if p + size > len(b):
            return None
        if bit == 0x01:
            rec["level"] = b[p]
        elif bit == 0x02:
            rec["durability"] = list(struct.unpack_from("<II", b, p))
        elif bit == 0x08:
            rec["palette"] = f"{struct.unpack_from('<I', b, p)[0]:08x}"
        elif bit == 0x10:
            rec["tier"] = [b[p], b[p + 1]]
        elif bit == 0x20:
            (gem,) = struct.unpack_from("<I", b, p)
            if gem:
                rec["gem"] = f"{gem:08x}"
        p += size
    return rec, p


# what the reader met but could not read, for build()'s "warnings"; reset by build()
WARNINGS = set()


def _blocked(b, o, items, last_slot):
    """Whether a run stops at o only because of an unknown flag bit: the next record is otherwise valid."""
    if o + 8 > len(b) or b[o] <= last_slot:
        return False
    (item_id,) = struct.unpack_from("<I", b, o + 1)
    (count,) = struct.unpack_from("<H", b, o + 5)
    flags = b[o + 7]
    return (item_id in items and flags & ~KNOWN_FLAGS and
            1 <= count <= max(items[item_id].get("max_stack") or 1, 1))


def containers(b, items, start=0, end=None, empty_inside=False):
    """Runs of consecutive item records with increasing slots.

    empty_inside: a run goes on over empty stacks (count 0), which the character's bag can hold (a used-up Spark,
    say; seen in a backup, where each one split the bag into a new list); they are left out of the run."""
    end = len(b) if end is None else end
    runs, o = [], start
    while o < end:
        got = read_record(b, o, items)
        if not got:
            o += 1
            continue
        run, last_slot = [], -1
        while got and got[0]["slot"] > last_slot:
            rec, nxt = got
            if rec["count"] > 0:
                run.append((o, rec))
            last_slot, o = rec["slot"], nxt
            got = read_record(b, o, items, allow_empty=empty_inside)
        if _blocked(b, o, items, last_slot):
            (item_id,) = struct.unpack_from("<I", b, o + 1)
            WARNINGS.add(f"unknown item data (flag 0x{b[o + 7] & ~KNOWN_FLAGS:02x}) on "
                         f"{items[item_id].get('name') or f'{item_id:08x}'}: items after it may be missing")
        runs.append(run)
    return runs


def character_state(save, gd):
    pc = save.blocks["player_character"].data
    runs = [r for r in containers(pc, gd.items, empty_inside=True) if len(r) >= 1]
    # the character block holds equipment, bag and pouch, in that order. The bag numbers 40 slots; the "pouch" is
    # a second carried list of 32 (backups show it full of materials, runes and coins, or holding arrows and
    # potions), not a bait pouch; the app shows both as the bag. The key stays "pouch" for older apps.
    # stray single hits (ids in the header) come before the first real list; the header's size varies (an older
    # character's equipment starts at byte 130, a newer one's at 520), so it is skipped by content, not offset
    while runs and len(runs[0]) < 2:
        runs.pop(0)
    names = ["equipment", "bag", "pouch"]
    if len(runs) > len(names):
        WARNINGS.add(f"the character holds {len(runs)} item lists, {len(names)} expected: equipment, bag and "
                     "pouch may be mixed up")
    out = {}
    for name, run in zip(names, runs):
        out[name] = [rec for _, rec in run]
    mark_cosmetics(out.get("equipment", []), gd.slot)

    # skill list: u32 level, u32 xp, u32 count, then count x (u32 node, u8 rank). Rank 0 = listed, not bought
    # (checked: level 39, 37 points from knowledge, ranks x costs = 110, the game shows 3 free: (39 - 1) x 2 + 37 -
    # 110; level 1 gives none).
    skills, first = [], None
    for o in range(0, len(pc) - 4):
        (v,) = struct.unpack_from("<I", pc, o)
        if v in gd.skills:
            first = o if first is None else first
            if pc[o + 4] > 0:
                skills.append({"node": f"{v:08x}", "level": pc[o + 4]})
    level, xp = struct.unpack_from("<II", pc, first - 12) if first and first >= 12 else (0, 0)

    ids = ()
    if "player_knowledge" in save.blocks:  # a character saved before it learned anything has none
        know = save.blocks["player_knowledge"].data
        (n,) = struct.unpack_from("<I", know, 4)
        ids = struct.unpack_from(f"<{n}I", know, 8)
    unlocked = sorted(f"{i:08x}" for i in ids if i in gd.recipes)
    known_items = sorted(f"{i:08x}" for i in ids if i in gd.items)

    name_blk = save.blocks["character_data"].data
    (ln,) = struct.unpack_from("<I", name_blk, 5)
    return {
        "name": name_blk[9 : 9 + ln].decode("utf-8", "replace"),
        "saved_at": save.saved_at.isoformat(timespec="seconds"),
        **out,
        "level": level,
        "xp": xp,
        "skills": skills,
        "recipes_unlocked": unlocked,
        "items_known": known_items,
        "knowledge": sorted(f"{i:08x}" for i in ids),
    }


TILE = 256  # half-metres: entity groups are 128 m tiles
LOCAL = 8192  # position units per half-metre (21-bit fields: 0..256 half-metres in a tile)
_M21 = (1 << 21) - 1


def _decode_pos(tile, b8):
    v = int.from_bytes(b8, "little")
    return tuple(t * TILE + ((v >> (21 * i)) & _M21) / LOCAL for i, t in enumerate(tile))


def _in_box(p, box, slack=2):
    mn, mx = box
    return all(mn[k] - slack <= p[k] <= mx[k] + slack for k in range(3))


def entity_positions(ent, offsets, boxes):
    """World positions (half-metres) of placed objects in entity_chunk00, {header offset: (x, y, z)}.

    Decoded from a controlled test (two stacked Huge Chests with 6 and 11 Twigs, 2026-10-26):
    - entities come in groups: u8 tile x, u8 tile y, u8 tile z (128 m tiles), u32 count, then the records;
    - each record starts with its transform: 8 bytes holding three 21-bit fields x, y, z (1/8192 half-metre,
      local to the tile), then a rotation (3 bytes, or 1 for some decorations); the record header
      (0x40/0xc0 0x80 ..) follows.
    Group headers are found by pattern: a tile that meets a Flame Altar's box, a small count, and a first
    record that decodes inside a box. Each object takes the nearest header before it.
    """
    heads = []
    for p in range(0, len(ent) - 20):
        tile = (ent[p], ent[p + 1], ent[p + 2])
        (cnt,) = struct.unpack_from("<I", ent, p + 3)
        if not 0 < cnt <= (len(ent) - p) // 8:  # a record takes at least 8 bytes
            continue
        if not any(mn[0] < (tile[0] + 1) * TILE and mx[0] > tile[0] * TILE and mn[1] < (tile[1] + 1) * TILE
                   and mx[1] > tile[1] * TILE and mn[2] < (tile[2] + 1) * TILE and mx[2] > tile[2] * TILE
                   for mn, mx in boxes):
            continue
        for t in (11, 9):
            if ent[p + 7 + t] in (0x40, 0xC0, 0x60, 0x62) and ent[p + 8 + t] == 0x80 and \
                    any(_in_box(_decode_pos(tile, ent[p + 7:p + 15]), b) for b in boxes):
                heads.append((p, tile))
                break
    out = {}
    starts = [h[0] for h in heads]
    for o in offsets:
        k = bisect.bisect_right(starts, o - 16) - 1
        if k < 0:
            continue
        tile = heads[k][1]
        best = None
        for t in (11, 9):
            pos = _decode_pos(tile, ent[o - t:o - t + 8])
            if any(_in_box(pos, b) for b in boxes):
                best = pos
                break
        out[o] = best
    return out


def placed_objects(ent, gd):
    """Placed objects in entity_chunk00: u8 lead (0x40/0xc0/...), 0x80, u16, 0x01, u32 item type.

    Containers (chests, racks, feeders, mannequins) continue with u8 size class, u8 record count
    and that many item records. Their position is in the bytes that follow and is not decoded yet.
    Returns ({item type: count}, [containers], {offsets of the records they own}).
    """
    placed, conts, covered = {}, [], set()
    headers = set()
    for m in re.finditer(rb"[\x40\xc0\x60\x62]\x80..\x01", ent, re.S):
        o = m.start()
        if o + 11 > len(ent):
            continue
        (kind,) = struct.unpack_from("<I", ent, o + 5)
        if kind not in gd.items:
            continue
        key = f"{kind:08x}"
        placed[key] = placed.get(key, 0) + 1
        headers.add(o + 4)  # the "0x01 + item type" bytes look like an item record in slot 1
        p, size_class, count = o + 11, ent[o + 9], ent[o + 10]
        recs = []
        for _ in range(count):
            got = read_record(ent, p, gd.items, allow_empty=True)
            if not got:
                break
            covered.add(p)
            recs.append(got[0])
            p = got[1]
        if count and len(recs) == count:
            conts.append({"offset": o, "kind": key, "size_class": size_class,
                          "items": [r for r in recs if r["count"] > 0]})
    return placed, conts, covered | headers


def snapped_pieces(save):
    """Building pieces from the `snapping` block, absolute in half-metres.

    Layout: "SBV2", u16 version, then sections of (u16 cell x, u16 cell z, u32 count) and count x 20-byte
    pieces: u32 shape, u32 material, u16 y, u8 x, u8 z (local in the 64 m cell, so world x = cell x * 128 + x),
    u8 size x, size y, size z (half-metres: 8,1,8 is a 4 x 0.5 x 4 m floor), u8 rotation, 4 more bytes.
    Checked: every section lands inside a Flame Altar's build box.
    """
    blk = save.blocks.get("snapping")
    if not blk or blk.data[:4] != b"SBV2":
        return []
    b, o, out = blk.data, 6, []
    while o + 8 <= len(b):
        cx, cz, n = struct.unpack_from("<HHI", b, o)
        o += 8
        if o + 20 * n > len(b):
            break
        for i in range(n):
            r = b[o + 20 * i: o + 20 * i + 20]
            (y,) = struct.unpack_from("<H", r, 8)
            out.append({
                "x": cx * 128 + r[10], "y": y, "z": cz * 128 + r[11],
                "s": [r[12], r[13], r[14]], "r": r[15],
                "shape": r[0:4][::-1].hex(), "mat": r[4:8][::-1].hex(),
            })
        o += 20 * n
    return out


def world_state(save, gd):
    names = save.custom_strings()
    # placed objects, chests and stations: entity_chunk00 (and any further chunks, read as one)
    chunks = sorted(k for k in save.blocks if re.fullmatch(r"entity_chunk\d+", k))
    ent = b"".join(save.blocks[k].data for k in chunks)
    bases = []
    # one block per Flame Altar: base00, base01, ... (as many as the Flame allows: 11 at strength 6, 16 at most)
    ids = sorted((int(k[4:]) for k in save.blocks if re.fullmatch(r"base\d+", k)))
    for i in ids:
        blk = save.blocks[f"base{i:02d}"]
        data = blk.data
        guid = data[:16]
        mn = struct.unpack_from("<3I", data, 16)
        mx = struct.unpack_from("<3I", data, 28)
        at = ent.find(guid)
        level = ent[at + 16] if at >= 0 else None
        key = ent[at + 17 : at + 25].hex() if at >= 0 else ""
        center = [(a + b) / 2 for a, b in zip(mn, mx)]
        bases.append({
            "id": f"base{i:02d}",
            "name": names.get(key),
            "altar_level": level,
            "min": list(mn),
            "max": list(mx),
            # map pixel of the centre (tools/world.py; Z grows north)
            "map": [round(v) for v in W.map_from_half(center[0], center[2])],
        })

    # building pieces, each given to the base whose build box holds it, relative to the box's corner:
    # [x, y, z, size x, size y, size z, rotation, material item id, shape item id] (half-metres = voxels)
    for piece in snapped_pieces(save):
        for base in bases:
            mn, mx = base["min"], base["max"]
            if all(mn[k] - 2 <= v <= mx[k] + 2 for k, v in enumerate((piece["x"], piece["y"], piece["z"]))):
                base.setdefault("pieces", []).append([
                    piece["x"] - mn[0], piece["y"] - mn[1], piece["z"] - mn[2], *piece["s"], piece["r"],
                    piece["mat"], piece["shape"],
                ])
                break

    placed, conts, covered = placed_objects(ent, gd)
    # item runs outside placed objects: animal produce, crops and the like
    for run in containers(ent, gd.items):
        run = [(o, rec) for o, rec in run if o not in covered]
        if not run:
            continue
        conts.append({"offset": run[0][0], "kind": None, "items": [rec for _, rec in run]})
    conts.sort(key=lambda c: c["offset"])
    # which base each chest, rack and station is in, from its decoded position
    boxes = [(b["min"], b["max"]) for b in bases]
    heads = [m.start() for m in re.finditer(rb"[\x40\xc0\x60\x62]\x80..\x01", ent, re.S)]
    pos = entity_positions(ent, heads, boxes)

    def base_of(p):
        if p is None:
            return None
        for b in bases:
            if _in_box(p, (b["min"], b["max"])):
                return b["id"]
        return None

    for c in conts:
        p = pos.get(c["offset"])
        if p is not None:
            c["pos"] = [round(v, 1) for v in p]
            c["base"] = base_of(p)
    by_base = {}
    for o in heads:
        (kind,) = struct.unpack_from("<I", ent, o + 5)
        bid = base_of(pos.get(o))
        if bid and kind in gd.items:
            key = f"{kind:08x}"
            by_base.setdefault(bid, {})[key] = by_base.setdefault(bid, {}).get(key, 0) + 1
    for b in bases:
        b["placed"] = by_base.get(b["id"], {})
    wk = save.blocks["world_knowledge"].data
    (wn,) = struct.unpack_from("<I", wk, 4)
    knowledge = sorted(f"{i:08x}" for i in struct.unpack_from(f"<{wn}I", wk, 8))
    # world settings (keen.ecs.GameSettings, packed): factors chosen when the world was created. A world from an
    # early game version (or never past its first minutes) has no game_settings and no logic block: the
    # defaults then, factor 1 (the app's fallback)
    settings = {}
    if "game_settings" in save.blocks:
        gs = save.blocks["game_settings"].data
        settings = {
            "health": struct.unpack_from("<f", gs, 0)[0],
            "mana": struct.unpack_from("<f", gs, 4)[0],
            "stamina": struct.unpack_from("<f", gs, 8)[0],
            "body_heat": struct.unpack_from("<f", gs, 12)[0],
            "diving_time": struct.unpack_from("<f", gs, 16)[0],
            "food_buff_duration": struct.unpack_from("<f", gs, 22)[0],
            "shroud_time": struct.unpack_from("<f", gs, 34)[0],
        }
        settings = {k: round(v, 3) for k, v in settings.items()}
    # Flame strength: u32 at 20 in the miscellaneous block. Checked on the game's backups: 1 in a new world,
    # then 6, then 8 as the Flame was raised (3 in an older world). The logic block's 6 is not it: it stays
    # 6 from a new world on. Without the block, a new world: strength 1, the game's "not upgraded"
    misc = save.blocks.get("miscellaneous")
    flame_level = struct.unpack_from("<I", misc.data, 20)[0] if misc and len(misc.data) >= 24 else 1
    meta = save.blocks["world_metadata"].data
    (ln,) = struct.unpack_from("<I", meta, 0x39)
    return {
        "name": meta[0x3D : 0x3D + ln].decode("utf-8", "replace"),
        "placed": placed,
        "settings": settings,
        "flame_level": flame_level,
        "knowledge": knowledge,
        "saved_at": save.saved_at.isoformat(timespec="seconds"),
        "bases": bases,
        "containers": conts,
    }


GUEST = -1  # the world number for a guest in a friend's world


def guest_world(flame):
    """A guest in a friend's world: that world's save is on the host's PC, so no chests, bases or world
    progress; the host's Flame strength, as the player gave it, for Shroud time and access."""
    return {"name": "", "guest": True, "placed": {}, "settings": {}, "flame_level": int(flame), "knowledge": [],
            "saved_at": None, "bases": [], "containers": []}


def build(saves, world, character, export, guest_flame=1):
    gd = GameData(export)
    WARNINGS.clear()
    out = {
        "version": 1,
        "built_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "character": character_state(Save(saves / f"character{character}.ksd"), gd),
        "world": guest_world(guest_flame) if world == GUEST else world_state(Save(saves / f"world{world}.ksd"), gd),
    }
    out["warnings"] = sorted(WARNINGS)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--saves", type=pathlib.Path, default=STEAM_SAVES)
    ap.add_argument("--world", type=int, default=1)
    ap.add_argument("--character", type=int, default=1)
    ap.add_argument("--export", type=pathlib.Path, default=ROOT / "data" / "export")
    ap.add_argument("--out", type=pathlib.Path)
    a = ap.parse_args()
    state = build(a.saves, a.world, a.character, a.export)
    text = json.dumps(state, ensure_ascii=False, indent=1)
    if a.out:
        a.out.write_text(text, encoding="utf-8")
    c, w = state["character"], state["world"]
    print(f"{c['name']}: {len(c.get('equipment', []))} equipped, {len(c.get('bag', []))} in bag, "
          f"{len(c.get('pouch', []))} in pouch, {len(c['skills'])} skills, {len(c['recipes_unlocked'])} recipes")
    print(f"{w['name']}: {len(w['bases'])} bases, {len(w['containers'])} containers, "
          f"{sum(len(x['items']) for x in w['containers'])} stacks")


if __name__ == "__main__":
    main()
