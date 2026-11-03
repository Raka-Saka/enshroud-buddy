"""Enshroud Buddy PC agent: watches the saves and serves the live state on the LAN.

    pythonw agent/agent.py                  # tray app (what agent.bat runs at login)
    python agent/agent.py --console         # no tray, log to the console
    python agent/agent.py --install-autostart | --uninstall-autostart

Endpoints (port 4750):
    GET /state      full state JSON (tools/state.py), rebuilt within seconds of a game save
    GET /health     {"ok", "built_at", "saved_at", "error", "warnings"}
    GET /saves      every save folder on this PC with its worlds and characters (tools/saves.py), and the
                    one being read: {"folders": [{"folder", "label", "worlds", "characters"}], "current":
                    {"folder", "world", "character"}}
    POST /select    {"folder", "world", "character"}: read that world and character from now on (kept in
                    agent/config.json); LAN clients only
    GET /fog.png    explored map, 1280x1280, white = explored
    GET /fog_overlay.png  the same as a dark veil over unexplored ground (RGBA), for the app's map
    GET /history    progress snapshots, oldest first (agent/history.jsonl, seeded from the game's backups)
    GET /db/version {"built"} of the game data the phone should use (app/assets/game.json, from tools/build_db.py)
    GET /db         that game data, so data fixes reach the phone without reinstalling the app
    GET /pos        where the player is right now, read from the running game's memory (tools/livepos.py,
                    read-only), once a second: {"live": true, "x", "y", "z" (metres), "heading" (degrees,
                    0 = north), "map" [x, y on the 1280 px map], "at", "glider" (item id), "glide" {"ratio",
                    "speed", "seconds", "glides"} once a few glides are measured (tools/glide.py), and from
                    tools/motion.py "mode" ("foot", "air", "fall"), "speed" and "vs" (m/s across, and up),
                    "course" (degrees of travel), "above" (metres over the map's ground), "walk" {"speed"}}
                    or {"live": false}
    POST /ask       {"q", "session"?, "context"?} -> {"answer", "session", "seconds"}: headless Claude Code on this
                    PC (tools/ask.py), read-only over the live character and the game data; LAN clients only
    POST /ask/stream  the same, answered as it is written: one JSON object per line ({"status"}, {"reset"},
                    {"delta"}, then {"done", "answer", "session", "seconds"} or {"error"})

The agent never writes to the save folder: it copies the files it reads into a temp folder first.
"""
import argparse
import io
import json
import math
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import ask as ask_mod  # noqa: E402
import glide as glide_mod  # noqa: E402
import history as history_mod  # noqa: E402
import livepos as livepos_mod  # noqa: E402
import motion as motion_mod  # noqa: E402
import saves as saves_mod  # noqa: E402
import state as state_mod  # noqa: E402
import wiki as wiki_mod  # noqa: E402
from ksd import Save  # noqa: E402

PORT = 4750
POLL_SECONDS = 3
SETTLE_SECONDS = 2  # the game writes several files per save; wait for them to settle


