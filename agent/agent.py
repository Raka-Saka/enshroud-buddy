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

Every request is signed with the pairing code (class Guard): the code itself never crosses the network, and
replies carry X-Buddy-Reply so the phone can tell they came from this agent.

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
from paths import DATA, EXPORT, FROZEN, RES  # noqa: E402
import ask as ask_mod  # noqa: E402
import glide as glide_mod  # noqa: E402
import history as history_mod  # noqa: E402
import livepos as livepos_mod  # noqa: E402
import motion as motion_mod  # noqa: E402
import saves as saves_mod  # noqa: E402
import state as state_mod  # noqa: E402
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
        self.pos_wanted = 0.0  # when the phone last asked for it (GET /pos)
        self.live_on = load_config().get("live", True)  # the tray's switch, kept in config.json
        self.glider = None  # the equipped glider's item id, for the glide calibration
        self.glides = glide_mod.GlideLog(DATA / "glide.json", log=log)
        try:
            ground = motion_mod.HeightMap(RES / "app" / "assets" / "height.png", RES / "app" / "assets" / "height.json")
        except (OSError, ValueError, KeyError):
            ground = None
        self.motion = motion_mod.Motion(ground, DATA / "walk.json")
        self.trace = motion_mod.Trace(DATA / "trace.jsonl")
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
                saves_mod.copy_shared(f, tmp / f.name)
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

    def live(self, stop):
        """Read the player's position from the running game once a second, while the tray's switch is on. The
        costly search for the camera runs only while the phone shows the map (asked in the last 2 minutes)."""
        lp, failed = livepos_mod.LivePos(log=log), False
        while not stop.is_set():
            if not self.live_on:
                lp.close()
                with self.lock:
                    self.pos = None
                stop.wait(2)
                continue
            try:
                pos = lp.poll(search=time.time() - self.pos_wanted < 120)
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


CONFIG = DATA / "config.json"


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


def write_config(conf):
    """Whole or not at all (a temp file, then a rename): a cut-off write would lose the pairing code."""
    tmp = CONFIG.with_suffix(".tmp")
    tmp.write_text(json.dumps(conf), encoding="utf-8")
    os.replace(tmp, CONFIG)


def save_config(folder, world, character):
    conf = load_config()
    conf.update({"folder": str(folder), "world": int(world), "character": int(character)})
    write_config(conf)


def pairing_key():
    """The code the phone must send with every request (header X-Buddy-Key), made once per PC and kept in
    agent/config.json. Without it, anything else on the network (or a web page in a browser, which can't add
    the header) gets nothing. 8 letters and digits without look-alikes, shown in the tray as ABCD-EFGH."""
    import secrets

    conf = load_config()
    if not conf.get("key"):
        alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
        conf["key"] = "".join(secrets.choice(alphabet) for _ in range(8))
        write_config(conf)
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
    path = DATA / "history" / f"{account}_w{world}_c{character}.jsonl"
    old = DATA / "history.jsonl"
    path.parent.mkdir(exist_ok=True)
    if old.exists() and not path.exists():
        old.rename(path)
    return path


AUTH_WINDOW = 120  # seconds a signed request stays valid (phone and PC clocks may differ this much)


def sign(key, *parts):
    """HMAC-SHA256 of the parts, with the pairing code as the key: what the phone sends instead of the code."""
    import hashlib
    import hmac

    return hmac.new(key.encode(), "\n".join(str(p) for p in parts).encode(), hashlib.sha256).hexdigest()


