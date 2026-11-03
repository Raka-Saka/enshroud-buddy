"""Export map points (labels, lore notes, loot chests) from the game, in chunk batches.

    python tools/export_poi.py --emm path/to/emm.exe [--game H:/.../Enshrouded] [--export data/export]

Installs tools/eml-poi as <game>/mods/ensh_companion_poi, then runs `emm run --export` once per
100 entity chunks, fewer where they are dense (a single run exhausts mlua's reference slots). While it runs, skip.txt in the
main export mod's folder makes that mod sit out. Writes data/export/poi.tsv:
category, template, label, extra, x, y, z (save half-metre units), visible query, completed query, area levels;
and data/export/gather.tsv: template, item ids, cell x, cell y (128 m cells), count, area level;
census.tsv (every entity by template and cell), inside.tsv (the Hollow Halls' insides), templates.tsv,
fish_tables.tsv and marker_types.tsv (see the mod's header). poi.tsv has an 11th column, "more".
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import saves as saves_mod  # noqa: E402

# the default Steam library; pass --game for another one
GAME = saves_mod.steam_dir() / "steamapps" / "common" / "Enshrouded"
BATCH = 100


def run(emm, game, out, first, last, mod):
    (mod / "job.txt").write_text(f"{first} {last}", encoding="utf-8")
    r = subprocess.run([str(emm), "run", "--export", "-g", str(game), "--export-directory", str(out)],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    m = re.search(r"poi chunks \d+-\d+ of (\d+): (\d+) points", r.stdout + r.stderr)
    if not m and "out of auxiliary stack space" in r.stdout + r.stderr and last > first:
        return None  # too many entities for one run: the caller halves the batch
    if not m:
        sys.exit(f"batch {first}-{last} failed:\n{(r.stdout + r.stderr)[-1500:]}")
    return int(m.group(1)), int(m.group(2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emm", type=pathlib.Path, required=True)
    ap.add_argument("--game", type=pathlib.Path, default=GAME)
    ap.add_argument("--export", type=pathlib.Path, default=ROOT / "data" / "export")
    a = ap.parse_args()

    mod = a.game / "mods" / "ensh_companion_poi"
    shutil.copytree(ROOT / "tools" / "eml-poi", mod, dirs_exist_ok=True)
    skip = a.game / "mods" / "ensh_companion_export" / "skip.txt"
    if skip.parent.exists():
        skip.write_text("poi export running", encoding="utf-8")
    try:
        with tempfile.TemporaryDirectory(prefix="ensh_poi_") as tmp:
            out = pathlib.Path(tmp)
            first, total, points, size = 1, None, 0, BATCH
            while total is None or first <= total:
                got = run(a.emm, a.game, out, first, first + size - 1, mod)
                if got is None:
                    size = max(1, size // 2)
                    continue
                total, n = got
                points += n
                print(f"chunks {first}-{min(first + size - 1, total)} of {total}: {n} points")
                first += size
                size = min(BATCH, size * 2)
            rows = [line for f in sorted((out / "poi").glob("*.tsv")) for line in f.read_text(encoding="utf-8").splitlines() if line]
            (a.export / "poi.tsv").write_text("\n".join(rows) + "\n", encoding="utf-8")
            print(f"{a.export / 'poi.tsv'}: {len(rows)} points")
            cells = [line for f in sorted((out / "gather").glob("*.tsv")) for line in f.read_text(encoding="utf-8").splitlines() if line]
            (a.export / "gather.tsv").write_text("\n".join(cells) + "\n", encoding="utf-8")
            print(f"{a.export / 'gather.tsv'}: {len(cells)} gather cells")
            for part in ("census", "inside"):
                lines = [line for f in sorted((out / part).glob("*.tsv")) for line in f.read_text(encoding="utf-8").splitlines() if line]
                if part == "census":  # a cell can span two batches
                    merged = {}
                    for line in lines:
                        key, n = line.rsplit("\t", 1)
                        merged[key] = merged.get(key, 0) + int(n)
                    lines = [f"{k}\t{n}" for k, n in sorted(merged.items())]
                (a.export / f"{part}.tsv").write_text("\n".join(lines) + "\n", encoding="utf-8")
                print(f"{a.export / (part + '.tsv')}: {len(lines)} rows")
            for name in ("templates.tsv", "fish_tables.tsv", "marker_types.tsv"):
                if (out / name).exists():
                    shutil.copyfile(out / name, a.export / name)
    finally:
        (mod / "job.txt").unlink(missing_ok=True)
        skip.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