class Agent:
    def __init__(self, saves, world, character, export):
        self.saves, self.world, self.character, self.export = saves, world, character, export
        self.lock = threading.Lock()
        self.state_json = b"{}"
        self.fog_png = b""
        self.fog_overlay_png = b""
        self.health = {"ok": False, "built_at": None, "saved_at": None, "error": "not built yet"}
        self.last_sig = None
        self.history = history_mod.History(history_path(saves, world, character))
        self.pos = None  # live position, None while the game isn't running
        self.glider = None  # the equipped glider's item id, for the glide calibration
        self.glides = glide_mod.GlideLog(ROOT / "agent" / "glide.json", log=log)
        try:
            ground = motion_mod.HeightMap(ROOT / "app" / "assets" / "height.png", ROOT / "app" / "assets" / "height.json")
        except (OSError, ValueError, KeyError):
            ground = None
        self.motion = motion_mod.Motion(ground, ROOT / "agent" / "walk.json")
        self.trace = motion_mod.Trace(ROOT / "agent" / "trace.jsonl")
        self.bases = []  # [name, map x, map y] for Ask's "nearest base"

    def files(self):
        return [self.saves / f"world{self.world}.ksd", self.saves / f"character{self.character}.ksd"]

    def signature(self):
        try:
            return tuple((f.stat().st_mtime_ns, f.stat().st_size) for f in self.files())
        except OSError:
            return None

    def rebuild(self):
        with tempfile.TemporaryDirectory(prefix="ensh_agent_") as tmp:
            tmp = pathlib.Path(tmp)
            for f in self.files():
                shutil.copy2(f, tmp / f.name)
            st = state_mod.build(tmp, self.world, self.character, self.export)
            if self.history.add(history_mod.snapshot(st, self.export)):
                log(f"history: {len(self.history.rows)} snapshots")
            try:
                ask_mod.write_me(st)  # what the assistant knows about the character
            except Exception:
                log("me.md failed:\n" + traceback.format_exc())
            fog, veil = render_fog(Save(tmp / f"character{self.character}.ksd"))
        data = json.dumps(st, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        gliders = _gliders()  # read each time, so a game data update counts at once
        with self.lock:
            self.state_json, self.fog_png, self.fog_overlay_png = data, fog, veil
            self.glider = next((o["item"] for o in st["character"].get("equipment", [])
                                if o["item"] in gliders and not o.get("cosmetic")), None)
            self.bases = [[b.get("name") or "an unnamed base", *b["map"]] for b in st["world"]["bases"]
                          if b.get("pieces") or b.get("placed")]
            self.health = {
                "ok": True,
                "built_at": st["built_at"],
                "saved_at": st["character"]["saved_at"],
                "character": st["character"]["name"],
                "world": st["world"]["name"],
                "error": None,
                "warnings": st.get("warnings", []),  # what the save reader met but couldn't read (tools/state.py)
            }
        log(f"state rebuilt: {self.health['character']} @ {self.health['world']}, saved {self.health['saved_at']}")
        for w in st.get("warnings", []):
            log(f"save reader warning: {w}")

    def wiki(self, stop):
        """Keep Ask's copy of the wiki at most a week old (checked daily); only where Ask can run (Claude Code
        installed), as nothing else reads it."""
        while not stop.is_set():
            try:
                if ask_mod.claude_cmd():
                    wiki_mod.fetch(log=log)
            except Exception as e:
                log(f"wiki refresh failed: {e}")
            stop.wait(86400)

    def live(self, stop):
        """Read the player's position from the running game once a second."""
        lp, failed = livepos_mod.LivePos(log=log), False
        while not stop.is_set():
            try:
                pos = lp.poll()
                failed = False
            except Exception:
                if not failed:
                    log("live position failed:\n" + traceback.format_exc())
                failed, pos = True, None
                lp.close()
            now = time.time()
            mo = self.motion.add(pos, now)
            self.glides.add(pos, now, self.glider, above=mo and mo["above"])
            if pos:
                self.trace.add({"t": round(now, 1), **{k: round(pos[k], 2) for k in ("x", "y", "z")},
                                "h": round(pos["heading"]), **mo})
                pos = {**pos, **mo, "at": time.strftime("%Y-%m-%dT%H:%M:%S"), "glider": self.glider}
                walk = self.motion.walk_speed()
                if walk:
                    pos["walk"] = {"speed": walk}
                glide = self.glides.info(self.glider)
                if glide:
                    pos["glide"] = glide
            with self.lock:
                self.pos = pos
            stop.wait(1)

    def live_for_ask(self):
        with self.lock:
            return {**self.pos, "bases": self.bases} if self.pos else None

    def select(self, folder, world, character):
        """Read another world and character from now on (the phone's setup, POST /select)."""
        # only a folder the agent found itself (tools/saves.py): a path from the network, say \\host\share,
        # would make Windows connect out (and offer the user's credentials) before any check
        # compared as text (normpath, normcase): the asked path itself is never opened or resolved
        want = os.path.normcase(os.path.normpath(str(folder)))
        folder = next((f for f in saves_mod.folders() if os.path.normcase(os.path.normpath(str(f))) == want), None)
        if folder is None:
            raise ValueError("not a save folder on this PC")
        if not (folder / f"world{world}.ksd").exists() or not (folder / f"character{character}.ksd").exists():
            raise ValueError("no such world or character in that folder")
        with self.lock:
            self.saves, self.world, self.character = folder, int(world), int(character)
            self.history = history_mod.History(history_path(folder, world, character))
            self.health = {"ok": False, "built_at": None, "saved_at": None, "error": "switching saves"}
            self.last_sig = None  # the watch loop rebuilds within seconds
        save_config(folder, world, character)
        log(f"reading world{world} and character{character} in {folder}")

    def seed_history(self):
        """A new world and character: start their timeline from what the game's own backups remember (once)."""
        if self.history.rows or getattr(self.history, "tried_seed", False):
            return
        self.history.tried_seed = True
        try:
            self.history.seed(history_mod.backfill(self.saves, self.world, self.character, self.export))
            log(f"history seeded from backups: {len(self.history.rows)} snapshots")
        except Exception:
            log("history backfill failed:\n" + traceback.format_exc())

    def watch(self, stop):
        while not stop.is_set():
            self.seed_history()
            sig = self.signature()
            if sig and sig != self.last_sig:
                time.sleep(SETTLE_SECONDS)
                if self.signature() == sig:
                    try:
                        self.rebuild()
                        self.last_sig = sig
                    except Exception as e:  # keep serving the last good state
                        with self.lock:
                            self.health = {**self.health, "error": f"{type(e).__name__}: {e}"}
                        log("rebuild failed:\n" + traceback.format_exc())
                        self.last_sig = sig
            stop.wait(POLL_SECONDS)


def render_fog(save):
    """(explored mask PNG, RGBA veil PNG that darkens unexplored ground)."""
    from PIL import Image

    data = save.blocks["fogofwar"].data
    px = math.isqrt(len(data) - 13)  # 13 header bytes, then one byte per map pixel (1280 x 1280)
    mask = Image.frombytes("L", (px, px), data[13 : 13 + px * px])
    out = []
    for img in (mask, None):
        if img is None:
            img = Image.new("RGBA", (px, px), (11, 20, 22, 0))
            img.putalpha(mask.point(lambda v: int((255 - v) * 0.72)))
        buf = io.BytesIO()
        img.save(buf, "PNG", optimize=True)
        out.append(buf.getvalue())
    return tuple(out)


CONFIG = ROOT / "agent" / "config.json"


def lan_ips():
    """This PC's IPv4 addresses for the phone's Setup, the default route's first. A PC can have several (a second
    network card, a virtual machine's adapter), and only the phone's Wi-Fi decides which one reaches it."""
    import socket

    out = []
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))  # a UDP "connect" sends nothing
            out.append(s.getsockname()[0])
    except OSError:
        pass
    try:
        out += sorted({a[4][0] for a in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET)})
    except OSError:
        pass
    return [ip for ip in dict.fromkeys(out) if not ip.startswith(("127.", "169.254."))] or ["this PC's address"]