class Guard:
    """Signed requests (X-Buddy-Time, X-Buddy-Nonce, X-Buddy-Sig = sign(code, method, path, time, nonce)): the
    pairing code itself never crosses the network, so someone listening on the Wi-Fi can't learn it, and a
    nonce seen before is refused, so a captured request can't be replayed. Wrong signatures are slowed down
    and, past a few a minute from anywhere, refused outright for a minute."""

    def __init__(self, key):
        self.key = key
        self.lock = threading.Lock()
        self.nonces = {}  # nonce -> time seen, kept for AUTH_WINDOW
        self.fails = []  # times of recent failures
        self.warned = 0.0

    def blocked(self):
        with self.lock:
            now = time.time()
            self.fails = [t for t in self.fails if now - t < 60]
            return len(self.fails) >= 20

    def check(self, method, path, headers):
        import hmac

        try:
            t = int(headers.get("X-Buddy-Time") or "")
        except ValueError:
            return False
        nonce = headers.get("X-Buddy-Nonce") or ""
        sig = headers.get("X-Buddy-Sig") or ""
        now = time.time()
        ok = (abs(now - t) <= AUTH_WINDOW and 16 <= len(nonce) <= 64
              and hmac.compare_digest(sig.encode(), sign(self.key, method, path, t, nonce).encode()))
        with self.lock:
            if ok:
                self.nonces = {n: at for n, at in self.nonces.items() if now - at <= 2 * AUTH_WINDOW}
                if nonce in self.nonces:
                    ok = False
                else:
                    self.nonces[nonce] = now
            if not ok:
                self.fails.append(now)
                if len(self.fails) >= 20 and now - self.warned > 600:
                    self.warned = now
                    log("many requests with a wrong pairing code: something on the network is guessing")
        return ok


def agent_version():
    """This agent's version: the app's, as both are released together (app/pubspec.yaml, bundled in the exe)."""
    try:
        for line in (RES / "app" / "pubspec.yaml").read_text(encoding="utf-8").splitlines():
            if line.startswith("version:"):
                return line.split(":", 1)[1].strip().split("+")[0]
    except OSError:
        pass
    return None


def make_handler(agent, key):
    import ipaddress

    saves_cache = {"at": 0.0, "body": None}
    guard = Guard(key)

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
            if guard.blocked():
                self.send_error(429)
                return False
            if not guard.check(self.command, self.path.split("?")[0], self.headers):
                time.sleep(0.5)  # guessing 8 characters one request at a time takes forever
                # the PC's clock, so a phone whose clock is off can sign with the right time next
                self.reply({"error": "pairing code needed", "pairing": True, "now": int(time.time())}, 401)
                return False
            return True

        def signed(self, body):
            """Signs a reply for the request's nonce, so the phone can tell it came from this agent: a device
            on the network can't slip it fake game data."""
            import hashlib

            return sign(key, self.headers.get("X-Buddy-Nonce") or "", hashlib.sha256(body).hexdigest())

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
                    "/health": (json.dumps({**agent.health, "version": agent_version()}).encode(), "application/json"),
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
            if path == "/pos":
                agent.pos_wanted = time.time()
            body, ctype = routes[path]
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Buddy-Reply", self.signed(body))
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


LOG = DATA / "agent.log"
DB = RES / "app" / "assets" / "game.json"


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
    """One line to agent.log (and the console). The log rolls over at 1 MB, one old file kept, and a failed
    write (disk full, a locked file) is ignored rather than breaking the thread that logs."""
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    if sys.stdout:
        try:
            print(line, flush=True)
        except (OSError, ValueError):
            pass
    try:
        if LOG.exists() and LOG.stat().st_size > 1_000_000:
            os.replace(LOG, LOG.with_suffix(".old.log"))
        with LOG.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


START_MENU = pathlib.Path(os.environ.get("APPDATA", "")) / "Microsoft" / "Windows" / "Start Menu" / "Programs"
EXE = DATA / "EnshroudBuddy.exe"  # where the one-file exe installs itself
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def shortcut_path():
    # from source the shortcut keeps its old name, so existing installs don't get a second one
    return START_MENU / "Startup" / ("Enshroud Buddy.lnk" if FROZEN else "Enshrouded Companion Agent.lnk")


SYSTEM32 = pathlib.Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32"


def powershell(script, **paths):
    """Runs a PowerShell script with paths handed over as environment variables ($env:EB_<NAME>), never
    pasted into its text, so no character in a path can change the script. PowerShell by its full path:
    a powershell.exe sitting next to the downloaded exe (in Downloads) is never the one run."""
    env = {**os.environ, **{f"EB_{k.upper()}": str(v) for k, v in paths.items()}}
    exe = SYSTEM32 / "WindowsPowerShell" / "v1.0" / "powershell.exe"
    return subprocess.Popen([str(exe), "-NoProfile", "-NonInteractive", "-Command", script], env=env,
                            cwd=str(SYSTEM32), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                            creationflags=NO_WINDOW)


