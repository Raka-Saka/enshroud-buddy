"""Build the app's offline game database from the EML export.

    python tools/build_db.py [--export data/export] [--out app/assets/game.json]

Input is the jsonl written by tools/eml-export (see docs/SCOPE.md). Output is one compact JSON
file the app loads at startup. Markup tags (<npc>, <b>, ...) are stripped; nested arrays that the
Lua exporter wrote as JSON strings are decoded.
"""
import argparse
import json
import math
import pathlib
import re
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import world as W  # noqa: E402

# cells for gather spots and regions: the game's 128 m entity tiles (gather.tsv counts per tile), so GRID x GRID
# of them across the world (80 in this version), CELL_PX map pixels each
CELL_M = 128
GRID = int(W.SIZE_M // CELL_M)
CELL_PX = CELL_M / W.M_PER_PX


def mp(x, z):
    """Map pixel of a save position (half-metres), rounded for game.json."""
    return [round(v, 1) for v in W.map_from_half(x, z)]
TAG = re.compile(r"</?[a-zA-Z_]+[^>]*>")
SKIP_CATEGORIES = {"Customization", "ColorPalette"}


def clean(s):
    if not s:
        return None
    s = TAG.sub("", s).replace("\r", "").strip()
    return s or None


def deep(v):
    if isinstance(v, str) and v[:1] in "{[":
        try:
            return deep(json.loads(v))
        except ValueError:
            return v
    if isinstance(v, list):
        return [deep(x) for x in v]
    if isinstance(v, dict):
        return {k: deep(x) for k, x in v.items()}
    return v


def read(export, name):
    path = export / name
    return [deep(json.loads(line)) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def split_stack(s):
    *ref, count = s.split(":")
    return [":".join(ref), int(count)]


ARTISANS = {"huntress": "Hunter", "hunter": "Hunter", "carpenter": "Carpenter", "farmer": "Farmer",
            "alchemist": "Alchemist", "blacksmith": "Blacksmith", "bard": "Bard", "barber": "Barber",
            "collector": "Collector", "cryptkeeper": "Collector", "researcher": "Researcher"}


def humanize(name):
    if not name:
        return "Hidden condition"
    if name.lower() in ARTISANS:
        return f"Rescue the {ARTISANS[name.lower()]}"
    words = re.sub(r"([a-z])([A-Z])", r"\1 \2", name).replace("_", " ").split()
    words = [w for w in words if w.lower() not in {"wk", "knowledge", "pickup"}]
    return " ".join(words).capitalize() or name


class Unlocks:
    """Turns a recipe's knowledge query into a tree the app can check against the save.

    Node: {"op": "AND"|"OR", "c": [nodes]} or a leaf {"t": text, "k": knowledge id, "i": item id}.
    A leaf with "k" is met when that id is in the player's or the world's knowledge.
    An artisan leaf has "n": the artisan's item id, which the world's knowledge holds once they are rescued
    (all seven in the test save), and "pl": item ids of stations placed for them; "sh" marks "sheltered",
    which the save can't tell: the app takes one of their stations placed in the world as them living in a
    base.
    """

    def __init__(self, export, items, workshops, recipe_outputs, raw_recipes=()):
        self.q = {q["query_id"]: q for q in read(export, "knowledge_queries.jsonl")}
        self.items, self.workshops, self.recipe_outputs = items, workshops, recipe_outputs
        # the game names its artisans' ids only in the actions that ask about them ("NPC_Alchemist_Placed",
        # "NPC_cryptKeeper_Placed", "blacksmith"): an id takes the artisan its action names say
        by_name = {w["n"]: wid for wid, w in workshops.items() if w.get("k") == "npc"}
        votes = {}
        for q in self.q.values():
            for a in q.get("actions", []):
                t = self.q.get(a.get("ref"))
                if not t or t.get("type") != "Npc":
                    continue
                low = (a.get("name") or "").lower()
                for token, name in ARTISANS.items():
                    if token in low and name in by_name:
                        votes.setdefault(t["npc_id"], {}).setdefault(by_name[name], 0)
                        votes[t["npc_id"]][by_name[name]] += 1
        self.npc = {nid: max(v, key=v.get) for nid, v in votes.items()}
        # the name alone for artisans without a workshop (the Bard)
        self.npc_names = {}
        for q in self.q.values():
            for a in q.get("actions", []):
                t = self.q.get(a.get("ref"))
                if t and t.get("type") == "Npc" and t["npc_id"] not in self.npc_names:
                    low = (a.get("name") or "").lower()
                    name = next((n for token, n in ARTISANS.items() if token in low), None)
                    if name:
                        self.npc_names[t["npc_id"]] = name
        # each artisan's stations: the props their recipes need, and those quests ask to be placed for them
        self.stations = {}
        for r in raw_recipes:
            if workshops.get(r["workshop_id"], {}).get("k") == "npc":
                self.stations.setdefault(r["workshop_id"], set()).update(r.get("required_props", []))
        for q in self.q.values():
            if q.get("type") == "Npc" and q.get("npc_action") == "CraftingPropPlaced" and q.get("npc_id") in self.npc:
                self.stations.setdefault(self.npc[q["npc_id"]], set()).add(q.get("prop"))

    def _station_items(self, props):
        return sorted({self.workshops[p]["it"] for p in props if self.workshops.get(p, {}).get("it")})

    def item_name(self, i):
        return self.items.get(i, {}).get("n", "an item")

    def runtime(self, q):
        t, v = q["type"], q.get("value", 0)
        ws = self.npc.get(q.get("npc_id"))
        npc = self.workshops.get(ws, {}).get("n") or self.npc_names.get(q.get("npc_id"), "artisan")
        who = {"n": self.workshops[ws]["it"]} if self.workshops.get(ws, {}).get("it") else {}
        if t == "Inventory":
            return {"t": f"Carry {self.item_name(q['item_id'])}", "i": q["item_id"]}
        if t == "InventoryCounter":
            return {"t": f"Carry {v} × {self.item_name(q['item_id'])}", "i": q["item_id"]}
        if t == "Npc":
            act = q.get("npc_action")
            if act == "CraftingPropPlaced":
                prop = self.workshops.get(q.get("prop"), {}).get("n", "an upgrade")
                placed = self._station_items([q.get("prop")])
                return {"t": f"Place {prop} for the {npc}", **who, **({"pl": placed} if placed else {})}
            if act == "IsSheltered":
                placed = self._station_items(self.stations.get(ws, ()))
                return {"t": f"Give the {npc} a shelter", **who, "sh": 1, **({"pl": placed} if placed else {})}
            return {"t": f"Rescue the {npc}", **who}
        # number conditions keep their operator: "MotherFlameLevel > 5" means strength 6 or more, and
        # "< 8" closes a window (a recipe for Flame 6-7 that a stronger version replaces at 8)
        op = {"GreaterThan": ">", "LessThan": "<", "Equals": "="}.get(q.get("op"), ">")
        words = {  # kind, then text for >, <, =
            "MotherFlameLevel": ("flame", "Raise the Flame to strength {n}", "Flame strength below {v}", "Flame strength exactly {v}"),
            "PlayerLevel": ("level", "Reach player level {n}", "Player level below {v}", "Player level exactly {v}"),
            "FlameAltarLevel": ("altar", "Upgrade a Flame Altar to level {n}", "Altar level below {v}", "Altar level exactly {v}"),
            "FlameAltarCount": ("altars", "Build {n} Flame Altars", "Fewer than {v} Flame Altars", "Exactly {v} Flame Altars"),
        }
        if t in words:
            kind, more, less, equal = words[t]
            text = {">": more, "<": less, "=": equal}[op].format(n=v + 1, v=v)
            return {"t": text, "rt": [kind, op, v]}
        return {"t": humanize(q.get("name"))}

    def flag(self, ref, kind):
        """A completion or discovery condition: a plain knowledge flag, or a query tree."""
        if not ref or ref == "00000000":
            return None
        if kind == "Extern":
            return self.query(ref)
        return {"t": "", "k": ref}

    def query(self, qid, depth=0):
        q = self.q.get(qid)
        if not q or depth > 4:
            return None
        if q.get("runtime") == "true" or q["type"] not in ("AND", "OR", "XOR"):
            return self.runtime(q)
        kids = []
        for a in q["actions"]:
            node = self.action(a, depth)
            if node and node not in kids:
                kids.append(node)
        if not kids:
            return None
        return kids[0] if len(kids) == 1 else {"op": "OR" if q["type"] == "OR" else "AND", "c": kids}

    def action(self, a, depth):
        ref = a["ref"]
        if a["type"] == "Knowledge":
            if ref in self.items:
                return {"t": f"Pick up {self.item_name(ref)}", "k": ref, "i": ref}
            if ref in self.recipe_outputs:
                out = self.recipe_outputs[ref]
                return {"t": f"Craft {self.item_name(out)}", "k": ref, "i": out}
            return {"t": humanize(a["name"]), "k": ref}
        return self.query(ref, depth + 1) or ({"t": humanize(a["name"])} if a["name"] else None)


def stat_values(values):
    """'Duration=2700000', 'Shroud Resistance=5%' -> [['Duration', '45 min'], ['Shroud Resistance', '5%']]."""
    out = []
    for v in values:
        label, _, raw = v.rpartition("=")
        pct = raw.endswith("%")
        num = raw.rstrip("%").split("*")[0]
        try:
            n = int(num)
        except ValueError:
            continue
        if re.fullmatch(r"[0-9a-f]{8}", label) or n == 0:
            continue
        if ("Duration" in label or "Time" in label or "Oxygen" in label) and abs(n) >= 1000 and not pct:
            secs = abs(n) / 1000
            text = ("-" if n < 0 else "") + (f"{secs / 60:.0f} min" if secs >= 60 else f"{secs:.0f} s")
        else:
            text = f"{n}%" if pct else str(n)
        out.append([label, text])
    return out


WEAPON_TYPES = [  # (debug-name pattern, any case, weapon type); class follows from WEAPON_CLASS
    # the export has no weapon type field (collection categories are only hashes), so the debug name tells;
    # build_db warns about any weapon left without a type
    (r"Grenade|Throwable|Torch|Fists|Toy|Buoyancy|Water_|Critter", "Utility"),
    (r"Bow", "Bow"), (r"Staff", "Staff"), (r"Wand", "Wand"), (r"Dagger", "Dagger"), (r"Shield", "Shield"),
    (r"GreatSword|Greatsword|2H_Sword", "Greatsword"), (r"GreatAxe|2H_Axe", "Two-handed axe"), (r"Hammer", "Hammer"),
    (r"Sword", "Sword"), (r"Axe", "Axe"), (r"Mace|Club", "Mace"),
]
WEAPON_CLASS = {"Bow": "Ranger", "Dagger": "Ranger", "Staff": "Mage", "Wand": "Mage", "Shield": "Warrior",
                "Greatsword": "Warrior", "Two-handed axe": "Warrior", "Hammer": "Warrior", "Sword": "Warrior",
                "Axe": "Warrior", "Mace": "Warrior"}


def weapon_type(debug_name, slot):
    if slot == "Shield":  # wards too: the slot says what it is, the item's alignment whose it is
        return "Shield"
    if slot not in ("MeleeWeapon", "MidRangeWeapon", "RangeWeapon"):
        return None
    for pat, wt in WEAPON_TYPES:
        if re.search(pat, debug_name, re.I):
            return wt
    print(f"WARNING: no weapon type for {debug_name} (add a pattern to WEAPON_TYPES)")
    return None


def item_stats(export):
    out = {}
    path = export / "item_stats.jsonl"
    if not path.exists():
        return out
    for st in read(export, "item_stats.jsonl"):
        row = {}
        if st["slot"] not in ("Invalid", "None"):
            row["sl"] = st["slot"]
        if st["max_level"]:
            row["lv"] = [st["min_level"], st["max_level"]]
        values = stat_values(st["values"]) + stat_values(st["buffs"])
        if values:
            row["v"] = values
        perks = {}
        for name in st["perks"]:
            if name and name != "None":
                perks[name] = perks.get(name, 0) + 1
        if perks:
            row["pk"] = [f"{k} ×{n}" if n > 1 else k for k, n in perks.items()]
        if st["armor"]:
            row["ar"] = st["armor"]
        if st["damage"]:
            row["dm"] = [d.replace("Damage", "") for d in st["damage"]]
        if st["comfort"]:
            row["cf"] = st["comfort"]
        if st.get("alignment") not in (None, "None", "Neutral"):
            row["al"] = st["alignment"]
        if row:
            out[st["item_id"]] = row
    return out


POI_RULES = [  # (substring of the lower-cased template name or label, category)
    ("teleport_platform_savepoint", "Save Point"), ("prop_tower_beacon", "Return Beacon"), ("dungeon_beacon", "Return Beacon"), ("mapmarker_tower", "Ancient Spire"), ("flameshrine", "Flame Shrine"), ("ancient spire", "Ancient Spire"), ("elixirwell", "Elixir Well"),
    ("fast travel", "Fast Travel"), ("gemforge", "Gem Forge"), ("boss", "Boss"),
    ("enemycamp", "Enemy Camp"), ("_camp_", "Enemy Camp"), ("outpost", "Enemy Camp"),
    ("dungeon", "Dungeon"), ("temple", "Dungeon"), ("crypt", "Dungeon"), ("catacomb", "Dungeon"), ("hiddengrave", "Dungeon"),
    ("fogwellplant", "Shroud Root"), ("fognest", "Shroud Lair"), ("mine", "Mine"), ("traversalcave", "Cave"),
    ("town", "Place"), ("farm", "Place"), ("village", "Place"), ("building", "Place"), ("ruin", "Place"),
    ("tower", "Place"), ("platform", "Place"), ("talltree", "Place"), ("obelisk", "Place"), ("island", "Place"),
]
POI_HIDDEN = ("noui", "searcharea", "placeholder", "hint", "areaname", "_old", "maplabel_general_tower", "triggerzone")
POI_UNNAMED_OK = {"Save Point", "Return Beacon", "Elixir Well", "Flame Shrine", "Gem Forge", "Shroud Root", "Shroud Lair", "Mine", "Cave", "Boss", "Dungeon"}


def poi_category(name, label):
    low = f"{name} {label}".lower()
    if any(h in low for h in POI_HIDDEN):
        return None
    for key, cat in POI_RULES:
        if key in low:
            return cat
    return "Other"


RARITIES = ["Common", "Uncommon", "Rare", "Epic", "Legendary"]


def chest_name(template):
    """LootChest_Random_HollowHall_Sarcophagus_gold_Armor_Warrior_T5 -> 'Gold sarcophagus · Armor · Warrior · T5'."""
    low = template.lower()
    tier = next((t for t in ("gold", "silver", "shell", "wood") if t in low), "")
    base = "sarcophagus" if "sarcophagus" in low else "cairn" if "cairn" in low else "chest"
    parts = [f"{tier.capitalize()} {base}".strip().capitalize() if tier else base.capitalize()]
    for key, label in (("armor", "Armor"), ("weapon", "Weapons"), ("warrior", "Warrior"), ("ranger", "Ranger"),
                       ("mage", "Mage"), ("bow", "Bow"), ("locked", "Locked")):
        if key in low:
            parts.append(label)
    m = re.search(r"_T(\d)(?:-T(\d))?", template)
    if m:
        parts.append(f"T{m.group(1)}" + (f"–T{m.group(2)}" if m.group(2) else ""))
    return " · ".join(parts)


class Loot:
    """Chest loot: rarity odds and item pool per loot setting, and which chests can drop an item."""

    def __init__(self, export, items):
        self.ok = (export / "loot_settings.jsonl").exists()
        if not self.ok:
            return
        self.items = items
        self.containers = {c["template"]: c for c in read(export, "loot_containers.jsonl")}
        lootable = {i["item_id"]: i for i in read(export, "loot_items.jsonl")}
        members = {}
        for iid, li in lootable.items():
            if iid in items:
                for label in li["labels"]:
                    members.setdefault(label.split(":")[0], set()).add(iid)
        self.settings = {}
        for s in read(export, "loot_settings.jsonl"):
            odds = [float(x.split("=")[1]) for x in s["modifier"].split("rarities ")[1].split(",")]
            pools = [t.split(":")[0] for t in s["tags"] if t.split(":")[1] == "1"]
            pool = set().union(*(members.get(t, set()) for t in pools)) if pools else set()
            self.settings[s["id"]] = {"o": odds, "pool": pool}
        self.special = read(export, "loot_special.jsonl")

    def setting_for(self, template):
        c = self.containers.get(template)
        return c["labels"] if c and c["labels"] in self.settings else None

    def summary(self):
        """{setting id: {o: odds %, n: pool size, ex: example item ids}} for the settings chests use."""
        out = {}
        for sid, s in self.settings.items():
            if not s["pool"]:
                continue
            top = max(range(5), key=lambda r: s["o"][r])
            pool = sorted(s["pool"], key=lambda i: (RARITIES.index(self.items[i]["r"]) if self.items[i]["r"] in RARITIES else 0, self.items[i]["n"]), reverse=True)
            ex = [i for i in pool if self.items[i]["r"] == RARITIES[top]][:10] or pool[:10]
            cats = {}
            for i in s["pool"]:
                cats[self.items[i]["c"]] = cats.get(self.items[i]["c"], 0) + 1
            out[sid] = {"o": [round(x, 1) for x in s["o"]], "n": len(s["pool"]), "c": cats, "ex": ex, "pool": pool}
        return out

    def drops(self, chest_kinds):
        """item id -> sorted chest kinds that can roll it (pool member, and its rarity has odds > 0)."""
        out = {}
        for kind, sids in chest_kinds.items():
            for sid in sids:
                s = self.settings[sid]
                for iid in s["pool"]:
                    r = self.items[iid]["r"]
                    if r in RARITIES and s["o"][RARITIES.index(r)] > 0:
                        out.setdefault(iid, set()).add(kind)
        return {k: sorted(v) for k, v in out.items()}


def more_of(s):
    """The 11th poi.tsv column, key=value;... (tools/eml-poi)."""
    return dict(kv.split("=", 1) for kv in s.split(";") if "=" in kv)


def fishing_kind(template):
    """_FishingLocation_Generic_FewFish_Treasure_and_Trash -> Few fish, treasure and trash."""
    words = re.sub(r"([a-z])([A-Z])", r"\1 \2", template.split("Generic_", 1)[-1]).replace("_", " ").lower()
    return words.replace("few fish ", "few fish, ").capitalize()


def own_level(more, levels):
    """(base, offset) of the entity's own level (tools/eml-poi spawn_info "lv=15" or "lv=3+7"), or the chunk's
    highest level with no offset when the entity has none."""
    lv = more_of(more).get("lv")
    if lv:
        base, _, off = lv.partition("+")
        return int(base), int(off or 0)
    return max((int(v) for v in levels.split(",") if v.strip().isdigit()), default=0), 0


UPDRAFT_SIZES = ("Small", "Medium", "Big")


def points(export, unlocks, lore_pages, loot=None, halls=None):
    """Map points from data/export/poi.tsv on the 1280 px fog-map grid. Points inside the Hollow Halls (the
    box [x0, y0, x1, y1] from hall_layout) get "in": 1 and their height "h" in metres."""
    path = export / "poi.tsv"
    out, plants = [], []
    if not path.exists():
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        cat, name, label, extra, x, y, z, visible, completed, levels, more = (line.split("\t") + [""] * 11)[:11]
        x, y, z = float(x), float(y), float(z)
        if x < 600 and z > 19500:  # developer test area in the far corner
            continue
        mx, my = mp(x, z)
        base, off = own_level(more, levels)
        # half-metre position, and the level offset the Hollow Halls' insides are told apart by (assign_halls).
        # h: height in metres. The map alone can't tell a cave or an island from the ground: Cinder's Cradle's
        # chests stand from 710 to 2,419 m, and many chests elsewhere lie in caves and cellars.
        p = {"x": mx, "y": my, "h": round(y / 2), "_hx": x, "_hz": z, "_off": off}
        if halls and halls[0] <= mx <= halls[2] and halls[1] <= my <= halls[3]:
            p["in"] = 1
        if cat == "fishing":
            p.update(c="fish", k=fishing_kind(name), t="Fishing spot", ft=more_of(more).get("fish", "")[:8])
            if base + off:
                p["lv"] = base + off
            out.append(p)
            continue
        if cat == "updraft":
            size = next((w for w in UPDRAFT_SIZES if w in name), "Big" if "Big" in name else "")
            p.update(c="updraft", k=f"{size} updraft".strip().capitalize(), t="Updraft")
            out.append(p)
            continue
        if cat == "trigger":
            if "SkillPointPlant" in name:
                plants.append((x, z, extra.split(",")[0]))
            continue
        if cat == "label":
            kind = poi_category(name, label)
            title = clean(label) or (kind if kind in POI_UNNAMED_OK else None)
            if kind is None or not title:
                continue
            if kind == "Ancient Spire" and "Spire" not in title:
                title = f"Ancient Spire — {title}"
            p.update(c="label", k=kind, t=title)
            if kind == "Dungeon" and base + off:
                p["lv"] = base + off  # a dungeon's own level (the Hollow Halls' are 10 to 45)
                p["_tpl"] = name
            if completed:
                tree = unlocks.flag(completed.split(":")[1], completed.split(":")[0])
                if tree:
                    p["d"] = tree
        elif cat == "lore":
            title = clean(label)
            if not title:
                continue
            p.update(c="lore", t=title)
            if title in lore_pages:
                p["l"] = lore_pages[title]
        elif cat in ("capsule", "air"):
            p.update(c="shroud" if cat == "capsule" else "water", t=clean(label) or cat)
        elif cat == "chest":
            tier = next((t for t in ("gold", "silver", "shell", "sarcophagus", "wood") if t in name.lower()), "other")
            p.update(c="chest", k=tier.capitalize(), t=chest_name(name))
            sid = loot.setting_for(name) if loot and loot.ok else None
            if sid:
                p["ls"] = sid
            if base + off:
                p["lv"] = base + off  # the chest's own level (else its chunk's highest); 0 = scales with you
        else:
            continue
        out.append(p)
    attach_roots(out, plants)
    if loot and loot.ok:
        attach_special(out, loot)
    for p in out:
        p.pop("_hx", None)
        p.pop("_hz", None)
    return out


def fish_tables(export, used, items):
    """{table key: {"tr": trash %, "bt": boot %, "f": [[item id, % of fish, "Day"/"Night"/""], ...]}} for the
    tables the fishing spots use (data/export/fish_tables.tsv, keyed by the first 8 hex of the guid)."""
    path = export / "fish_tables.tsv"
    out = {}
    if not path.exists():
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        guid, trash_ok, trash, fish, shoes = (line.split("\t") + [""] * 5)[:5]
        if guid[:8] not in used:
            continue
        rows = [e.split(":") for e in fish.split(",") if e.count(":") == 2]
        rows = [(i, float(w), t) for i, w, t in rows if i in items]
        total = sum(w for _, w, _ in rows) or 1
        boot = sum(float(e.split(":")[1]) for e in shoes.split(",") if e.count(":") == 2)
        out[guid[:8]] = {
            "tr": round(100 * float(trash), 1) if trash_ok == "true" else 0,
            "bt": round(100 * boot, 1),
            "f": [[i, round(100 * w / total, 1), {"DayTime": "Day", "NightTime": "Night"}.get(t, "")]
                  for i, w, t in sorted(rows, key=lambda r: -r[1])],
        }
    return out


def hall_layout(export):
    """The Hollow Halls' insides, which the game keeps in the world's far north-west corner (tools/eml-poi
    inside.tsv): every placed object but plants and loose loot, as {"b": [x0, y0, x1, y1] (map px, the box
    around them), "p": [x, y, h, ...]} with x, y in tenths of a map pixel and h in metres, one point per
    2 m square and 4 m of height (assign_halls adds each point's hall). The app draws them as the halls'
    layout and dims other floors."""
    path = export / "inside.tsv"
    if not path.exists():
        return None
    seen, pts, rows = set(), [], []
    for line in path.read_text(encoding="utf-8").splitlines():
        name, x, y, z = (line.split("\t") + [""] * 4)[:4]
        if "Scatter" in name or not z:
            continue
        x, y, z = float(x), float(y), float(z)
        if x < 600 and z > 19500:  # developer test area
            continue
        key = (int(x // 4), int(z // 4), int(y // 8))
        rows.append((name, key))
        if key in seen:
            continue
        seen.add(key)
        mx, my = W.map_from_half(x, z)
        pts.append((round(mx * 10), round(my * 10), round(y / 2), key))
    if not pts:
        return None
    pts.sort()
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    # "_k" (each point's square) and "_rows" (every object and its square) are for hall_brief, then dropped
    return {"b": [min(xs) / 10, min(ys) / 10, max(xs) / 10, max(ys) / 10], "p": [v for p in pts for v in p[:3]],
            "_k": [p[3] for p in pts], "_rows": rows}


def _spawn(t):
    """An enemy spawn point, not a bone pile that keeps raising them (those are "raisers")."""
    return t.startswith("spawnpoint") and "respawner" not in t and "destructible" not in t


# What a Hollow Hall holds, told by the names of the objects placed in it (lower case): enemies by kind, the
# bone piles that raise more until broken, grapple points, climbing walls, rune barriers (some needing the
# glider) and traps. The app turns these into its "before you go" check.
HALL_CONTENT = (
    ("fell", lambda t: _spawn(t) and ("fogger" in t or "_fog_" in t)),
    ("beasts", lambda t: _spawn(t) and "wildbeast" in t and "_fog_" not in t),
    ("hollow", lambda t: _spawn(t) and "wildbeast" not in t and "fogger" not in t),
    ("elite", lambda t: _spawn(t) and any(w in t for w in ("elite", "heavy", "necromancer", "hero"))),
    ("raisers", lambda t: "bonepile" in t and ("respawner" in t or "destructible" in t)),
    ("hook", lambda t: t.startswith("hookshot_target")),
    ("climb", lambda t: t.startswith("climbingwall")),
    ("doors", lambda t: t.startswith("logic_magicbarrier")),
    ("glide", lambda t: t.startswith("logic_magicbarrier") and t.endswith("_glider")),
    ("fire", lambda t: t.startswith("trap_") and "magma" in t),
    ("shock", lambda t: t.startswith("trap_") and "electro" in t),
    ("traps", lambda t: t.startswith("trap_")),
)


def hall_brief(rows, hall_of, n):
    """Per hall, how many of each HALL_CONTENT kind: [{"hollow": 210, "hook": 14, ...}, ...] (zeros left out)."""
    out = [{} for _ in range(n)]
    for name, key in rows:
        k = hall_of.get(key, -1)
        if k < 0:
            continue
        t = name.lower()
        for kind, test in HALL_CONTENT:
            if test(t):
                out[k][kind] = out[k].get(kind, 0) + 1
    return out


# The wiki's names for damage types (NPC infobox rows) and the game's (items' "dm")
WIKI_DAMAGE = {"Cutting": "physicalCut", "Piercing": "physicalPierce", "Blunt": "physicalBlunt", "Poison": "poison",
               "Fire": "magicalFire", "Ice": "magicalIce", "Shroud": "magicalFog", "Shock": "magicalLightning"}


def faction_damage(faction):
    """What a faction's enemies take more and less from, by the wiki copy the Ask workspace keeps
    (agent/ask/wiki, NPC infoboxes): {"weak": [...], "strong": [...], "from": [names]} in the game's damage
    names. A type counts only when every enemy that lists it agrees (Effective; Resisted or Immune)."""
    wiki = ROOT / "agent" / "ask" / "wiki"
    if not wiki.is_dir():
        return None
    votes, names = {}, []
    row = re.compile(r"^\|\s*(\w+)\s*=\s*(.*?)\s*$", re.M)
    for f in sorted(wiki.glob("*.txt")):
        text = f.read_text(encoding="utf-8", errors="replace")
        if "NPC Infobox" not in text:
            continue
        fields = dict(row.findall(text))
        if fields.get("Faction", "").strip() != faction:
            continue
        got = False
        for w, dm in WIKI_DAMAGE.items():
            v = fields.get(w, "").strip().lower()
            if v in ("effective", "resisted", "immune", "neutral"):
                votes.setdefault(dm, set()).add("weak" if v == "effective" else "neutral" if v == "neutral" else "strong")
                got = True
        if got:
            names.append(f.stem)
    if not names:
        return None
    pick = lambda want: [dm for dm, v in votes.items() if v == {want}]
    return {"weak": pick("weak"), "strong": pick("strong"), "from": names}


def assign_halls(halls, poi):
    """Tie each of the Hollow Halls' insides to its entrance. Inside, chests, notes and spawners carry a level
    offset, one per hall (+9, +14 ... +44), and the entrances' own levels sort the same way, one above (10,
    15 ... 45): the n-th offset is the n-th entrance. Every layout point and inside point then takes the hall
    of the nearest point with an offset (in 3D, height counting double: the halls are stacked). Adds "h"
    (entrances, insides' boxes and levels) to halls, a fourth value per layout point, and "hl" to inside
    points. Leaves things as they are when the counts don't match."""
    inside = [q for q in poi if q.get("in")]
    anchors = [(q["x"], q["y"], q["h"], q["_off"]) for q in inside if q.get("_off")]
    offsets = sorted({a[3] for a in anchors})
    entrances = sorted((q for q in poi if q.get("c") == "label" and q.get("t") == "Hollow Halls"
                        and not q.get("in") and q.get("lv")), key=lambda q: q["lv"])
    if not offsets or len(offsets) != len(entrances):
        print(f"halls: {len(offsets)} level offsets inside, {len(entrances)} entrances: not tied")
        return
    index = {off: i for i, off in enumerate(offsets)}
    cell = 4.0  # map px
    grid = {}
    for a in anchors:
        grid.setdefault((int(a[0] // cell), int(a[1] // cell)), []).append(a)

    def nearest(x, y, h):
        best, bd = None, float("inf")
        gx, gy = int(x // cell), int(y // cell)
        for r in range(0, 40):
            for dx in range(-r, r + 1):
                for dy in (range(-r, r + 1) if abs(dx) == r else (-r, r)):
                    for a in grid.get((gx + dx, gy + dy), ()):
                        d = ((a[0] - x) * W.M_PER_PX) ** 2 + ((a[1] - y) * W.M_PER_PX) ** 2 + 4 * (a[2] - h) ** 2
                        if d < bd:
                            best, bd = a, d
            if best is not None and (r * cell * W.M_PER_PX) ** 2 > bd:
                break
        return index[best[3]] if best else -1

    pts = halls["p"]
    xyz = [(pts[i] / 10, pts[i + 1] / 10, pts[i + 2]) for i in range(0, len(pts), 3)]
    ks = [nearest(*q) for q in xyz]
    # then each point takes the hall most of its neighbours within 8 m (and 8 m of height) have, twice:
    # rooms stay whole where an anchor of the hall above or below happened to be closer
    near = 8 / W.M_PER_PX
    cells = {}
    for i, (x, y, h) in enumerate(xyz):
        cells.setdefault((int(x // near), int(y // near)), []).append(i)
    for _ in range(2):
        votes = []
        for i, (x, y, h) in enumerate(xyz):
            count = {}
            gx, gy = int(x // near), int(y // near)
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    for j in cells.get((gx + dx, gy + dy), ()):
                        if abs(xyz[j][2] - h) <= 8 and (xyz[j][0] - x) ** 2 + (xyz[j][1] - y) ** 2 <= near * near:
                            count[ks[j]] = count.get(ks[j], 0) + 1
            votes.append(max(count, key=count.get))
        ks = votes
    out = []
    boxes = [[1e9, 1e9, -1e9, -1e9] for _ in offsets]
    for (x, y, h), i, k in zip(xyz, range(0, len(pts), 3), ks):
        out += [pts[i], pts[i + 1], h, k]
        if k >= 0:
            b = boxes[k]
            b[0], b[1], b[2], b[3] = min(b[0], x), min(b[1], y), max(b[2], x), max(b[3], y)
    halls["p"] = out
    brief = hall_brief(halls.pop("_rows"), dict(zip(halls.pop("_k"), ks)), len(offsets))
    for q in inside:
        q["hl"] = index[q["_off"]] if q.get("_off") in index else nearest(q["x"], q["y"], q["h"])
    def region(e):  # the biome word in the entrance's template names the region (BIOME_TOKENS ~ REGION_NAMES)
        t = e.get("_tpl", "").lower()
        return next((REGION_NAMES[i] for i, b in enumerate(BIOME_TOKENS) if b in t), None)

    for q in inside:
        if q.get("c") == "updraft" and q.get("hl", -1) >= 0:
            brief[q["hl"]]["glide"] = brief[q["hl"]].get("glide", 0) + 1
    halls["h"] = [{"x": e["x"], "y": e["y"], "lv": e["lv"], "n": region(e), "b": [round(v, 1) for v in boxes[i]],
                   "in": brief[i]} for i, e in enumerate(entrances)]
    for e in halls["h"]:
        print(f"  {e['n']} L{e['lv']}: {e['in']}")
    halls["dmg"] = faction_damage("Hollow")
    print(f"  Hollow damage (wiki): {halls['dmg']}")
    print("halls: " + ", ".join(f"level {e['lv']} <- inside +{offsets[i]}" for i, e in enumerate(entrances)))


GATHER_CELLS_PER_ITEM = 150
EVERYWHERE = {"Wood Logs": "Fell any tree"}


def gather_cells(export, items):
    """Where each item grows or lies: {item id: [cell x, cell y, count, area level, ...]} on 128 m cells
    (16 px of the 1280 grid), the densest cells first, from data/export/gather.tsv."""
    path = export / "gather.tsv"
    if not path.exists():
        return {}
    # a template giving 3+ items is a random container (Prop_Ancients_Container_Mining: one of four ores);
    # an item uses those spots only when nothing gives it for sure, and is flagged "gm"
    sure, mixed = {}, {}
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split("\t")
        if len(parts) != 6:
            continue
        _, ids, cx, cy, n, lv = parts
        ids = ids.split(",")
        for iid in ids:
            if iid not in items:
                continue
            c = (mixed if len(ids) >= 3 else sure).setdefault(iid, {}).setdefault((int(cx), int(cy)), [0, 0])
            c[0] += int(n)
            c[1] = max(c[1], int(lv))
    cells = dict(sure)
    for iid, cs in mixed.items():
        if iid not in cells:
            cells[iid] = cs
            items[iid]["gm"] = 1
    for iid, it in items.items():  # from terrain everyone can reach, not placed objects
        if it["n"] in EVERYWHERE:
            it["ew"] = EVERYWHERE[it["n"]]
    out = {}
    for iid, cs in cells.items():
        items[iid]["gn"] = len(cs)  # cells it grows in: 1000+ (Twigs, Stone, Plant Fiber) is "everywhere"
        best = sorted(cs.items(), key=lambda kv: -kv[1][0])[:GATHER_CELLS_PER_ITEM]
        out[iid] = [v for (cx, cy), (n, lv) in best for v in (cx, cy, n, lv)]
    return out


BIOME_TOKENS = ["grassland", "deepforest", "steppe", "desert", "coldheights", "wetland", "ancientland"]
REGION_NAMES = ["Springlands", "Revelwood", "Nomad Highlands", "Kindlewastes", "Albaneve Summits", "Veilwater Basin",
                "Cinder's Cradle", "Blackmire"]


def regions(export, points):
    """Region map on the GRID x GRID cells (80 x 80 of 128 m), from the biome word in template names (Scatter_Loot_Desert_...,
    8kMapLabel_..._coldheights_...) weighted by how many there are. Each biome is named after the regions whose
    Ancient Spires stand in it; a biome with several (Revelwood's forest also holds the Blackmire spire) is split
    between them by the nearest spire. Every name in REGION_NAMES must end up with ground, or the build says so.
    Returns {"names", "cells" (GRID x GRID chars, "0" = unknown, "1".. = names index + 1),
    "anchors" {region: [[x, y, title], ...]} (its spires and passages, for zone pins)}."""
    votes = {}

    def vote(name, cx, cy, n):
        low = name.lower()
        tok = next((t for t in BIOME_TOKENS if t in low), None)
        if tok and 0 <= cx < GRID and 0 <= cy < GRID:
            v = votes.setdefault((cx, cy), {})
            v[tok] = v.get(tok, 0) + n

    path = export / "gather.tsv"
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            parts = line.split("\t")
            if len(parts) == 6:
                vote(parts[0], int(parts[2]), int(parts[3]), int(parts[4]))
    for line in (export / "poi.tsv").read_text(encoding="utf-8").splitlines():
        parts = (line.split("\t") + [""] * 10)[:10]
        try:
            x, z = float(parts[4]), float(parts[6])
        except ValueError:
            continue
        mx, my = W.map_from_half(x, z)
        vote(parts[1], int(mx // CELL_PX), int(my // CELL_PX), 5)
    top = {c: max(v, key=v.get) for c, v in votes.items()}

    # name each biome after the spires standing in it
    anchors, named = {}, {}  # named: biome token -> {region: [spire cells]}
    for p in points:
        if p.get("c") != "label" or p.get("k") not in ("Ancient Spire", "Place"):
            continue
        region = next((r for r in REGION_NAMES if r.lower() in p["t"].lower()), None)
        if not region:
            continue
        anchors.setdefault(region, []).append([p["x"], p["y"], p["t"]])
        if p["k"] == "Ancient Spire":
            cx, cy = int(p["x"] // CELL_PX), int(p["y"] // CELL_PX)
            near = {}
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    t = top.get((cx + dx, cy + dy))
                    if t:
                        near[t] = near.get(t, 0) + 1
            if near:
                t = max(near, key=near.get)
                named.setdefault(t, {}).setdefault(region, []).append((cx, cy))
    names = sorted({r for rs in named.values() for r in rs})
    cells = ["0"] * (GRID * GRID)
    for (cx, cy), t in top.items():
        rs = named.get(t)
        if not rs:
            continue
        r = min(rs, key=lambda r: min((cx - a) ** 2 + (cy - b) ** 2 for a, b in rs[r]))
        cells[cy * GRID + cx] = chr(ord("1") + names.index(r))
    counts = {r: cells.count(chr(ord("1") + i)) for i, r in enumerate(names)}
    print("regions:", {t: sorted(rs) for t, rs in named.items()}, counts)
    missing = [r for r in REGION_NAMES if r not in names]
    if missing:
        print(f"WARNING: regions with no ground on the map: {missing} (no spire found in a known biome)")
    return {"names": names, "cells": "".join(cells), "anchors": anchors}


def hint_tags(items):
    """From each item's acquisition hint: the regions it names ("rz"), underwater ("uw"), in the Shroud ("sh")."""
    for it in items.values():
        h = it.get("h") or ""
        rz = [r for r in REGION_NAMES if r in h]
        if rz:
            it["rz"] = rz
        if "underwater" in h.lower():
            it["uw"] = 1
        if re.search(r"\bShroud\b", h) and not h.startswith("Shroud "):  # "Kindlewastes Shroud", not "Shroud Spores"
            it["sh"] = 1


def attach_roots(points, plants):
    """Shroud Roots: done once the plant's first-time skill point is claimed (its own knowledge flag).

    The marker and the plant are separate entities a few metres apart; a plant with no marker becomes a point.
    Elixir Well cores (3 points) sit far below their marker and keep the well's own completion flag.
    """
    near = lambda p, x, z: (p["_hx"] - x) ** 2 + (p["_hz"] - z) ** 2
    roots = [p for p in points if p.get("k") == "Shroud Root"]
    wells = [p for p in points if p.get("k") == "Elixir Well"]
    for x, z, kid in plants:
        best = min(roots, key=lambda r: near(r, x, z), default=None)
        if best and near(best, x, z) < 60 ** 2:  # 30 m
            best["d"] = {"t": "", "k": kid}
        elif not any(near(w, x, z) < 700 ** 2 for w in wells):
            mx, my = mp(x, z)
            points.append({"x": mx, "y": my, "_hx": x, "_hz": z,
                           "c": "label", "k": "Shroud Root", "t": "Shroud Root", "d": {"t": "", "k": kid}})


def attach_special(points, loot):
    """Fixed loot: a single-candidate item goes on its exact chest; others become an area point."""
    chests = [p for p in points if p["c"] == "chest"]
    for sp in loot.special:
        iid = sp["item_id"]
        if iid not in loot.items:
            continue
        x0, y0, z0, x1, y1, z1 = (float(v) * 2 for v in sp["box"].split(","))  # metres -> half-metres
        cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
        if sp["candidates"] == 1:
            best = min(chests, key=lambda c: (c["_hx"] - cx) ** 2 + (c["_hz"] - cz) ** 2, default=None)
            if best and (best["_hx"] - cx) ** 2 + (best["_hz"] - cz) ** 2 < 25:
                best.setdefault("sp", []).append(iid)
                continue
        mx, my = mp(cx, cz)
        p = {"x": mx, "y": my, "c": "special", "t": loot.items[iid]["n"], "i": iid, "n": sp["candidates"]}
        if sp["candidates"] == 1:
            p["h"] = round(y0 / 2)  # one spot: its height; an area's box spans too much to give one
        points.append(p)


# the 12 sectors of the skill tree, clockwise from 0 degrees (east), each 30 degrees wide;
# named from their signature skills, then checked against a published build guide's area names
# (Guardian holds Heavy Plates and Thick Skin; Trickster holds Quick Charge; Battlemage holds Blink)
# the twelve 30-degree sectors of the skill tree, clockwise from east, as the game's tree art labels them
# (the names aren't in the export); the app places each label from its skills
ARCHETYPES = ["Wizard", "Healer", "Battlemage", "Guardian", "Warrior", "Barbarian", "Athlete", "Survivor",
              "Beastmaster", "Ranger", "Assassin", "Trickster"]


SKILL_FRAMES = {  # asset name -> (source texture, size in px)
    **{f"{kind}_{state}": (f"skillnode_{kind}_{state}", 64 if kind == "activeskill" else 48)
       for kind in ("passiveskill", "activeskill", "attribute") for state in ("activated", "inreach", "outofreach")},
    "spark": ("skillnode_starting", 64),
    "ring": ("skilltree_starter_ring", 512),
}


def skill_art(export, names, out):
    """Copy node frames and skill icons into the app; returns {skill name: icon base} for matched icons."""
    src = export / "skilltree"
    if not src.exists():
        return {}
    from PIL import Image
    out.mkdir(parents=True, exist_ok=True)
    for asset, (tex, size) in SKILL_FRAMES.items():
        if (src / f"{tex}.png").exists():
            im = Image.open(src / f"{tex}.png").convert("RGBA")
            im.thumbnail((size, size), Image.LANCZOS)
            im.save(out / f"{asset}.png", optimize=True)
    squash = lambda s: re.sub(r"[^a-z0-9]", "", (s or "").lower())
    icons = {squash(f.name[: -len("_unlocked.png")]): f.name[: -len("_unlocked.png")] for f in src.glob("*_unlocked.png")}
    alias = {  # icon textures whose names differ from the skill
        "Crash Down Attack": "crashdown_slash", "Airborne Architect": "flying_architect", "Bow Specialization": "bow",
        "Dagger Specialization": "dagger", "Wand Specialization": "wand", "One-Handed Specialization": "one-handed",
        "Two-Handed Specialization": "two-handed", "Heavy Hitter": "heavyspecialization", "Upwards Slash Attack": "upwards_slash",
        "Whirlwind Crescendo": "whirl_attack", "Splash Dash": "water_dodge", "Aerial Wand Attack": "wand_jump_attack",
        "Strategic Maneuver": "dodge_around", "Shrapnel Blast": "shrapnel_attack",
    }
    matched = {}
    for name in names:
        base = alias.get(name) or icons.get(squash(name))
        if not base:
            continue
        matched[name] = base
        for state in ("unlocked", "out_of_reach"):
            f = src / f"{base}_{state}.png"
            if f.exists():
                im = Image.open(f).convert("RGBA")
                im.thumbnail((56, 56), Image.LANCZOS)
                im.save(out / f"icon_{base}_{state}.png", optimize=True)
    return matched


# skill config ids (hashed parameter names) whose role is known from the descriptions they fill
CFG_CHANCE, CFG_RADIUS = 3726022082, 1815063917
KEY_BEFORE = re.compile(r"(press(ing)?|hold(ing)?( down the)?|jumping with)\s*$", re.I)


def skill_values(node):
    """A node's numbers: one dict per value config (per rank when scaled by the skill level)."""
    out = []
    for c in node.get("config") or []:
        kind, ty, raw = c.split("|", 2)
        if "AttributeReference" in ty or "TemplateImpact" in ty:
            continue
        v = json.loads(raw)
        num = v.get("scaleFactor") if kind == "scaled" else v.get("value")
        if not isinstance(num, (int, float)) or isinstance(num, bool):
            continue
        out.append({"v": num, "fmt": v.get("valueFormat"), "scaled": kind == "scaled", "id": v["configId"]["value"],
                    "guid": v.get("id", "")})
    return out


def fmt_value(c, max_level):
    """5% / 5-10-15% per rank / 10 / 3 s."""
    unit = "%" if c["fmt"] == "Percentage" else (" s" if c["fmt"] == "Duration" else "")
    base = c["v"] * 100 if c["fmt"] == "Percentage" else c["v"]
    nums = [base * r for r in range(1, max_level + 1)] if c["scaled"] and max_level > 1 else [base]
    return "/".join(f"{round(n, 1):g}" for n in nums) + unit


def fill_skill(desc, values, max_level):
    """Replace each %k with the value that fits its words: a key, a chance, a radius, seconds, an amount, a percentage.

    Returns (text, guessed): guessed when two different values fitted a %k equally well.
    """
    text = clean(desc) or ""
    used, out, pos, guessed = set(), [], 0, False
    order = {i: r for r, i in enumerate(sorted(range(len(values)), key=lambda i: values[i]["guid"]))}
    for m in re.finditer(r"%k", text):
        before, after = text[max(0, m.start() - 30) : m.start()], text[m.end() : m.end() + 16].lower()
        out.append(text[pos : m.start()])
        pos = m.end()
        if KEY_BEFORE.search(before) and not re.match(r"\s*(second|meter|%|chance)", after):
            out.append("[key]")
            continue
        if after.startswith(" chance"):
            want = "chance"
        elif after.startswith(" meter"):
            want = "radius"
        elif re.match(r" (second|minute|times your|mana|health|stamina|durability|experience|fire|shock|ice|blunt)", after) \
                or "cost:" in before.lower():
            want = "amount"
        else:
            want = "pct"

        def score(i):
            c = values[i]
            pct = c["fmt"] == "Percentage"
            s = {"chance": 3 * (c["id"] == CFG_CHANCE) + pct,
                 "radius": 3 * (c["id"] == CFG_RADIUS) + (not pct),
                 "amount": 2 * (not pct) - 2 * (c["id"] == CFG_CHANCE) - (c["id"] == CFG_RADIUS),
                 "pct": 2 * pct - (c["id"] == CFG_CHANCE)}[want]
            return s - (10 if i in used else 0)

        if not values:
            out.append("?")
            continue
        # ties: between percentages the lowest guid goes first (Fatal Precision, Runner), otherwise list order
        # (Ranger); both match the text wherever the true numbers are known
        tie = lambda i: -order[i] if values[i]["fmt"] == "Percentage" else -i
        ranked = sorted(range(len(values)), key=lambda i: (score(i), tie(i)), reverse=True)
        best = ranked[0]
        if len(ranked) > 1 and score(ranked[1]) == score(best) and best not in used                 and fmt_value(values[ranked[1]], max_level) != fmt_value(values[best], max_level):
            guessed = True
        used.add(best)
        c = values[best]
        if c["v"] < 0 and re.search(r"(reduced|decreased|less)\s+by\s*$", before):
            c = {**c, "v": -c["v"]}  # "reduced by -1 seconds" reads as "reduced by 1 seconds"
        out.append(fmt_value(c, max_level))
    out.append(text[pos:])
    return "".join(out).replace("%%", "%"), guessed


# What a skill does, from its filled-in effect text: axis -> pattern. Used for build projections.
SKILL_AXES = {
    "damage": r"damage (is|are|of|dealt|against)|damage with [^.]*increased|damage by\b|increased damage"
              r"|increased physical damage|deal[s]? [^.]*damage"
              r"|critical strike (chance|damage)|attack speed|merciless|backstab|sneak attack|skillshot|special abilit"
              r"|charge time|overpower|stun bars|summon|companion|totems|will attack the enemy|upward strike"
              r"|increases your (dexterity|strength|intelligence)|chance to poison",
    "area": r"all enemies|enemies within|within \d[\d/]* meters of the target|explosion|explosive|flurry|whirl|shockwave"
            r"|additional random target|pierces enemies|secondary|multi ?shot|small radius|all fell enemies",
    "survival": r"health|armor points|resistance|heal|leech|parry|block(ing)?\b(?! enemies)|revive|dodge|blink|stuns?\b"
                r"|absorb|reflect|slowed|attention|martyr|poison resistance|being poisoned",
    "sustain": r"restore[s]? .*(mana|stamina)|(mana|stamina) regeneration|stamina cost|consume .* less stamina|orb"
               r"|increases your (endurance|spirit)|(endurance|spirit) attribute",
    "gathering": r"tools |mining|additional resource|pickaxe|felling axe|fishing|against (wood|stone|metal)|durability",
    "building": r"while building|inside the base",
    "exploration": r"glider|gliding|sprint|climb|double jump|jumping a second|swim|diving|time in the shroud|zoom"
                   r"|while sneaking|grappling hook|no longer attack|roads|airborne|wet",
    "passives": r"food|rested|potions|sweets|experience points|persist through death",
}
# weapon types a skill's effect needs (a skill that names none works with anything)
SKILL_WEAPONS = [
    (r"\bbows?\b|arrows?|ranged explosives|ranged piercing|skillshot|dexterity", ["Bow"]),
    (r"daggers?|dexterity|backstab|sneak attack", ["Dagger"]),
    (r"wands?|magic weapon|intelligence|spells?", ["Wand"]),
    (r"staff|staves|magic weapon|intelligence|spells?", ["Staff"]),
    (r"one-handed|swords?\b|axes\b|clubs?\b|melee weapon|melee damage|strength|melee cutting|melee blunt|melee piercing",
     ["Sword", "Axe", "Mace"]),
    (r"two-handed|greatswords?|hammers?|melee weapon|melee damage|strength|melee cutting|melee blunt|melee piercing",
     ["Greatsword", "Hammer", "Two-handed axe"]),
    (r"shield|ward\b|parry|block", ["Shield"]),
]


MELEE_AND_SHIELD = ["Axe", "Dagger", "Greatsword", "Hammer", "Mace", "Shield", "Sword", "Two-handed axe"]


def skill_function(name, text, kind):
    """Axes a skill feeds and the weapons it needs, from its effect paragraphs.

    Glossary paragraphs are dropped (unless titled with the skill's own name), and so are sentences
    about what cannot be used.
    """
    paras = []
    for para in text.split("\n\n"):
        first = para.strip().split("\n")[0].strip()
        if paras and len(first.split()) <= 4 and not first.endswith(".") and first.lower() != name.lower():
            break
        paras.append(para)
    low = " ".join(paras).lower()
    low = " ".join(x for x in re.split(r"(?<=[.!])\s+", low) if "cannot" not in x)
    low = low.replace("break the armor of enemies", "").replace("damage received", "")
    if "tools deal" in low or re.search(r"pickaxe|felling axe", name.lower()):
        return ["gathering"], []
    if "durability" in low:  # weapon upkeep: a convenience, tied to the weapon that triggers it
        axes = ["passives"]
    elif kind != "Attribute":
        axes = [a for a, pat in SKILL_AXES.items() if re.search(pat, low)]
    if kind == "Attribute":
        attr = re.search(r"(strength|dexterity|intelligence|constitution|endurance|spirit)", low)
        a = attr.group(1) if attr else ""
        axes = ["damage"] if a in ("strength", "dexterity", "intelligence") else (["survival"] if a == "constitution" else ["sustain"])
    weapons = sorted({w for pat, ws in SKILL_WEAPONS if re.search(pat, low) for w in ws})
    tied = set(axes) & {"damage", "area"} or re.search(
        r"critical strikes with|defeating an enemy with|killing an enemy with|equipped with|dealing damage with", low)
    if re.search(r"parry|block|merciless|overpower", low):
        weapons, tied = sorted(set(weapons) | set(MELEE_AND_SHIELD)), True  # parries need a melee weapon, dagger or shield
    return axes, weapons if tied else []


def skill_factor(text):
    """How often an effect applies: 0.4 when it only works on one enemy kind or with throwables or bare fists,
    0.6 for one element; 1 otherwise."""
    low = (text or "").lower().split("\n\n")[0]
    if "tools deal" in low:
        return 1
    if re.search(r"damage against|throwable damage|unarmed damage|unarmed attacks", low):
        return 0.4
    if re.search(r"all (fire|ice|shock|shroud) damage", low):
        return 0.6
    return 1


def skill_tree(export):
    nodes = read(export, "skills.jsonl")
    neighbours = {n["node_id"]: set() for n in nodes}
    for link in read(export, "skill_links.jsonl"):
        if link["from"] in neighbours and link["to"] in neighbours:
            neighbours[link["from"]].add(link["to"])
            neighbours[link["to"]].add(link["from"])
    # the tree's centre: the Root (Spark) nodes' centroid, to 10 units (it comes out half a unit off the
    # authored (4000, 4000), which tips nodes lying on a sector line, like Breach at 150 degrees, the other way)
    roots = [n for n in nodes if n["type"] == "Root"] or nodes
    cx = round(sum(n["x"] for n in roots) / len(roots), -1)
    cy = round(sum(n["y"] for n in roots) / len(roots), -1)
    sparks = [math.hypot(n["x"] - cx, n["y"] - cy) for n in nodes if n["type"] == "Root"]
    spark_ring = min(sparks) if sparks else 0
    out = []
    for n in nodes:
        if not clean(n["name"]):
            continue
        angle = math.degrees(math.atan2(n["y"] - cy, n["x"] - cx)) % 360
        inner = math.hypot(n["x"] - cx, n["y"] - cy) < spark_ring - 40
        values = skill_values(n)
        text, guessed = fill_skill(n["description"], values, n["max_level"])
        axes, weapons = skill_function(clean(n["name"]), text, n["type"])
        row = {
            "id": n["node_id"], "n": clean(n["name"]), "d": text or None,
            "pl": fill_skill(n["per_level"], values, 1)[0] or None if n["per_level"] else None,
            "g": 1 if guessed else None, "fx": axes or None, "wp": weapons or None,
            "cf": skill_factor(text) if skill_factor(text) < 1 else None,
            "ty": n["type"], "cl": n["class"], "mx": n["max_level"], "c": n["costs"],
            "x": round(n["x"], 1), "y": round(n["y"], 1), "lk": sorted(neighbours[n["node_id"]]),
            "ar": "Centre" if inner and n["type"] != "Root" else ARCHETYPES[int(angle // 30) % 12],
        }
        out.append({k: v for k, v in row.items() if v not in (None, "")})
    icons = skill_art(export, {r["n"] for r in out}, ROOT / "app" / "assets" / "skilltree")
    for r in out:
        if r["n"] in icons:
            r["ic"] = icons[r["n"]]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--export", default=ROOT / "data" / "export", type=pathlib.Path)
    ap.add_argument("--out", default=ROOT / "app" / "assets" / "game.json", type=pathlib.Path)
    a = ap.parse_args()

    items = {}
    for i in read(a.export, "items.jsonl"):
        name = clean(i["name"])
        if not name or i["category"] in SKIP_CATEGORIES:
            continue
        row = {"n": name, "c": i["category"], "r": i["rarity"]}
        for key, field in (("d", "description"), ("l", "lore"), ("h", "acquisition_hint")):
            if clean(i[field]):
                row[key] = clean(i[field])
        if i["max_stack"] > 1:
            row["s"] = i["max_stack"]
        items[i["item_id"]] = row

    debug = {i["item_id"]: i["debug_name"] or "" for i in read(a.export, "items.jsonl")}
    for iid, st in item_stats(a.export).items():
        if iid in items:
            wt = weapon_type(debug.get(iid, ""), st.get("sl"))
            if wt:
                st["wt"] = wt
            items[iid]["st"] = st
    loot = Loot(a.export, items)

    workshops = {}
    for w in read(a.export, "workshops.jsonl"):
        raw = w["name"] or ""
        kind = "npc" if "<npc>" in raw else w["kind"]
        workshops[w["workshop_id"]] = {"n": clean(raw) or w["workshop_id"], "k": kind}
        if w["item_id"] != "00000000":
            workshops[w["workshop_id"]]["it"] = w["item_id"]

    categories = {c["category_id"]: [i for i in c["items"] if i in items] for c in read(a.export, "recipe_categories.jsonl")}

    raw_recipes = read(a.export, "recipes.jsonl")
    unlocks = Unlocks(a.export, items, workshops,
                      {r["recipe_id"]: split_stack(r["outputs"][0])[0] for r in raw_recipes if r["outputs"]},
                      raw_recipes)
    print("artisans in conditions: " + ", ".join(
        f"{nid}={workshops[w]['n']} ({len(unlocks.stations.get(w, ()))} stations)" for nid, w in unlocks.npc.items()))
    recipes = []
    for r in raw_recipes:
        outputs = [split_stack(o) for o in r["outputs"]]
        if not any(o[0] in items for o in outputs):
            continue
        unlock = None if r["knowledge_query"] == "00000000" else unlocks.query(r["knowledge_query"])
        recipes.append({
            "u": unlock,
            "id": r["recipe_id"],
            "w": r["workshop_id"],
            "i": [split_stack(i) for i in r["inputs"]],
            "o": outputs,
            "p": r["required_props"],
            "t": round(int(r["duration_ns"]) / 1e9, 1),
        })

    sets = []
    for s in read(a.export, "item_sets.jsonl"):
        entries = []
        for e in s["entries"]:
            if e["item_id"] not in items:
                continue
            hints = []
            for h in e["hints"]:
                text = clean(h["hint"])
                if text and text not in hints:
                    hints.append(text)
            entries.append({"i": e["item_id"], "h": hints, "d": unlocks.flag(e.get("done"), e.get("done_type"))})
        if entries:
            sets.append({"c": clean(s["category"]), "n": clean(s["name"]), "e": entries})

    def docs(rows, quest=False):
        out = []
        for c in rows:
            if c["tutorial"] == "true" or not clean(c["name"]):
                continue
            pages = []
            for e in c["entries"]:
                if not clean(e["text"]):
                    continue
                page = {"n": clean(e["name"]), "t": clean(e["text"])}
                flag = unlocks.flag(e.get("done"), e.get("done_type")) if quest else unlocks.flag(e.get("seen"), e.get("seen_type"))
                if flag:
                    page["d"] = flag
                pages.append(page)
            if not pages:
                continue
            doc = {"n": clean(c["name"]), "c": clean(c["lore_category"]) if not re.fullmatch(r"[0-9a-f]{8}", c["lore_category"] or "") else None, "p": pages}
            if quest:
                doc["m"] = c["main"] == "true"
                doc["rw"] = [i for i in c["rewards"] if i in items]
            out.append(doc)
        return out

    lore = docs(read(a.export, "lore.jsonl"))
    # lore page title -> [doc index, page index], so a map note opens its journal page
    lore_pages = {pg["n"]: [di, pi] for di, d in enumerate(lore) for pi, pg in enumerate(d["p"]) if pg.get("n")}
    halls = hall_layout(a.export)
    db = {
        "version": 1,
        # when this data was built: the phone takes a newer copy from the PC agent (GET /db) without a reinstall
        "built": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "items": items,
        "workshops": workshops,
        "categories": categories,
        "recipes": recipes,
        "sets": sets,
        "lore": lore,
        "poi": points(a.export, unlocks, lore_pages, loot, (halls or {}).get("b")),
        "quests": docs(read(a.export, "quests.jsonl"), quest=True),
        "skills": skill_tree(a.export),
        "gather": gather_cells(a.export, items),
        # the map grid and world size (tools/world.py), and the cells "gather" and "regions" use
        "world": {"size_m": W.SIZE_M, "map_px": W.MAP_PX, "cell_px": CELL_PX, "grid": GRID},
    }
    db["regions"] = regions(a.export, db["poi"])
    db["fish"] = fish_tables(a.export, {p["ft"] for p in db["poi"] if p.get("ft")}, items)
    if halls:
        assign_halls(halls, db["poi"])
        halls.pop("_k", None)
        halls.pop("_rows", None)
        db["halls"] = halls
    for q in db["poi"]:
        q.pop("_off", None)
        q.pop("_tpl", None)
    hint_tags(items)
    a.out.parent.mkdir(parents=True, exist_ok=True)
    if (a.export / "balancing.json").exists():
        db["balancing"] = json.loads((a.export / "balancing.json").read_text(encoding="utf-8"))
    if loot.ok:
        used = {p["ls"] for p in db["poi"] if p.get("ls")}
        db["loot"] = {sid: v for sid, v in loot.summary().items() if sid in used}
        kinds = {}
        for p in db["poi"]:
            if p.get("ls"):
                kinds.setdefault(p["t"].split(" · ")[0], set()).add(p["ls"])
        for iid, where in loot.drops(kinds).items():
            items[iid]["lc"] = where
        for p in db["poi"]:
            for iid in p.get("sp", []) + ([p["i"]] if p.get("c") == "special" else []):
                items[iid]["fx"] = items[iid].get("fx", 0) + 1  # fixed placements in the world
    a.out.write_text(json.dumps(db, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"{a.out}: {a.out.stat().st_size // 1024} KB, {len(items)} items, {len(recipes)} recipes, "
          f"{len(sets)} sets, {len(db['lore'])} lore docs, {len(db['quests'])} quests")


if __name__ == "__main__":
    main()