def load_config():
    try:
        return json.loads(CONFIG.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_config(folder, world, character):
    conf = load_config()
    conf.update({"folder": str(folder), "world": int(world), "character": int(character)})
    CONFIG.write_text(json.dumps(conf), encoding="utf-8")


def pairing_key():
    """The code the phone must send with every request (header X-Buddy-Key), made once per PC and kept in
    agent/config.json. Without it, anything else on the network (or a web page in a browser, which can't add
    the header) gets nothing. 8 letters and digits without look-alikes, shown in the tray as ABCD-EFGH."""
    import secrets

    conf = load_config()
    if not conf.get("key"):
        alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
        conf["key"] = "".join(secrets.choice(alphabet) for _ in range(8))
        CONFIG.write_text(json.dumps(conf), encoding="utf-8")
    return conf["key"]


def key_text(key):
    return f"{key[:4]}-{key[4:]}"


def pick_save(folder=None, world=None, character=None):
    """(folder, world, character): what's asked, else the last choice, else the newest save on this PC."""
    conf = load_config()
    newest = None
    if folder is None and "folder" not in conf or world is None and "world" not in conf \
            or character is None and "character" not in conf:
        newest = saves_mod.newest()
    folder = pathlib.Path(folder or conf.get("folder") or (newest[0] if newest else saves_mod.steam_dir()))
    world = world if world is not None else conf.get("world", newest[1] if newest else 0)
    character = character if character is not None else conf.get("character", newest[2] if newest else 0)
    return folder, int(world), int(character)


def history_path(folder, world, character):
    """agent/history/<account>_w<world>_c<character>.jsonl: each character and world keeps its own timeline.
    The single agent/history.jsonl from before goes to whichever save is read first."""
    parts = pathlib.Path(folder).parts
    account = parts[-3] if saves_mod.APP_ID in parts else "local"
    path = ROOT / "agent" / "history" / f"{account}_w{world}_c{character}.jsonl"
    old = ROOT / "agent" / "history.jsonl"
    path.parent.mkdir(exist_ok=True)
    if old.exists() and not path.exists():
        old.rename(path)
    return path


def make_handler(agent, key):
    import hmac
    import ipaddress

    saves_cache = {"at": 0.0, "body": None}

    class Handler(BaseHTTPRequestHandler):
        timeout = 30  # seconds a connection may sit idle or trickle (a slow client can't hold threads forever)

        def allowed(self):
            """Home network only, addressed by IP (a web page that renamed itself to this PC by DNS can't reach
            it), and with the pairing code. Answers the refusal itself; returns whether to go on."""
            try:
                ip = ipaddress.ip_address(self.client_address[0].split("%")[0])
                local = ip.is_private or ip.is_loopback or ip.is_link_local
            except ValueError:
                local = False
            host = (self.headers.get("Host") or "").rsplit(":", 1)[0].strip("[]")
            try:
                by_ip = host == "localhost" or bool(ipaddress.ip_address(host))
            except ValueError:
                by_ip = False
            if not local or not by_ip:
                self.send_error(403)
                return False
            sent = (self.headers.get("X-Buddy-Key") or "").replace("-", "").strip().upper()
            if not hmac.compare_digest(sent.encode(), key.encode()):
                time.sleep(0.5)  # guessing 8 characters one request at a time takes forever
                self.reply({"error": "pairing code needed", "pairing": True}, 401)
                return False
            return True

        def reply(self, obj, status=200):
            data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if not self.allowed():
                return
            path = self.path.split("?")[0]
            with agent.lock:
                routes = {
                    "/state": (agent.state_json, "application/json; charset=utf-8"),
                    "/health": (json.dumps(agent.health).encode(), "application/json"),
                    "/fog.png": (agent.fog_png, "image/png"),
                    "/fog_overlay.png": (agent.fog_overlay_png, "image/png"),
                    "/history": (agent.history.json(), "application/json"),
                    "/db/version": (db_version(), "application/json"),
                    "/pos": (json.dumps({"live": True, **agent.pos} if agent.pos else {"live": False}).encode(),
                             "application/json"),
                }
                current = {"folder": str(agent.saves), "world": agent.world, "character": agent.character}
            if path == "/saves":
                # listing copies and unpacks every save: at most every 15 s, however often it's asked
                if saves_cache["body"] is None or time.time() - saves_cache["at"] > 15:
                    saves_cache["body"] = [saves_mod.listing(f) for f in saves_mod.folders()]
                    saves_cache["at"] = time.time()
                routes["/saves"] = (json.dumps({"folders": saves_cache["body"], "current": current},
                                               ensure_ascii=False).encode(), "application/json; charset=utf-8")
            if path == "/db":
                routes["/db"] = (DB.read_bytes() if DB.exists() else b"{}", "application/json; charset=utf-8")
            if path not in routes:
                self.send_error(404)
                return
            body, ctype = routes[path]
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def read_body(self, limit=20000):
            """The request body, sized or chunked (Dart's HttpClient sends chunked unless told the length), never
            more than limit bytes read: a huge or negative size is refused, not buffered."""
            if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
                body = b""
                while len(body) < limit:
                    size = int(self.rfile.readline(64).split(b";")[0].strip() or b"0", 16)
                    if size <= 0:
                        self.rfile.readline(64)  # the blank line after the last chunk
                        break
                    if size > limit - len(body):
                        raise ValueError("request too large")
                    body += self.rfile.read(size)
                    self.rfile.readline(64)  # CRLF after each chunk
                return body
            n = int(self.headers.get("Content-Length") or 0)
            if not 0 <= n <= limit:
                raise ValueError("request too large")
            return self.rfile.read(n)

        def ask_stream(self, req):
            """One JSON object per line as the answer is written (tools/ask.py stream()); the body ends when
            the connection closes (HTTP/1.0). A phone that hangs up stops Claude Code."""
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()

            def send(obj):
                self.wfile.write(json.dumps(obj, ensure_ascii=False).encode("utf-8") + b"\n")

            q = str(req.get("q") or "").strip()
            gen = None
            try:
                if not q:
                    raise RuntimeError("Empty question")
                send({"status": "Reading your question"})
                gen = ask_mod.stream(q[:2000], req.get("session"), req.get("context"), agent.live_for_ask())
                for ev in gen:
                    send(ev)
                    if ev.get("done"):
                        log(f"ask: {len(q)} chars, answered in {ev['seconds']} s (streamed)")
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                log("ask: the phone hung up")
            except Exception as e:
                log(f"ask failed: {e}")
                try:
                    send({"error": str(e)[:300]})
                except OSError:
                    pass
            finally:
                if gen is not None:
                    gen.close()

        def do_POST(self):
            path = self.path.split("?")[0]
            if path not in ("/ask", "/ask/stream", "/select"):
                self.send_error(404)
                return
            if not self.allowed():
                return
            if path == "/select":
                try:
                    req = json.loads(self.read_body() or b"{}")
                    agent.select(req["folder"], int(req["world"]), int(req["character"]))
                    body = {"ok": True}
                except (ValueError, KeyError, TypeError) as e:
                    body = {"ok": False, "error": str(e)[:200]}
                data = json.dumps(body).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return
            if path == "/ask/stream":
                try:
                    req = json.loads(self.read_body() or b"{}")
                except ValueError:
                    req = {}
                self.ask_stream(req)
                return
            try:
                req = json.loads(self.read_body() or b"{}")
                q = str(req.get("q") or "").strip()
                if not q:
                    raise RuntimeError("Empty question")
                text, session, secs = ask_mod.answer(q[:2000], req.get("session"), req.get("context"),
                                                     agent.live_for_ask())
                body = {"answer": text, "session": session, "seconds": secs}
                log(f"ask: {len(q)} chars, answered in {secs} s")
            except Exception as e:
                body = {"error": str(e)[:300]}
                log(f"ask failed: {e}")
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, fmt, *args):
            pass

    return Handler


