"""Glide calibration from the live position: how far the equipped glider carries per metre of height lost,
and how fast, measured from the player's own glides (the game data only gives Speed and Range).

A one-second step counts as gliding when the player crosses 9 to 40 m/s of ground while sinking 0.3 to
12 m/s, at least 3 m above the map's ground (tools/motion.py; so a run downhill doesn't count); four or more
such steps in a row make a glide. A rising step (an air stream, Updraft) or a stop
ends the glide, so lift never flatters the ratio. Totals are kept per glider in agent/glide.json.
"""
import json
import math


class GlideLog:
    MIN_STEPS = 4
    MIN_SECONDS = 10  # of gliding before the numbers are given out

    def __init__(self, path, log=print):
        self.path, self.log = path, log
        try:
            self.data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            self.data = {}
        self.prev = None
        self.run = []

    def add(self, pos, t, glider, above=None):
        """One live reading (tools/livepos.py, metres) at time t, with the equipped glider's item id and the
        feet's height over the ground when known."""
        prev, self.prev = self.prev, (pos, t)
        if prev is None or glider is None or pos is None:
            self._end(glider)
            return
        p0, t0 = prev
        dt = t - t0
        if not 0.5 <= dt <= 3:
            self._end(glider)
            return
        across = math.hypot(pos["x"] - p0["x"], pos["z"] - p0["z"]) / dt
        sink = (p0["y"] - pos["y"]) / dt
        if 9 <= across <= 40 and 0.3 <= sink <= 12 and (above is None or above >= 3):
            self.run.append((across * dt, sink * dt, dt))
        else:
            self._end(glider)

    def _end(self, glider):
        run, self.run = self.run, []
        if glider is None or len(run) < self.MIN_STEPS:
            return
        g = self.data.setdefault(glider, {"dist": 0.0, "drop": 0.0, "seconds": 0.0, "glides": 0})
        g["dist"] += sum(r[0] for r in run)
        g["drop"] += sum(r[1] for r in run)
        g["seconds"] += sum(r[2] for r in run)
        g["glides"] += 1
        try:
            self.path.write_text(json.dumps(self.data, indent=1), encoding="utf-8")
        except OSError:
            pass
        self.log(f"glide: {sum(r[0] for r in run):.0f} m for {sum(r[1] for r in run):.0f} m drop "
                 f"in {sum(r[2] for r in run):.0f} s (ratio so far {g['dist'] / g['drop']:.1f})")

    def info(self, glider):
        """{"ratio", "speed", "seconds", "glides"} for the glider once it has been flown enough, else None."""
        g = self.data.get(glider or "")
        if not g or g["seconds"] < self.MIN_SECONDS or g["drop"] <= 0:
            return None
        return {"ratio": round(g["dist"] / g["drop"], 2), "speed": round(g["dist"] / g["seconds"], 1),
                "seconds": round(g["seconds"]), "glides": g["glides"]}
