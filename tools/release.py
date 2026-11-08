"""Copy what Enshroud Buddy ships into the GitHub repo's working copy.

    python tools/release.py G:/enshroudbuddy --apk app/build/app/outputs/flutter-apk/app-release.apk

Ships the app's source and a ready APK (release/enshroudbuddy.apk), the PC agent with its install scripts, the
game data the agent reads at runtime, the build tools, and the repo's own README, LICENSE, NOTICE and licenses
(from distrib/). Leaves out everything personal or local: saves, logs, history, traces, glide and walk
measurements, the agent's config, docs/SCOPE.md (the dev log), local.properties and build output. Files the
copy no longer has are removed from the repo folder (its .git stays). Then it searches the copy for personal
markers (account ids, home addresses, character names) and fails if any turns up.
"""
import argparse
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

SHIP = [
    "app/lib", "app/test", "app/assets", "app/android", "app/pubspec.yaml", "app/pubspec.lock",
    "app/analysis_options.yaml", "app/.metadata", "app/.gitignore",
    "agent/agent.py", "agent/start.bat", "agent/install.bat", "agent/requirements.txt",
    "tools/ask.py", "tools/build_agent.py", "tools/build_db.py", "tools/build_map.py", "tools/export_poi.py", "tools/glide.py",
    "tools/history.py", "tools/hunt.py", "tools/icons.py", "tools/ksd.py", "tools/licences_dump.py", "tools/livepos.py", "tools/motion.py", "tools/overlay.py", "tools/paths.py", "tools/release.py",
    "tools/saves.py", "tools/state.py", "tools/world.py", "tools/eml-export", "tools/eml-poi",
    "tools/build_web.py", "tools/webapp.py", "app/web", "tools/pc_text.py", "tools/i18n.py", "tools/ui_strings.py", "tools/export_loca.py", "tools/eml-loca", "tools/i18n",
    # what the agent reads at runtime (tools/state.py, history.py, world.py)
    "data/export/items.jsonl", "data/export/recipes.jsonl", "data/export/skills.jsonl",
    "data/export/item_stats.jsonl", "data/export/balancing.json", "data/export/map/index.tsv",
]
SKIP_DIRS = {"build", "work", ".gradle", ".cxx", ".idea", ".dart_tool", "__pycache__"}  # work: tools/i18n/work, the translators' hand-back files
SKIP_FILES = {"local.properties", "key.properties"}
SKIP_SUFFIXES = {".jks", ".keystore", ".iml", ".pyc"}

# personal markers that must never be in the repo: one per line in release_markers.txt beside tools/ (not
# shipped, so the list itself doesn't publish what it guards)
MARKERS_FILE = ROOT / "release_markers.txt"


def keep(path):
    return not (set(path.parts) & SKIP_DIRS or path.name in SKIP_FILES or path.suffix in SKIP_SUFFIXES)


def public_export(src, dst):
    """A data/export .jsonl as it ships: without the developers' internal names (debug_name) and without
    leftovers the game never uses (_UNUSED, with no name). Everything the agent reads stays."""
    import json

    rows = []
    for line in src.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        r = json.loads(line)
        if "_UNUSED" in (r.get("debug_name") or "") and not r.get("name"):
            continue
        r.pop("debug_name", None)
        rows.append(json.dumps(r, ensure_ascii=False, separators=(",", ":")))
    dst.write_text("\n".join(rows) + "\n", encoding="utf-8")


def copy(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.suffix == ".jsonl" and src.parent.name == "export":
        public_export(src, dst)
    else:
        shutil.copy2(src, dst)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("repo", type=pathlib.Path)
    ap.add_argument("--apk", type=pathlib.Path, required=True)
    a = ap.parse_args()
    out = a.repo.resolve()
    if not (out / ".git").exists():
        sys.exit(f"{out} isn't a git working copy")

    wanted = {}
    for rel in SHIP:
        src = ROOT / rel
        if src.is_dir():
            for f in src.rglob("*"):
                if f.is_file() and keep(f.relative_to(ROOT)):
                    wanted[f.relative_to(ROOT)] = f
        elif src.exists():
            wanted[pathlib.Path(rel)] = src
        else:
            sys.exit(f"missing: {rel}")
    for f in (ROOT / "distrib").rglob("*"):  # README, LICENSE, NOTICE, licenses/, .gitignore
        if f.is_file():
            wanted[f.relative_to(ROOT / "distrib")] = f
    wanted[pathlib.Path("release/enshroudbuddy.apk")] = a.apk.resolve()

    # drop files the release no longer has, keep .git
    for f in sorted(out.rglob("*"), reverse=True):
        rel = f.relative_to(out)
        if rel.parts[0] == ".git":
            continue
        if f.is_file() and rel not in wanted:
            f.unlink()
        elif f.is_dir() and not any(f.iterdir()):
            f.rmdir()
    for rel, src in wanted.items():
        copy(src, out / rel)

    markers = []
    if MARKERS_FILE.exists():
        markers = [m.strip() for m in MARKERS_FILE.read_text(encoding="utf-8").splitlines() if m.strip()]
    else:
        print(f"note: no {MARKERS_FILE.name}, so nothing personal is searched for")
    found = []
    for rel in wanted:
        if rel.suffix in {".apk", ".png", ".jpg", ".ttf", ".webp"}:
            continue
        text = (out / rel).read_text(encoding="utf-8", errors="ignore")
        found += [f"{rel}: {m}" for m in markers if m.lower() in text.lower()]
    if found:
        sys.exit("personal markers in the release:\n  " + "\n  ".join(found))
    size = sum((out / r).stat().st_size for r in wanted) / 1e6
    print(f"{len(wanted)} files, {size:.0f} MB, no personal markers ({len(markers)} searched)")


if __name__ == "__main__":
    main()