def make_shortcut(sc, target, workdir, minimized=False):
    script = ("$ws = New-Object -ComObject WScript.Shell; $sc = $ws.CreateShortcut($env:EB_SC); "
              "$sc.TargetPath = $env:EB_TARGET; $sc.WorkingDirectory = $env:EB_WORKDIR; "
              f"{'$sc.WindowStyle = 7; ' if minimized else ''}$sc.Description = 'Enshroud Buddy agent'; $sc.Save()")
    proc = powershell(script, sc=sc, target=target, workdir=workdir)
    out, err = proc.communicate(timeout=60)
    return subprocess.CompletedProcess(proc.args, proc.returncode, out, err)


def install_autostart():
    if FROZEN:
        target = EXE
    else:
        target = ROOT / "agent" / "start.bat"
        if not target.exists():  # older layout
            target = ROOT / "agent" / "agent.bat"
    sc = shortcut_path()
    r = make_shortcut(sc, target, target.parent, minimized=not FROZEN)
    print(f"installed {sc}" if r.returncode == 0 else f"failed: {r.stderr}")
    return r.returncode


def message(text, ask=False):
    """A Windows message box (the exe has no console); with ask, True when the answer is Yes."""
    import ctypes

    flags = 0x24 if ask else 0x40  # Yes/No with a question mark, else OK with an "i"
    return ctypes.windll.user32.MessageBoxW(None, text, "Enshroud Buddy", flags | 0x10000) == 6


QUIT_EVENT = "Local\\EnshroudBuddyQuit"


def quit_signal():
    """A named event the running agent watches: set, it quits cleanly (config written, temp files removed)."""
    import ctypes

    k32 = ctypes.windll.kernel32
    k32.CreateEventW.restype = ctypes.c_void_p
    return k32.CreateEventW(None, True, False, QUIT_EVENT)


def watch_quit(stop, on_quit):
    import ctypes

    k32 = ctypes.windll.kernel32
    k32.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    handle = quit_signal()
    k32.ResetEvent(ctypes.c_void_p(handle))
    while not stop.is_set():
        if k32.WaitForSingleObject(handle, 1000) == 0:
            log("asked to quit (an update is replacing this copy)")
            on_quit()
            return


def stop_installed():
    """Ends a running installed copy, so a newer exe can replace it: first by asking it to quit, and only
    if it hasn't within 10 s by ending the process (that copy's, by its exact path, never anything else)."""
    import ctypes

    import psutil

    def ours():
        out = []
        for p in psutil.process_iter(["exe"]):
            try:
                if p.pid != os.getpid() and p.info["exe"] and pathlib.Path(p.info["exe"]).resolve() == EXE.resolve():
                    out.append(p)
            except (psutil.Error, OSError):
                pass
        return out

    running = ours()
    if not running:
        return
    ctypes.windll.kernel32.SetEvent(ctypes.c_void_p(quit_signal()))
    _, alive = psutil.wait_procs(running, timeout=10)
    for p in alive:
        try:
            p.terminate()
            p.wait(10)
        except (psutil.Error, OSError):
            pass


def self_install():
    """The downloaded exe, run from anywhere but its install folder, installs or updates itself: it copies
    itself to %LOCALAPPDATA%/EnshroudBuddy (replacing a running older copy), adds Start menu and Windows
    startup shortcuts, and starts the installed copy, which shows the pairing QR code on a first install. No
    admin rights needed; Windows asks once whether it may use the network. True when this process should end."""
    here = pathlib.Path(sys.executable).resolve()
    if not FROZEN or here == EXE.resolve():
        return False
    update = EXE.exists()
    stop_installed()
    for _ in range(20):
        try:
            shutil.copy2(here, EXE)
            break
        except OSError:
            time.sleep(0.5)
    else:
        message("Enshroud Buddy couldn't be installed: its folder is in use. Restart the PC and try again.")
        return True
    make_shortcut(START_MENU / "Enshroud Buddy.lnk", EXE, DATA)
    make_shortcut(shortcut_path(), EXE, DATA)
    subprocess.Popen([str(EXE)] + ([] if update else ["--pair"]), cwd=DATA)
    if update:
        message("Enshroud Buddy is updated and running again (the round icon in the tray, bottom right).")
    return True