LOG = ROOT / "agent" / "agent.log"
DB = ROOT / "app" / "assets" / "game.json"


def _gliders():
    try:
        items = json.loads(DB.read_text(encoding="utf-8"))["items"]
        return {k for k, v in items.items() if (v.get("st") or {}).get("sl") == "Glider"}
    except (OSError, ValueError, KeyError):
        return set()




def db_version():
    """{"built": "..."} from the head of game.json (build_db.py writes "built" near the start)."""
    import re
    if not DB.exists():
        return b'{"built": null}'
    with DB.open("rb") as f:
        head = f.read(400).decode("utf-8", "replace")
    m = re.search(r'"built":\s*"([^"]+)"', head)
    return json.dumps({"built": m.group(1) if m else None, "size": DB.stat().st_size}).encode()


def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    if sys.stdout:
        print(line, flush=True)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(line + "\n")


def shortcut_path():
    return pathlib.Path(os.environ["APPDATA"]) / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Startup" / "Enshrouded Companion Agent.lnk"


def install_autostart():
    bat = ROOT / "agent" / "start.bat"
    if not bat.exists():  # older layout
        bat = ROOT / "agent" / "agent.bat"
    sc = shortcut_path()
    def q(path):  # a PowerShell literal: nothing inside single quotes is expanded
        return "'" + str(path).replace("'", "''") + "'"

    ps = (f"$ws = New-Object -ComObject WScript.Shell; $sc = $ws.CreateShortcut({q(sc)}); "
          f"$sc.TargetPath = {q(bat)}; $sc.WorkingDirectory = {q(bat.parent)}; $sc.WindowStyle = 7; "
          f"$sc.Description = 'Enshroud Buddy agent'; $sc.Save();")
    r = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", ps], capture_output=True, text=True)
    print(f"installed {sc}" if r.returncode == 0 else f"failed: {r.stderr}")
    return r.returncode


