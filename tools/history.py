"""Progress over time: one small snapshot per game save, for the app's timeline.

The agent appends a snapshot whenever a rebuilt state differs from the last one, and on first start
backfills from the game's own rolling backups (<save folder>/backup/*.ksd.backup-0..9).

    python tools/history.py [--saves DIR] [--world 1] [--character 1]   # print the backfill
"""
import argparse
import json
import pathlib
import shutil
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import state as state_mod  # noqa: E402
from ksd import Save  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent


def skill_point_flags(export):
    """Knowledge ids that grant skill points: (Shroud Root ids, Elixir Well ids)."""
    path = export / "balancing.json"
    if not path.exists():
        return set(), set()
    b = json.loads(path.read_text(encoding="utf-8"))
    roots, wells = set(), set()
    for u in b.get("skill_point_unlocks", []):
        kid, n = u.split(":")
        (wells if n == "3" else roots).add(kid)
    return roots, wells


def snapshot(st, export):
    """The numbers the timeline tracks, from one state (tools/state.py output)."""
    c, w = st["character"], st["world"]
    known = set(c.get("knowledge") or []) | set(w.get("knowledge") or [])
    roots, wells = skill_point_flags(export)
    return {
        "t": c.get("saved_at"),
        "level": c.get("level", 0),
        "xp": c.get("xp", 0),
        "flame": w.get("flame_level", 0),
        "skills": len(c.get("skills") or []),
        "ranks": sum(s.get("level", 0) for s in c.get("skills") or []),
        "recipes": len(c.get("recipes_unlocked") or []),
        "knowledge": len(known),
        "roots": len(known & roots),
        "wells": len(known & wells),
        "bases": [[b.get("name") or b["id"], b.get("altar_level") or 0] for b in w.get("bases") or []],
        "worn": sorted(o["item"] for o in c.get("equipment") or [] if not o.get("cosmetic")),
    }


def same(a, b):
    """Equal apart from the time."""
    return a is not None and b is not None and {k: v for k, v in a.items() if k != "t"} == {
        k: v for k, v in b.items() if k != "t"
    }


def backfill(saves, world, character, export):
    """Snapshots from the game's backups, oldest first: each character backup with the world backup saved
    closest to it. Backups too small to hold a character are skipped."""
    folder = saves / "backup"
    chars = sorted(folder.glob(f"character{character}.ksd.backup-*"), key=lambda f: f.stat().st_mtime)
    worlds = list(folder.glob(f"world{world}.ksd.backup-*"))
    out = []
    for cf in chars:
        if cf.stat().st_size < 2048 or not worlds:
            continue
        wf = min(worlds, key=lambda f: abs(f.stat().st_mtime - cf.stat().st_mtime))
        with tempfile.TemporaryDirectory(prefix="ensh_hist_") as tmp:
            tmp = pathlib.Path(tmp)
            shutil.copy2(cf, tmp / f"character{character}.ksd")
            shutil.copy2(wf, tmp / f"world{world}.ksd")
            try:
                snap = snapshot(state_mod.build(tmp, world, character, export), export)
            except Exception:  # a backup from another game version, or half written
                continue
        if not out or not same(out[-1], snap):
            out.append(snap)
    return out


class History:
    """agent/history.jsonl: snapshots oldest first, one per line."""

    def __init__(self, path):
        self.path = pathlib.Path(path)
        self.rows = []
        if self.path.exists():
            for line in self.path.read_text(encoding="utf-8").splitlines():
                try:
                    self.rows.append(json.loads(line))
                except ValueError:
                    pass

    def add(self, snap):
        """Append if anything but the time changed; returns whether it did."""
        if self.rows and same(self.rows[-1], snap):
            return False
        self.rows.append(snap)
        with self.path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(snap, separators=(",", ":")) + "\n")
        return True

    def seed(self, snaps):
        """First start: write the backfill, then whatever is already recorded after it."""
        if self.rows:
            return
        for s in snaps:
            self.add(s)

    def json(self):
        return json.dumps(self.rows, separators=(",", ":")).encode("utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--saves", type=pathlib.Path, default=state_mod.STEAM_SAVES)
    ap.add_argument("--world", type=int, default=1)
    ap.add_argument("--character", type=int, default=1)
    ap.add_argument("--export", type=pathlib.Path, default=ROOT / "data" / "export")
    a = ap.parse_args()
    for s in backfill(a.saves, a.world, a.character, a.export):
        print({k: v for k, v in s.items() if k not in ("worn", "bases")}, len(s["bases"]), "bases")


if __name__ == "__main__":
    main()
