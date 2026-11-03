"""Item icons for the app from the Enshrouded wiki (enshrouded.wiki.gg): app/assets/icons/*.png, 64×64.

    python tools/icons.py            # match every item, download the icons not on disk yet
    python tools/icons.py --force    # download them all again
    python tools/icons.py --map      # only the map markers (app/assets/map_icons, see build_map)

The game draws most item icons from 3D models at runtime, so the game files don't hold them; the wiki keeps
the in-game icons as files named after the item ("Copper Ore.png", 256×256). Each item name is matched, in
order, to:
  1. the file named after it (also with ' for ’ and without quotes: Room Divider "Snake"), or the image
     in the infobox of the article with that title (any case);
  2. the article it redirects to, when that is the same name (plural, ’ for ');
  3. steps 1-2 for the singular ("Fired Bricks" → "Fired Brick"), when that isn't an item of its own;
  4. steps 1-2 for the name without its tier numeral ("Giant Bone Arrow I" → "Giant Bone Arrow").
Nothing else counts, and only squarish images do (no screenshots), so an item without a sure match gets
no icon. Items sharing a name share the icon, and files are written once however many items use them.

icons/index.json maps item id → file name, so the app knows which items have an icon without probing
assets. API requests go a second apart (about 80), downloads four a second (about 3,000, ~12 min).
The icons are Keen Games' art as shown on the wiki; they stay in this personal app.
"""
import argparse
import html
import io
import json
import pathlib
import re
import sys
import time
import urllib.request

from PIL import Image

from wiki import OUT as WIKI, UA, _get

ROOT = pathlib.Path(__file__).resolve().parent.parent
GAME = ROOT / "app" / "assets" / "game.json"
OUT = ROOT / "app" / "assets" / "icons"
MAP_OUT = ROOT / "app" / "assets" / "map_icons"
MAP_GROUPS = "Map:Embervale/Groups"  # the wiki map's marker groups: name, icon file, size
SIZE = 64
BAD_TITLE = re.compile(r"[#<>\[\]|{}]")
NUMERAL = re.compile(r"\s+(?:I|II|III|IV|V|VI|VII|VIII|IX|X)$")
IMAGE = re.compile(r"\s*([^|:,]+?\.(?:png|jpe?g|webp|gif))", re.I)


def norm(name):
    """A name as compared with a redirect's target: case, apostrophes, plural and tier numeral left out."""
    n = NUMERAL.sub("", name.replace("’", "'").strip()).lower()
    return re.sub(r"(?<=[a-z])(es|s)$", "", n)


def local_infoboxes():
    """title.lower() → (title, infobox image file) from the local wiki copy; item and armour articles only."""
    out = {}
    for f in WIKI.glob("*.txt"):
        text = f.read_text(encoding="utf-8")
        title = text.split("\n", 1)[0][2:].strip()
        image = None
        if re.search(r"^\{\{(?:Item|Armor) Infobox", text, re.M):
            m = re.search(r"^\s*\|\s*images?\s*=\s*(.*)$", text, re.M)
            v = m.group(1).replace("{{PAGENAME}}", title).replace("{{SUBPAGENAME}}", title) if m else ""
            hit = IMAGE.match(v)
            if hit:
                image = html.unescape(hit.group(1)).strip()
        out[title.lower()] = (title, image)
    return out


def batches(xs, n=50):
    xs = list(xs)
    for i in range(0, len(xs), n):
        yield xs[i : i + n]


def file_info(files):
    """File name → (width, height, thumbnail url) for the files that exist."""
    out = {}
    for chunk in batches(sorted(set(files))):
        j = _get({
            "action": "query", "format": "json", "formatversion": "2",
            "prop": "imageinfo", "iiprop": "url|size", "iiurlwidth": str(SIZE),
            "titles": "|".join("File:" + f for f in chunk),
        })
        q = j.get("query") or {}
        back = {}
        for n in q.get("normalized", []):
            back[n["to"]] = n["from"]
        for p in q.get("pages", []):
            ii = (p.get("imageinfo") or [None])[0]
            if p.get("missing") or not ii:
                continue
            asked = back.get(p["title"], p["title"])[len("File:"):]
            out[asked] = (ii.get("width") or 0, ii.get("height") or 0, ii.get("thumburl") or ii.get("url"))
        time.sleep(1)
    return out


