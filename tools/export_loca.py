"""Export the game's text in every language it ships, for the app's translations.

    python tools/export_loca.py --emm path/to/emm.exe [--game H:/.../Enshrouded] [--export data/export]

Installs tools/eml-loca as <game>/mods/ensh_companion_loca and runs `emm run --export` once, with the main
export mod sitting out (skip.txt). Writes data/export/loca/<language>.jsonl and languages.txt.
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import saves as saves_mod  # noqa: E402

GAME = saves_mod.steam_dir() / "steamapps" / "common" / "Enshrouded"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emm", type=pathlib.Path, required=True)
    ap.add_argument("--game", type=pathlib.Path, default=GAME)
    ap.add_argument("--export", type=pathlib.Path, default=ROOT / "data" / "export")
    a = ap.parse_args()

    mod = a.game / "mods" / "ensh_companion_loca"
    shutil.copytree(ROOT / "tools" / "eml-loca", mod, dirs_exist_ok=True)
    skip = a.game / "mods" / "ensh_companion_export" / "skip.txt"
    if skip.parent.exists():
        skip.write_text("loca export running", encoding="utf-8")
    (mod / "job.txt").write_text("all", encoding="utf-8")
    try:
        with tempfile.TemporaryDirectory(prefix="ensh_loca_") as tmp:
            r = subprocess.run([str(a.emm), "run", "--export", "-g", str(a.game), "--export-directory", tmp],
                               capture_output=True, text=True, encoding="utf-8", errors="replace")
            log = r.stdout + r.stderr
            if not re.search(r"loca: \d+ languages", log):
                sys.exit(f"loca export failed:\n{log[-1500:]}")
            out = a.export / "loca"
            shutil.rmtree(out, ignore_errors=True)
            shutil.copytree(pathlib.Path(tmp) / "loca", out)
            print((out / "languages.txt").read_text(encoding="utf-8"))
    finally:
        (mod / "job.txt").unlink(missing_ok=True)
        skip.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
