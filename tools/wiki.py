"""A local copy of the Enshrouded wiki (enshrouded.wiki.gg) for Ask: agent/ask/wiki/*.txt, one file per article,
so answers Grep it instead of searching the web (faster, the same every time).

    python tools/wiki.py            # fetch when the copy is older than a week
    python tools/wiki.py --force

The MediaWiki API gives 50 articles per request with their wikitext; requests go a second apart (about 90 for
the ~4300 articles). The text is the wiki's (CC BY-SA); the copy stays on this PC. Each file starts with the
title, the page's address and when it was last edited, then the wikitext lightly cleaned: links become their
text, references, comments and images go, templates stay (infobox fields such as drops and locations are
useful as they are).
"""
import argparse
import json
import pathlib
import re
import shutil
import sys
import time
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
from paths import DATA  # noqa: E402
OUT = DATA / "ask" / "wiki"
API = "https://enshrouded.wiki.gg/api.php"
SITE = "https://enshrouded.wiki.gg/wiki/"
UA = "EnshroudedCompanion/0.17 (personal companion app; local wiki copy, weekly)"
MAX_AGE_DAYS = 7


def fetched_at():
    stamp = OUT / ".fetched"
    return stamp.stat().st_mtime if stamp.exists() else 0


def stale():
    return time.time() - fetched_at() > MAX_AGE_DAYS * 86400


def _get(params):
    url = API + "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Encoding": "identity"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read().decode("utf-8"))
        except Exception:
            if attempt == 3:
                raise
            time.sleep(5 * (attempt + 1))


def pages():
    """(title, timestamp, wikitext) for every article, redirects left out."""
    params = {
        "action": "query", "format": "json", "formatversion": "2",
        "generator": "allpages", "gapnamespace": "0", "gapfilterredir": "nonredirects", "gaplimit": "50",
        "prop": "revisions", "rvprop": "content|timestamp", "rvslots": "main",
    }
    cont = {}
    while True:
        j = _get({**params, **cont})
        for p in (j.get("query") or {}).get("pages", []):
            rev = (p.get("revisions") or [{}])[0]
            text = ((rev.get("slots") or {}).get("main") or {}).get("content")
            if text:
                yield p["title"], rev.get("timestamp", ""), text
        if "continue" not in j:
            return
        cont = j["continue"]
        time.sleep(1)


_LINK = re.compile(r"\[\[([^\[\]|]*)(?:\|([^\[\]]*))?\]\]")


def clean(text):
    """Wikitext made readable for Grep: categories kept as one line, links as their text."""
    cats = re.findall(r"\[\[Category:([^\]|]+)", text)
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    text = re.sub(r"<ref[^>]*/>|<ref[^>]*>.*?</ref>", "", text, flags=re.S)
    # images and categories (an image caption can hold links: drop them from the inside out)
    for _ in range(3):
        text = re.sub(r"\[\[(?:File|Image|Category):[^\[\]]*\]\]", "", text)
    text = _LINK.sub(lambda m: m.group(2) if m.group(2) is not None else m.group(1), text)
    text = re.sub(r"'{2,}", "", text)
    text = re.sub(r"<br\s*/?>", "\n", text)
    text = re.sub(r"</?[a-zA-Z][^>]*>", "", text)
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    if cats:
        text += "\n\nCategories: " + ", ".join(dict.fromkeys(c.strip() for c in cats))
    return text


def file_name(title):
    return re.sub(r"[^A-Za-z0-9 _().,'&+-]", "_", title)[:120].strip() + ".txt"


def fetch(force=False, log=print):
    """Refresh agent/ask/wiki/ when it is older than a week (or forced). Returns the article count, or None."""
    if not force and not stale():
        return None
    tmp = OUT.with_name("wiki.tmp")
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    n, seen = 0, set()
    for title, ts, text in pages():
        name = file_name(title)
        if name.lower() in seen:
            name = name[:-4] + f" ({n}).txt"
        seen.add(name.lower())
        head = f"# {title}\n({SITE}{urllib.parse.quote(title.replace(' ', '_'))}, edited {ts[:10]})\n\n"
        (tmp / name).write_text(head + clean(text) + "\n", encoding="utf-8")
        n += 1
    if n < 100:  # something went wrong: keep the old copy
        shutil.rmtree(tmp, ignore_errors=True)
        raise RuntimeError(f"only {n} wiki articles came back")
    (tmp / ".fetched").write_text(time.strftime("%Y-%m-%dT%H:%M:%S"), encoding="utf-8")
    shutil.rmtree(OUT, ignore_errors=True)
    tmp.rename(OUT)
    log(f"wiki: {n} articles")
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    n = fetch(a.force)
    print("up to date" if n is None else f"{n} articles in {OUT}")


if __name__ == "__main__":
    sys.exit(main())
