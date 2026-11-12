"""Keen's news about Enshrouded, from Steam's public news feed (ISteamNews, the game's app id only, no key, nothing
about the player), for the app's News: patch notes, test-branch notes for patches to come, plans for later.

The agent asks at most every few hours and keeps the last answer in DATA/news.json, so the phone gets the news with
the PC offline too. Steam's posts are BBCode; they come out as plain text with "# " headings and "- " bullets.
"""
import json
import re
import threading
import time
import urllib.request

from paths import DATA

APP_ID = 1203620
URL = ("https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/"
       f"?appid={APP_ID}&count=40&maxlength=0&feeds=steam_community_announcements")
CACHE = DATA / "news.json"
EVERY_S = 3 * 3600
RETRY_S = 15 * 60

# what a post is, from its title (and Steam's patchnotes tag): notes for a test branch (a patch to come), plans and
# previews (an update to come), patch notes
KINDS = (
    ("test", re.compile(r"playtest|play test|experimental|test branch|public test|beta branch", re.I)),
    ("plan", re.compile(r"roadmap|road map|road to|what'?s next|coming (soon|next|up)|the future|still cooking|"
                        r"dev(eloper)? (update|diary|blog)|sneak peek|preview|changes and additions|plans for|"
                        r"^update \d+:", re.I)),
    ("patch", re.compile(r"changelog|hotfix|patch ?notes|patch #", re.I)),
)


def kind_of(title, tags):
    for k, rx in KINDS:
        if rx.search(title):
            return k
    return "patch" if "patchnotes" in (tags or ()) else "news"


def plain(bb):
    """BBCode (Steam's post markup) to plain text: headings as "# ", list items as "- ", links and images out."""
    s = bb.replace("\r", "")
    s = re.sub(r"\[img[^\]]*\].*?\[/img\]|\[previewyoutube[^\]]*\].*?\[/previewyoutube\]|\[video[^\]]*\].*?\[/video\]",
               "", s, flags=re.I | re.S)
    s = re.sub(r"\[h[1-6][^\]]*\](.*?)\[/h[1-6]\]", lambda m: "\n# " + m.group(1).strip() + "\n", s, flags=re.I | re.S)
    s = re.sub(r"\[/\*\]", "", s)
    s = re.sub(r"\[\*\]\s*", "\n- ", s)
    s = re.sub(r"\[/?(p|list|olist|ul|ol|li)[^\]]*\]", "\n", s, flags=re.I)
    s = re.sub(r"\[url=[^\]]*\](.*?)\[/url\]", r"\1", s, flags=re.I | re.S)
    s = re.sub(r"\[dynamiclink[^\]]*\]\[/dynamiclink\]", "", s, flags=re.I)
    s = re.sub(r"\[/?[a-z0-9]+(=[^\]]*)?\]", "", s, flags=re.I)  # b, i, u, quote, table bits...
    s = re.sub(r"<[^>]+>", "", s)  # some posts are HTML
    s = s.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"').replace("&#39;", "'")
    s = re.sub(r"[ \t]+\n", "\n", s)
    s = re.sub(r"\n- *\n+(?=\S)", "\n- ", s)  # an item whose text starts on the next line
    s = re.sub(r"\n- \s*\n", "\n", s)
    s = "\n".join(line.replace("\xa0", " ").strip() for line in s.split("\n"))
    s = re.sub(r"\n{3,}", "\n\n", s)
    return re.sub(r"\n\n(?=- )", "\n", s).strip()  # a list without gaps


def posts(raw):
    out = []
    for n in raw.get("appnews", {}).get("newsitems", []):
        title = str(n.get("title") or "").strip()
        if not title:
            continue
        out.append({"id": str(n.get("gid") or n.get("url")), "date": int(n.get("date") or 0), "title": title[:200],
                    "kind": kind_of(title, n.get("tags")), "url": str(n.get("url") or ""),
                    "text": plain(str(n.get("contents") or ""))[:60000]})
    return out


class News:
    """The latest posts, fetched in the background when asked for and stale; json() answers at once."""

    def __init__(self):
        self.lock = threading.Lock()
        self.data = None
        self.tried = 0.0
        self.busy = False
        try:
            self.data = json.loads(CACHE.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            pass

    def _fetch(self):
        try:
            req = urllib.request.Request(URL, headers={"User-Agent": "EnshroudBuddy"})
            with urllib.request.urlopen(req, timeout=20) as r:
                got = posts(json.loads(r.read()))
            if got:
                data = {"at": int(time.time()), "posts": got}
                with self.lock:
                    self.data = data
                CACHE.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        except (OSError, ValueError):
            pass  # offline or Steam down: the last answer stays
        finally:
            self.busy = False

    def json(self):
        with self.lock:
            data = self.data
            stale = data is None or time.time() - data.get("at", 0) > EVERY_S
            if stale and not self.busy and time.time() - self.tried > RETRY_S:
                self.busy, self.tried = True, time.time()
                threading.Thread(target=self._fetch, daemon=True).start()
        return json.dumps({**(data or {"at": 0, "posts": []}), "fetching": self.busy}, ensure_ascii=False).encode()
