"""A hunt run on the PC (POST /hunt), so it keeps moving on while the phone sleeps in a pocket.

The phone sends the places still missing (lore pages, unique loot: it knows what the save holds); with each
live position the agent leads to the nearest, and once you've been there (closer than ARRIVED_M) and walked
on (LEFT_M away), to the next. The phone reads where the hunt is (GET /pos, "hunt") when it wakes. Same rules
as the app's own hunt (app/lib/data/hunt.dart), which runs when the agent has none.
"""
import math

ARRIVED_M = 15.0  # the guide's "You're there"
LEFT_M = 30.0  # this far from a reached place counts as moved on
SWITCH_M, SWITCH_SHARE = 150.0, 0.5  # another place takes over only when this much nearer
MAX_PLACES = 3000


def _key(x, y):
    return (round(x, 1), round(y, 1))


class Hunt:
    def __init__(self):
        self.places = []  # [{"title", "x", "y", "h"}]
        self.m = 8.0  # metres per map pixel
        self.passed = set()  # place keys visited this hunt (the save may not know yet)
        self.cur = None
        self.reached = False

    @property
    def on(self):
        return bool(self.places) or self.cur is not None

    def set(self, req):
        """A new list from the phone (checked), or {} to stop. A list for the same hunt keeps what was
        visited; the place being led to stays unless the list dropped it (had, or skipped on the phone)."""
        places = []
        for p in list(req.get("places") or [])[:MAX_PLACES]:
            x, y = float(p[0]), float(p[1])
            h = None if p[2] is None else float(p[2])
            if not all(map(math.isfinite, [x, y] + ([] if h is None else [h]))):
                raise ValueError("bad place")
            places.append({"title": str(p[3] or "")[:80], "x": x, "y": y, "h": h})
        if not places:
            self.stop()
            return
        if req.get("new"):
            self.passed.clear()
        m = float(req.get("m") or 8.0)
        self.m = m if math.isfinite(m) and 0 < m < 100 else 8.0
        self.places = places
        keys = {_key(p["x"], p["y"]) for p in places}
        if self.cur and _key(self.cur["x"], self.cur["y"]) not in keys:
            self.cur, self.reached = None, False

    def stop(self):
        self.places, self.cur, self.reached = [], None, False
        self.passed.clear()

    def _metres(self, p, x, y):
        return math.hypot(p["x"] - x, p["y"] - y) * self.m

    def step(self, pos):
        """With a live position: move on if the place was visited, pick the nearest left. Returns the place
        to lead to (the overlay's target), or None when none is left."""
        if not self.places or not pos:
            return self.cur
        x, y = pos["map"][0], pos["map"][1]
        if self.cur:
            d = self._metres(self.cur, x, y)
            if d < ARRIVED_M:
                self.reached = True
            if self.reached and d > LEFT_M:
                self.passed.add(_key(self.cur["x"], self.cur["y"]))
                self.cur, self.reached = None, False
        open_ = [p for p in self.places if _key(p["x"], p["y"]) not in self.passed]
        if not open_:
            self.stop()
            return None
        best = min(open_, key=lambda p: self._metres(p, x, y))
        if self.cur and best is not self.cur:
            now, d = self._metres(self.cur, x, y), self._metres(best, x, y)
            if now - d < SWITCH_M or d > now * SWITCH_SHARE:
                best = self.cur
        if best is not self.cur:
            self.cur, self.reached = best, False
        return self.cur

    def status(self):
        """For the phone: the place led to, how many are left, what was visited."""
        if not self.on:
            return None
        left = sum(1 for p in self.places if _key(p["x"], p["y"]) not in self.passed)
        return {"cur": None if not self.cur else [self.cur["x"], self.cur["y"]], "left": left,
                "passed": [list(k) for k in self.passed]}


if __name__ == "__main__":
    h = Hunt()
    h.set({"new": True, "m": 8, "places": [[0, 0, None, "a"], [10, 0, None, "b"], [100, 0, 5, "c"]]})
    assert h.step({"map": [1, 0]})["title"] == "a"
    h.step({"map": [0.5, 0]})  # there
    assert h.step({"map": [5, 0]})["title"] == "b"  # 40 m on: next
    assert h.status()["left"] == 2 and h.status()["passed"] == [[0.0, 0.0]]
    h.set({"m": 8, "places": [[0, 0, None, "a"], [100, 0, 5, "c"]]})  # b had: dropped
    assert h.cur is None and h.step({"map": [5, 0]})["title"] == "c"
    h.step({"map": [100, 0]})
    assert h.step({"map": [200, 0]}) is None and not h.on  # all done
    print("ok")