def uninstall():
    """Removes the shortcuts and, a few seconds after this process ends, the install folder with its data."""
    shortcut_path().unlink(missing_ok=True)
    (START_MENU / "Enshroud Buddy.lnk").unlink(missing_ok=True)
    if FROZEN and DATA.name == "EnshroudBuddy":  # only ever its own folder
        powershell("Start-Sleep -Seconds 4; Remove-Item -LiteralPath $env:EB_DIR -Recurse -Force", dir=DATA)


def pair_text():
    """What the pairing QR code holds: every address of this PC and the pairing code. The app tries the
    addresses in turn and keeps the first that answers."""
    return f"enshroudbuddy:pair?a={','.join(f'{ip}:{PORT}' for ip in lan_ips())}&k={pairing_key()}"


def show_pairing():
    """A small window with the QR code to scan in the app's Setup, and the same details to type instead."""
    import tkinter as tk

    import qrcode
    from PIL import ImageTk

    root = tk.Tk()
    root.title("Enshroud Buddy: pair your phone")
    root.configure(bg="white")
    root.resizable(False, False)
    photo = ImageTk.PhotoImage(qrcode.make(pair_text(), box_size=8, border=2).get_image().convert("RGB"))
    tk.Label(root, text="In the app, open Setup (gear icon on Home) and tap Scan the PC's code.",
             bg="white", font=("Segoe UI", 11), wraplength=360).pack(padx=16, pady=(16, 8))
    tk.Label(root, image=photo, bg="white").pack(padx=16)
    tk.Label(root, text="Or type it in:\n" + " or ".join(f"{ip}:{PORT}" for ip in lan_ips())
             + f"\nPairing code {key_text(pairing_key())}", bg="white", font=("Segoe UI", 10),
             justify="center").pack(padx=16, pady=8)
    tk.Button(root, text="Close", command=root.destroy, width=12).pack(pady=(0, 8))
    tk.Label(root, text="Unofficial fan project. Not affiliated with or endorsed by Keen Games.\nEnshrouded and "
             "its content are the property of Keen Games GmbH.", bg="white", fg="#666666", font=("Segoe UI", 8),
             justify="center").pack(padx=16, pady=(0, 12))
    root.attributes("-topmost", True)
    root.after(500, lambda: root.attributes("-topmost", False))
    root.mainloop()


def set_live(agent, on):
    agent.live_on = bool(on)
    conf = load_config()
    conf["live"] = agent.live_on
    write_config(conf)
    log(f"live position {'on' if on else 'off: the game is left alone'}")


def single_instance():
    """True when no other agent runs for this Windows user: a named mutex, held until this process ends."""
    import ctypes

    k32 = ctypes.windll.kernel32
    k32.CreateMutexW.restype = ctypes.c_void_p
    single_instance.handle = k32.CreateMutexW(None, False, "Local\\EnshroudBuddyAgent")
    return k32.GetLastError() != 183  # ERROR_ALREADY_EXISTS


class Server(ThreadingHTTPServer):
    """The agent's HTTP server: the port is its own (Windows would otherwise let a second program share it),
    and at most 32 requests are handled at once, so slow or many connections can't exhaust the PC."""

    allow_reuse_address = False
    daemon_threads = True

    def __init__(self, *a, **kw):
        self.slots = threading.BoundedSemaphore(32)
        super().__init__(*a, **kw)

    def server_bind(self):
        import socket

        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