def run_tray(agent, stop):
    import pystray
    from PIL import Image, ImageDraw

    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse([6, 6, 58, 58], fill=(19, 34, 42, 255), outline=(242, 163, 58, 255), width=4)
    d.polygon([(32, 14), (44, 38), (32, 50), (20, 38)], fill=(242, 163, 58, 255))

    def status(_item=None):
        h = agent.health
        return f"Saved {h['saved_at'] or '—'}" if h["ok"] else f"Waiting: {h['error']}"

    def reading(_item=None):
        h = agent.health
        return f"{h.get('character') or '?'} in {h.get('world') or '?'}"

    def address(_item=None):
        return "Phone address: " + " or ".join(f"{ip}:{PORT}" for ip in lan_ips())

    def code(_item=None):
        return f"Pairing code: {key_text(pairing_key())}"

    def quit_(icon, _item):
        stop.set()
        icon.stop()

    icon = pystray.Icon("ensh_agent", img, "Enshroud Buddy agent", pystray.Menu(
        pystray.MenuItem(lambda _i: address(), None, enabled=False),
        pystray.MenuItem(lambda _i: code(), None, enabled=False),
        pystray.MenuItem(lambda _i: reading(), None, enabled=False),
        pystray.MenuItem(lambda _i: status(), None, enabled=False),
        pystray.MenuItem("Rebuild now", lambda i, it: threading.Thread(target=agent.rebuild, daemon=True).start()),
        pystray.MenuItem("Open state in browser", lambda i, it: os.startfile(f"http://localhost:{PORT}/health")),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Quit", quit_),
    ))
    icon.run()