def redirects(titles):
    """Title → the article it redirects to."""
    out = {}
    for chunk in batches(sorted(set(titles))):
        j = _get({"action": "query", "format": "json", "formatversion": "2", "redirects": "1", "titles": "|".join(chunk)})
        q = j.get("query") or {}
        back = {n["to"]: n["from"] for n in q.get("normalized", [])}
        for r in q.get("redirects", []):
            out[back.get(r["from"], r["from"])] = r["to"]
        time.sleep(1)
    return out


def candidates(name, boxes):
    """Files that may be this name's icon, best first."""
    title, image = boxes.get(name.lower(), (None, None))
    out = []
    plain = re.sub(r"\s+", " ", name.replace('"', "")).strip()
    for n in dict.fromkeys([name, name.replace("’", "'"), plain, title]):
        if n:
            out.append(n + ".png")
    if image:
        out.append(image)
    return [f for f in dict.fromkeys(out) if not BAD_TITLE.search(f)]


def square(info):
    w, h, url = info
    return url and w and h and 0.75 <= w / h <= 1.3


def match(names, boxes, log=print):
    """Item name → wiki file name, and how many came from a tier numeral."""
    chosen = {}

    def settle(todo, cands):
        info = file_info(f for cs in cands.values() for f in cs)
        for n in todo:
            for f in cands[n]:
                if f in info and square(info[f]):
                    chosen[n] = (f, info[f][2])
                    break

    # 1. the name itself
    cands = {n: candidates(n, boxes) for n in names}
    settle(names, cands)
    log(f"icons: {len(chosen)} of {len(names)} names by their own name")
    # 2. a redirect to the same name
    left = [n for n in names if n not in chosen and not BAD_TITLE.search(n)]
    red = redirects(left)
    cands = {n: candidates(red[n], boxes) for n in left if n in red and norm(red[n]) == norm(n)}
    settle(list(cands), cands)
    log(f"icons: {len(chosen)} after redirects")
    # 3. the singular, when it isn't another item
    known = {n.lower() for n in names}
    left = [n for n in names if n not in chosen and re.search(r"[a-z]s$", n)]
    cands = {n: candidates(n[:-1], boxes) for n in left if n[:-1].lower() not in known}
    settle(list(cands), cands)
    log(f"icons: {len(chosen)} after singulars")
    # 4. the name without its tier numeral
    left = [n for n in names if n not in chosen and NUMERAL.search(n)]
    base = {n: NUMERAL.sub("", n) for n in left}
    cands = {n: candidates(b, boxes) for n, b in base.items()}
    before = len(chosen)
    settle(left, cands)
    log(f"icons: {len(chosen)} after tier numerals")
    return chosen, len(chosen) - before


def file_name(wiki_file, taken):
    stem = re.sub(r"[^a-z0-9]+", "_", wiki_file.rsplit(".", 1)[0].lower()).strip("_") or "icon"
    name, i = stem + ".png", 2
    while name in taken:
        name, i = f"{stem}_{i}.png", i + 1
    taken.add(name)
    return name