def run_tray(agent, stop, quit_now=None):
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

    if quit_now is not None:
        quit_now.append(lambda: quit_(icon, None))

    def uninstall_(icon, item):
        if message("Remove Enshroud Buddy and its data from this PC? Your game saves stay as they are.", ask=True):
            uninstall()
            quit_(icon, item)

    icon = pystray.Icon("ensh_agent", img, "Enshroud Buddy agent", pystray.Menu(
        pystray.MenuItem(lambda _i: address(), None, enabled=False),
        pystray.MenuItem(lambda _i: code(), None, enabled=False),
        pystray.MenuItem(lambda _i: reading(), None, enabled=False),
        pystray.MenuItem(lambda _i: status(), None, enabled=False),
        pystray.MenuItem("Pair a phone (QR code)", lambda i, it: threading.Thread(target=show_pairing,
                                                                                    daemon=True).start(),
                         default=True),
        pystray.MenuItem("Live position (reads the game's memory)", lambda i, it: set_live(agent, not agent.live_on),
                         checked=lambda _i: agent.live_on),
        pystray.MenuItem("Rebuild now", lambda i, it: setattr(agent, "last_sig", None)),  # the watch loop rebuilds
        pystray.MenuItem("Open log folder", lambda i, it: os.startfile(DATA)),
        pystray.MenuItem("Licences", lambda i, it: os.startfile(RES / "THIRD_PARTY_LICENSES.txt"),
                         visible=(RES / "THIRD_PARTY_LICENSES.txt").exists()),
        pystray.MenuItem("Open state in browser", lambda i, it: os.startfile(f"http://localhost:{PORT}/health")),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("Uninstall from this PC", uninstall_),
        pystray.MenuItem("Quit", quit_),
    ))
    icon.run()


def main():
    ap = argparse.ArgumentParser()
    # which save: these, else the phone's last choice (agent/config.json), else the newest on this PC
    ap.add_argument("--saves", type=pathlib.Path)
    ap.add_argument("--world", type=int)
    ap.add_argument("--character", type=int)
    ap.add_argument("--export", type=pathlib.Path, default=EXPORT)
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--console", action="store_true")
    # live position reads the running game's memory (read-only); this leaves the game process alone entirely
    ap.add_argument("--no-live", action="store_true")
    ap.add_argument("--install-autostart", action="store_true")
    ap.add_argument("--uninstall-autostart", action="store_true")
    ap.add_argument("--pair", action="store_true", help="show the pairing QR code once started")
    a = ap.parse_args()
    if self_install():
        return 0
    if a.install_autostart:
        return install_autostart()
    if a.uninstall_autostart:
        shortcut_path().unlink(missing_ok=True)
        print("removed")
        return 0

    if not single_instance():  # already running: opening it again shows the pairing code
        if FROZEN:
            show_pairing()
            return 0
        print("the agent is already running")
        return 1

    folder, world, character = pick_save(a.saves, a.world, a.character)
    agent = Agent(folder, world, character, a.export)
    stop = threading.Event()
    key = pairing_key()
    try:
        server = Server(("0.0.0.0", a.port), make_handler(agent, key))
    except OSError:  # the port is taken by another program
        log(f"port {a.port} is in use by another program")
        if FROZEN:
            message(f"Enshroud Buddy can't start: another program uses port {a.port}.")
            return 1
        raise
    threading.Thread(target=server.serve_forever, daemon=True).start()
    threading.Thread(target=agent.watch, args=(stop,), daemon=True).start()
    quit_now = []  # the tray sets this to its own quit; without a tray, stopping the loop is enough
    threading.Thread(target=watch_quit, args=(stop, lambda: (quit_now[0]() if quit_now else stop.set())),
                     daemon=True).start()
    if FROZEN:  # Ask reads wiki pages as needed now; drop a bulk copy an older version kept
        shutil.rmtree(DATA / "ask" / "wiki", ignore_errors=True)
    if a.pair:
        threading.Thread(target=show_pairing, daemon=True).start()
    if a.no_live:
        agent.live_on = False  # for this run; the tray's switch can still turn it on
        log("live position off (--no-live): the game's memory isn't read")
    threading.Thread(target=agent.live, args=(stop,), daemon=True).start()
    log(f"agent listening on {', '.join(lan_ips())} port {a.port}, reading world{world} and character{character} "
        f"in {folder}")
    try:
        if a.console:
            while not stop.wait(1):
                pass
        else:
            run_tray(agent, stop, quit_now)
    except KeyboardInterrupt:
        pass
    server.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
