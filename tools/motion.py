"""On foot or in the air, from the live position (tools/livepos.py) once a second.

Each reading is compared with the one about two seconds before it: metres a second across the ground and
up or down, the direction of travel, and how high the feet are above the game's height map
(app/assets/height.png; 16 m steps, so a few metres off, more on ridges and cliffs). The mode:
  "fall"  sinking faster than 12 m/s, off the ground (a glider sinks about 1 to 8)
  "air"   sinking while crossing 10 m/s or more, or 5 m/s or more well above the ground (12 m): a glide;
          or rising 5 m/s or more above the ground: an updraft
  "foot"  anything else: walking, running, standing, a roof or a spire's platform, stairs
A new mode is taken once two readings in a row agree (a fall at once), so a jump or a slide doesn't
flicker. The thresholds are first guesses; agent/trace.jsonl keeps the readings to check them against.

Also measured: the walking speed, from steps on foot at 2 to 12 m/s, for the guide's walk times.
"""
import json
import math
from collections import deque

CAMERA = 3.0  # metres from the camera down to the feet


class HeightMap:
    """The ground in metres at a map pixel, as the app reads it (lib/data/guide.dart)."""

    def __init__(self, png, fit):
        from PIL import Image

        img = Image.open(png).convert("L")
        self.size = img.width
        self.v = img.tobytes()
        f = json.loads(fit.read_text(encoding="utf-8"))
        self.per, self.off = f["m_per_step"], f["offset_m"]

    def at(self, x, y):
        n = self.size
        u = min(max(x - 0.5, 0.0), n - 1.001)
        v = min(max(y - 0.5, 0.0), n - 1.001)
        u0, v0 = int(u), int(v)
        fu, fv = u - u0, v - v0
        h = self.v
        raw = (h[v0 * n + u0] * (1 - fu) * (1 - fv) + h[v0 * n + u0 + 1] * fu * (1 - fv)
               + h[(v0 + 1) * n + u0] * (1 - fu) * fv + h[(v0 + 1) * n + u0 + 1] * fu * fv)
        return raw * self.per + self.off


class Motion:
    def __init__(self, ground=None, path=None):
        self.ground = ground  # HeightMap or None
        self.path = path  # walking totals, {"dist", "seconds"}
        self.hist = deque(maxlen=3)
        self.mode, self.pending = "foot", None
        try:
            self.walk = json.loads(path.read_text(encoding="utf-8"))
        except (AttributeError, OSError, ValueError):
            self.walk = {"dist": 0.0, "seconds": 0.0}
        self.unsaved = 0.0

    def add(self, pos, t):
        """One reading (metres, with "map") at time t: {"mode", "speed", "vs", "course", "above"}, or None
        when there is no reading."""
        if pos is None:
            self.hist.clear()
            self.mode, self.pending = "foot", None
            return None
        above = None
        if self.ground is not None:
            above = round(pos["y"] - CAMERA - self.ground.at(*pos["map"]), 1)
        prev = self.hist[-1] if self.hist else None
        old = next(((t0, p0) for t0, p0 in self.hist if 0.8 <= t - t0 <= 3.5), None)
        self.hist.append((t, pos))
        if old is None:
            return {"mode": self.mode, "speed": 0.0, "vs": 0.0, "course": None, "above": above}
        t0, p0 = old
        dt = t - t0
        dx, dz = pos["x"] - p0["x"], pos["z"] - p0["z"]
        across = math.hypot(dx, dz) / dt
        vs = (pos["y"] - p0["y"]) / dt
        step = self.classify(across, vs, above)
        if step == "fall" or step == self.pending:
            self.mode = step
        self.pending = step
        if self.mode == "foot" and prev is not None and 0.5 <= t - prev[0] <= 2:
            d = math.hypot(pos["x"] - prev[1]["x"], pos["z"] - prev[1]["z"])
            s = t - prev[0]
            if 2 <= d / s <= 12 and abs(pos["y"] - prev[1]["y"]) / s < 4:
                self.walk["dist"] += d
                self.walk["seconds"] += s
                self.unsaved += s
                if self.unsaved >= 30 and self.path is not None:
                    self.unsaved = 0.0
                    try:
                        self.path.write_text(json.dumps(self.walk), encoding="utf-8")
                    except OSError:
                        pass
        return {"mode": self.mode, "speed": round(across, 1), "vs": round(vs, 1),
                "course": round(math.degrees(math.atan2(dx, dz)) % 360) if across >= 1 else None,
                "above": above}

    @staticmethod
    def classify(across, vs, above):
        sink = -vs
        high = above is not None and above >= 12
        if sink > 12 and (above is None or above > 4):  # on the ground it is a steep slope
            return "fall"
        if sink >= 0.8 and (across >= 10 or (across >= 5 and high)):
            return "air"
        if vs >= 5 and above is not None and above >= 8:
            return "air"
        return "foot"

    def walk_speed(self):
        """Metres a second on foot, None under a minute of walking."""
        s = self.walk["seconds"]
        return round(self.walk["dist"] / s, 1) if s >= 60 else None


class Trace:
    """The last few hours of live readings, one JSON line each, to check the modes against real play."""

    LIMIT = 3_000_000  # bytes; then the older half goes

    def __init__(self, path):
        self.path = path

    def add(self, rec):
        try:
            with self.path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(rec, separators=(",", ":")) + "\n")
            if self.path.stat().st_size > self.LIMIT:
                lines = self.path.read_text(encoding="utf-8").splitlines(keepends=True)
                self.path.write_text("".join(lines[len(lines) // 2:]), encoding="utf-8")
        except OSError:
            pass
