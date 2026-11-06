"""The game's text in every language it ships, for the app: app/assets/i18n/game/<language>.json, English text
-> translation, for every text in game.json the game itself has (names, descriptions, lore, quests).

Called by tools/build_db.py when data/export/loca exists (tools/export_loca.py). The app keeps game.json in
English and translates at display time (lib/l10n.dart, gt()). Texts build_db writes itself (COMPOSED: "Pick up
{item}") are filled from tools/i18n/terms.json, which also holds the app-made labels ("Fishing spot"), with the
game's own translations of their arguments. Skill texts (FILLED) get their numbers put into the game's
translation. Texts with no translation anywhere stay English and are listed in data/export/loca/unmatched.txt.
"""
import collections
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
TERMS = ROOT / "tools" / "i18n" / "terms.json"
TAG = re.compile(r"</?[a-zA-Z_]+[^>]*>")
HEX = re.compile(r"[0-9a-f]{8}")


def clean(s):
    return TAG.sub("", s).replace("\r", "").strip()


def read(path):
    return {r["id"]: r["t"] for r in map(json.loads, path.read_text(encoding="utf-8").splitlines()) if r.get("t")}


def strings(v, out):
    if isinstance(v, str):
        if re.search(r"[^\W\d_]", v) and not HEX.fullmatch(v):
            out.add(v)
    elif isinstance(v, list):
        for x in v:
            strings(x, out)
    elif isinstance(v, dict):
        for x in v.values():
            strings(x, out)
    return out


def write(db, composed, filled, loca, out):
    langs = [line.split("\t")[0] for line in (loca / "languages.txt").read_text(encoding="utf-8").splitlines()
             if line.strip()]
    en = read(loca / "En_Us.jsonl")
    index = collections.defaultdict(list)
    for tid, text in en.items():
        index[clean(text)].append(tid)
    terms = json.loads(TERMS.read_text(encoding="utf-8")) if TERMS.exists() else {}
    texts = sorted(strings(db, set()))
    out.mkdir(parents=True, exist_ok=True)
    unmatched = set()
    for lang in langs:
        if lang == "En_Us":
            continue
        tx = read(loca / f"{lang}.jsonl")
        memo = {}

        def tr(s, depth=0):
            if s in memo:
                return memo[s] if memo[s] is not None else s
            got = None
            if s in composed and depth < 4:
                tpl, args = composed[s]
                t = terms.get(tpl, {}).get(lang)
                if t:
                    got = t.format(**{k: tr(v, depth + 1) if isinstance(v, str) else v for k, v in args.items()})
            if got is None and s in filled and filled[s][0] != s and depth < 4:
                # a skill text: the game's translation with the same numbers, in the same order
                raw, fills = filled[s]
                t = tr(raw, depth + 1)
                if t != raw and t.count("%k") == len(fills):
                    it = iter(fills)
                    got = re.sub(r"%k", lambda m: next(it), t).replace("%%", "%")
            if got is None and s in index:
                # one English text can stand for several tags: the most common translation wins
                c = collections.Counter(clean(tx[i]) for i in index[s] if i in tx and clean(tx[i]))
                got = c.most_common(1)[0][0] if c else None
            if got is None:
                got = terms.get(s, {}).get(lang)
            memo[s] = got
            return got if got is not None else s

        table = {}
        for s in texts:
            t = tr(s)
            if t != s:
                table[s] = t
            elif memo.get(s) is None:
                unmatched.add(s)
        (out / f"{lang}.json").write_text(json.dumps(table, ensure_ascii=False, separators=(",", ":")),
                                          encoding="utf-8")
        print(f"i18n {lang}: {len(table)} of {len(texts)} texts")
    plain = sorted(u for u in unmatched if u not in composed)
    tpls = sorted({composed[u][0] for u in unmatched if u in composed})
    (loca / "unmatched.txt").write_text("\n".join(tpls + ["---"] + plain) + "\n", encoding="utf-8")