def main():
    ap = argparse.ArgumentParser()
    # which save: these, else the phone's last choice (agent/config.json), else the newest on this PC
    ap.add_argument("--saves", type=pathlib.Path)
    ap.add_argument("--world", type=int)
    ap.add_argument("--character", type=int)
    ap.add_argument("--export", type=pathlib.Path, default=ROOT / "data" / "export")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--console", action="store_true")
    # live position reads the running game's memory (read-only); this leaves the game process alone entirely
    ap.add_argument("--no-live", action="store_true")
    ap.add_argument("--install-autostart", action="store_true")
    ap.add_argument("--uninstall-autostart", action="store_true")
    a = ap.parse_args()
    if a.install_autostart:
        return install_autostart()
    if a.uninstall_autostart:
        shortcut_path().unlink(missing_ok=True)
        print("removed")
        return 0

    folder, world, character = pick_save(a.saves, a.world, a.character)
    agent = Agent(folder, world, character, a.export)
    stop = threading.Event()
    key = pairing_key()
    server = ThreadingHTTPServer(("0.0.0.0", a.port), make_handler(agent, key))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    threading.Thread(target=agent.watch, args=(stop,), daemon=True).start()
    threading.Thread(target=agent.wiki, args=(stop,), daemon=True).start()
    if not a.no_live:
        threading.Thread(target=agent.live, args=(stop,), daemon=True).start()
    else:
        log("live position off (--no-live): the game's memory isn't read")
    log(f"agent listening on {', '.join(lan_ips())} port {a.port}, reading world{world} and character{character} "
        f"in {folder}")
    try:
        if a.console:
            while not stop.wait(1):
                pass
        else:
            run_tray(agent, stop)
    except KeyboardInterrupt:
        pass
    server.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