def download(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Encoding": "identity"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read()
        except Exception:
            if attempt == 3:
                raise
            time.sleep(5 * (attempt + 1))


def to_icon(data):
    """The image fitted into a transparent 64×64 square, as a 256-colour PNG (half the size, looks the same)."""
    im = Image.open(io.BytesIO(data)).convert("RGBA")
    im.thumbnail((SIZE, SIZE), Image.LANCZOS)
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(im, ((SIZE - im.width) // 2, (SIZE - im.height) // 2))
    buf = io.BytesIO()
    out.quantize(256, method=Image.Quantize.FASTOCTREE).save(buf, "PNG", optimize=True)
    return buf.getvalue()


def build(force=False, log=print):
    items = json.loads(GAME.read_text(encoding="utf-8"))["items"]
    names = sorted({v["n"] for v in items.values()})
    chosen, by_numeral = match(names, local_infoboxes(), log)
    OUT.mkdir(parents=True, exist_ok=True)
    taken, files = set(), {}
    for f, url in sorted(set(chosen.values())):
        files[f] = (file_name(f, taken), url)
    failed = 0
    for f, (name, url) in files.items():
        path = OUT / name
        if path.exists() and not force:
            continue
        try:
            path.write_bytes(to_icon(download(url)))
        except Exception as e:
            failed += 1
            log(f"icons: {f}: {e}")
        time.sleep(0.25)
    # a collectible sharing its name with another kind of item (the music sheet "Mirage", the staff
    # "Mirage") gets no icon: the wiki file shows the other one
    kinds = {}
    for v in items.values():
        kinds.setdefault(v["n"], set()).add(v["c"])
    index = {}
    for iid, v in sorted(items.items()):
        hit = chosen.get(v["n"])
        if v["c"] == "Collectibles" and len(kinds[v["n"]]) > 1:
            continue
        if hit and (OUT / files[hit[0]][0]).exists():
            index[iid] = files[hit[0]][0]
    for p in OUT.glob("*.png"):  # icons no item uses any more
        if p.name not in set(index.values()):
            p.unlink()
    (OUT / "index.json").write_text(json.dumps(index, separators=(",", ":"), sort_keys=True), encoding="utf-8")
    log(f"icons: {len(index)} of {len(items)} items, {len(set(index.values()))} files"
        f" ({by_numeral} names by tier numeral, {failed} failed)")
    return index


def build_map(force=False, log=print):
    """Map markers as the game draws them (Flame Shrine, Night Sanctum, Enemy Camp...), from the wiki's own
    interactive map: its marker groups name an icon file each. map_icons/index.json maps a name (the group's,
    or the file's own) → file, and the app gives a place the icon whose name is in its title, else its kind.
    Groups drawn with an item's picture (Fossil → Big Ammonite) are left out: those are items, not markers,
    and the wiki keeps item pictures at 256 px while the markers are 56 (a few 128) px."""
    j = _get({"action": "query", "format": "json", "formatversion": "2", "prop": "revisions",
              "rvprop": "content", "rvslots": "main", "titles": MAP_GROUPS})
    groups = json.loads(j["query"]["pages"][0]["revisions"][0]["slots"]["main"]["content"])["groups"]
    items = {v["n"].lower() for v in json.loads(GAME.read_text(encoding="utf-8"))["items"].values()}
    names = {}
    for g in groups.values():
        f = (g.get("icon") or "").replace("_", " ").strip()
        stem = f.rsplit(".", 1)[0]
        if not f or stem.lower() in items:
            continue
        for n in (g.get("name"), stem):
            if n:
                names.setdefault(n, f)
    info = {f: v for f, v in file_info(names.values()).items() if max(v[0], v[1]) < 256}
    MAP_OUT.mkdir(parents=True, exist_ok=True)
    taken, files = set(), {}
    for f in sorted(info):
        files[f] = file_name(f, taken)
        path = MAP_OUT / files[f]
        if force or not path.exists():
            path.write_bytes(to_icon(download(info[f][2])))
            time.sleep(0.25)
    index = {n: files[f] for n, f in sorted(names.items()) if f in files}
    for p in MAP_OUT.glob("*.png"):
        if p.name not in set(index.values()):
            p.unlink()
    (MAP_OUT / "index.json").write_text(json.dumps(index, separators=(",", ":"), sort_keys=True), encoding="utf-8")
    log(f"map icons: {len(index)} names, {len(set(index.values()))} files")
    return index


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--map", action="store_true", help="only the map markers")
    a = ap.parse_args()
    if not a.map:
        build(a.force)
    build_map(a.force)


if __name__ == "__main__":
    sys.exit(main())
