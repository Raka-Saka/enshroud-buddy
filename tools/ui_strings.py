"""The app's own texts: every tr()/trn() in app/lib, and what each language in app/assets/i18n/ui lacks.

    python tools/ui_strings.py [--write-keys tools/i18n/ui_keys.json] [--prune] [--merge-work]

--write-keys writes the keys with the files that use them (for translators). --prune drops translations of
texts the code no longer has. --merge-work takes the PC and data-label translations handed back per
language (tools/i18n/work). Exits 1 when a tr() argument isn't a plain literal (see docs/i18n.md).
"""
import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIB = ROOT / "app" / "lib"
UI = ROOT / "app" / "assets" / "i18n" / "ui"

# a Dart string literal: '...' or "..." with escapes, raw r'...' too
LIT = r"""(r?'(?:[^'\\\n]|\\.)*'|r?"(?:[^"\\\n]|\\.)*")"""
TR = re.compile(r"\btr\(\s*" + LIT + r"\s*[,)]")
TRN = re.compile(r"\btrn\(\s*[^,]+?,\s*" + LIT + r"\s*,\s*" + LIT + r"\s*[,)]")
ANY = re.compile(r"\btrn?\(")


def unquote(lit):
    raw = lit.startswith("r")
    body = lit[2:-1] if raw else lit[1:-1]
    if raw:
        return body
    return re.sub(r"\\(u\{[0-9a-fA-F]+\}|u[0-9a-fA-F]{4}|.)", lambda m: {
        "n": "\n", "t": "\t", "'": "'", '"': '"', "\\": "\\", "$": "$"}.get(m.group(1)) or (
        chr(int(m.group(1)[1:].strip("{}"), 16)) if m.group(1).startswith("u") else m.group(1)), body)


def scan():
    keys, plural, bad = {}, set(), []
    for f in sorted(LIB.rglob("*.dart")):
        if f.name == "l10n.dart":
            continue
        src = f.read_text(encoding="utf-8")
        rel = f.relative_to(LIB).as_posix()
        found = set()
        for m in TR.finditer(src):
            keys.setdefault(unquote(m.group(1)), set()).add(rel)
            found.add(m.start())
        for m in TRN.finditer(src):
            other = unquote(m.group(2))
            keys.setdefault(other, set()).add(rel)
            plural.add(other)
            found.add(m.start())
        for m in ANY.finditer(src):
            if m.start() not in found:
                line = src.count("\n", 0, m.start()) + 1
                bad.append(f"{rel}:{line}: {src[m.start():m.start() + 70].splitlines()[0]}")
        for k in keys:
            if "$" in k and rel in keys[k]:
                bad.append(f"{rel}: interpolation in a key: {k[:60]}")
    return keys, plural, bad


PC_FILES = ["agent/agent.py", "tools/overlay.py", "tools/ask.py"]
PC = ROOT / "tools" / "i18n" / "pc.json"
PY_T = re.compile(r"""\bt\(\s*"((?:[^"\\\n]|\\.)*)\"""")


def pc_keys():
    """The PC program's texts (pc_text.t), added to tools/i18n/pc.json with what each language lacks."""
    keys = []
    for f in PC_FILES:
        for m in PY_T.finditer((ROOT / f).read_text(encoding="utf-8")):
            k = re.sub(r"\\(.)", r"\1", m.group(1))
            if k not in keys:
                keys.append(k)
    old = json.loads(PC.read_text(encoding="utf-8")) if PC.exists() else {}
    PC.write_text(json.dumps({k: old.get(k, {}) for k in keys}, ensure_ascii=False, indent=1) + "\n",
                  encoding="utf-8")
    langs = sorted({c for v in old.values() for c in v})
    print(f"PC: {len(keys)} texts; " + ", ".join(f"{c} {sum(1 for k in keys if old.get(k, {}).get(c))}"
                                                 for c in langs))


def merge_work():
    """Translations handed back per language (tools/i18n/work/<code>.pc.json, <code>.terms.json) into pc.json and
    terms.json, which hold every language side by side."""
    work = ROOT / "tools" / "i18n" / "work"
    for kind in ("pc", "terms"):
        path = ROOT / "tools" / "i18n" / f"{kind}.json"
        table = json.loads(path.read_text(encoding="utf-8"))
        for f in sorted(work.glob(f"*.{kind}.json")):
            code = f.name.split(".")[0]
            for k, v in json.loads(f.read_text(encoding="utf-8")).items():
                if k in table and isinstance(v, str) and v.strip():
                    table[k][code] = v
        path.write_text(json.dumps(table, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
        print(f"{kind}.json: " + ", ".join(sorted({c for v in table.values() for c in v})))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write-keys", type=pathlib.Path)
    ap.add_argument("--prune", action="store_true")
    ap.add_argument("--merge-work", action="store_true")
    a = ap.parse_args()
    if a.merge_work:
        merge_work()
    keys, plural, bad = scan()
    pc_keys()
    print(f"{len(keys)} texts ({len(plural)} with plural forms)")
    if a.write_keys:
        a.write_keys.write_text(json.dumps(
            {k: {"files": sorted(v), **({"plural": True} if k in plural else {})} for k, v in sorted(keys.items())},
            ensure_ascii=False, indent=1), encoding="utf-8")
    for f in sorted(UI.glob("*.json")):
        if f.name.startswith("."):
            continue
        tx = json.loads(f.read_text(encoding="utf-8"))
        missing = [k for k in keys if not tx.get(k)]
        stale = [k for k in tx if k not in keys]
        if a.prune and stale:
            for k in stale:
                del tx[k]
            f.write_text(json.dumps(tx, ensure_ascii=False, indent=1, sort_keys=True) + "\n", encoding="utf-8")
        print(f"{f.stem}: {len(keys) - len(missing)}/{len(keys)}" + (f", {len(stale)} stale" if stale else ""))
    for b in bad:
        print("not a literal:", b)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
