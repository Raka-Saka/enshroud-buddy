"""The guide over the game: the place the phone's guide leads to, marked where it is in the world.

    python tools/overlay.py            # a demo over the desktop: a marker that drifts across the screen

The phone sends its guide's target (POST /target, agent.py); the agent reads the game's camera about 20 times a
second (livepos.LivePos.peek) and projects the target onto the screen: a gold marker on the spot when it is in
view, an arrow at the screen's edge pointing the way when it isn't, with its name, distance and height under
it. It is our own see-through window that clicks pass through, shown only while the game is the window in
front (borderless or windowed: exclusive fullscreen draws over every other window). Nothing is written to the
game or injected into it.
"""
import ctypes
import ctypes.wintypes as wt
import math
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import pc_text  # noqa: E402
import world as W  # noqa: E402
from pc_text import t  # noqa: E402

FLAME = (242, 163, 58, 255)
BONE = (236, 226, 204, 255)
SHADOW = (0, 0, 0, 170)
CAMERA_HEIGHT = 3.0  # the camera sits about this far above the character's feet (livepos)
ARRIVED_M = 6.0
FPS = 20


def axes(q):
    """The camera's right, up and forward directions in the world (x east, y up, z north), from its rotation."""
    x, y, z, w = q
    right = (1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y))
    up = (2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x))
    fwd = (2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y))
    return right, up, fwd


def project(cam, target, aspect):
    """Where a world point (x, y, z metres) shows on the screen: (sx, sy) from -1 to 1 (right, up), and whether
    it is in view. Off screen or behind, (sx, sy) points the way to turn, pushed to the edge. The camera's field
    of view is taken as vertical."""
    right, up, fwd = axes(cam["q"])
    v = (target[0] - cam["x"], target[1] - cam["y"], target[2] - cam["z"])
    lx, ly, lz = (sum(a * b for a, b in zip(v, axis)) for axis in (right, up, fwd))
    tv = math.tan(cam["fov"] / 2)
    th = tv * aspect
    if lz > 0.5:
        sx, sy = lx / (lz * th), ly / (lz * tv)
        if abs(sx) <= 0.92 and abs(sy) <= 0.85:
            return sx, sy, True
    else:  # behind: the side to turn to, as seen from the camera
        sx, sy = lx / th, ly / tv
        if abs(sx) < 1e-6 and abs(sy) < 1e-6:
            sx = 1.0
    k = max(abs(sx) / 0.88, abs(sy) / 0.78)
    return sx / k, sy / k, False


def target_m(t, ground=None):
    """The target as world metres (x, y up, z), from map pixels and its height (or the ground's)."""
    h = t.get("h")
    if h is None and ground is not None:
        h = ground.at(t["x"], t["y"])
    return t["x"] * W.M_PER_PX, h, W.SIZE_M - t["y"] * W.M_PER_PX


def describe(cam, tm):
    """("120 m", "65 m below"): how far across, and how much up or down from the character's feet."""
    d = math.hypot(tm[0] - cam["x"], tm[2] - cam["z"])
    dist = t("Here") if d < ARRIVED_M else (t("{n} km", n=f"{d / 1000:.1f}") if d >= 1000
                                            else t("{n} m", n=f"{round(d / 5) * 5:.0f}"))
    if tm[1] is None:
        return dist, ""
    c = round(tm[1] - (cam["y"] - CAMERA_HEIGHT))
    return dist, (t("level") if abs(c) < 4 else t("{n} m above", n=abs(c)) if c > 0 else t("{n} m below", n=abs(c)))


# --- drawing --------------------------------------------------------------------------------------------------

WIN_FONTS = pathlib.Path(r"C:\Windows\Fonts")
# fonts with the language's script, (regular, bold); Cinzel has Latin only, Segoe UI Latin, Greek and Cyrillic
SCRIPT_FONTS = {"Ja_Jp": ("YuGothM.ttc", "YuGothB.ttc"), "Ko_Kr": ("malgun.ttf", "malgunbd.ttf"),
                "Zh_Cn": ("msyh.ttc", "msyhbd.ttc"), "Zh_Tw": ("msjh.ttc", "msjhbd.ttc"),
                "Th_Th": ("LeelawUI.ttf", "LeelaUIb.ttf")}


def fonts(fonts_dir):
    """(title, regular, bold) font files for the overlay's language, best first."""
    script = SCRIPT_FONTS.get(pc_text.lang)
    if script:
        reg, bold = WIN_FONTS / script[0], WIN_FONTS / script[1]
        return [bold, reg], [reg, WIN_FONTS / "segoeui.ttf"], [bold, reg]
    title = [WIN_FONTS / "georgiab.ttf"] if pc_text.lang in ("Ru_Ru", "Uk_Ua") else [fonts_dir / "Cinzel.ttf"]
    return (title + [WIN_FONTS / "georgia.ttf"], [WIN_FONTS / "segoeui.ttf"],
            [WIN_FONTS / "segoeuib.ttf", WIN_FONTS / "segoeui.ttf"])


def _font(names, size):
    from PIL import ImageFont

    for n in names:
        try:
            return ImageFont.truetype(str(n), size)
        except OSError:
            continue
    return ImageFont.load_default()


class Painter:
    """The marker as an image: a diamond on the spot, or an arrow at the edge, with the text under it."""

    def __init__(self, fonts_dir, scale):
        self.s, self.lang = scale, pc_text.lang
        title, _, bold = fonts(fonts_dir)
        self.title = _font(title, round(19 * scale))
        self.small = _font(bold, round(15 * scale))

    def draw(self, title, line, arrow=None):
        """An RGBA image and the point in it that sits on the target (the diamond's centre or the arrow's tip's
        base). arrow: None for the diamond, else the screen angle to point at (degrees, 0 up, clockwise)."""
        from PIL import Image, ImageDraw

        s = self.s
        r = round(13 * s)  # the icon's half size
        tw = max(self.title.getbbox(title)[2], self.small.getbbox(line)[2]) if line else self.title.getbbox(title)[2]
        w = max(tw + round(12 * s), 4 * r)
        th = self.title.getbbox("Ag")[3]
        h = 2 * r + round(8 * s) + th + (self.small.getbbox("Ag")[3] + round(4 * s) if line else 0) + round(6 * s)
        img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        cx, cy = w // 2, r + 2
        if arrow is None:
            pts = [(cx, cy - r), (cx + r, cy), (cx, cy + r), (cx - r, cy)]
            d.polygon([(px, py + 2) for px, py in pts], fill=SHADOW)
            d.polygon(pts, fill=(19, 34, 42, 200), outline=FLAME, width=max(2, round(3 * s)))
            d.ellipse([cx - r // 3, cy - r // 3, cx + r // 3, cy + r // 3], fill=FLAME)
        else:
            a = math.radians(arrow)

            def rot(px, py):  # around the centre; (0, -1) is up
                return (cx + px * math.cos(a) - py * math.sin(a), cy + px * math.sin(a) + py * math.cos(a))

            pts = [rot(0, -r), rot(r * 0.8, r * 0.75), rot(0, r * 0.3), rot(-r * 0.8, r * 0.75)]
            d.polygon([(px, py + 2) for px, py in pts], fill=SHADOW)
            d.polygon(pts, fill=FLAME)
        y = 2 * r + round(8 * s)
        stroke = max(1, round(2 * s))
        d.text((cx, y), title, font=self.title, fill=BONE, anchor="ma", stroke_width=stroke, stroke_fill=SHADOW)
        if line:
            d.text((cx, y + th + round(4 * s)), line, font=self.small, fill=FLAME, anchor="ma",
                   stroke_width=stroke, stroke_fill=SHADOW)
        return img, (cx, cy)


class PanelPainter:
    """The plan's tracker, in a corner like the game's own quest list: the goals, the next tasks, and how far
    along the collections are."""

    def __init__(self, fonts_dir, scale):
        self.s, self.lang = scale, pc_text.lang
        title, regular, bold = fonts(fonts_dir)
        self.head = _font(title, round(17 * scale))
        self.body = _font(regular, round(15 * scale))
        self.note = _font(bold, round(13 * scale))

    def _fit(self, text, font, width):
        if font.getlength(text) <= width:
            return text
        while text and font.getlength(text + "…") > width:
            text = text[:-1]
        return text + "…"

    def draw(self, tr):
        from PIL import Image, ImageDraw

        s = self.s
        w, pad = round(330 * s), round(12 * s)
        inner = w - 2 * pad
        rows = []  # (text, font, colour, gap above)
        if tr.get("lines"):
            rows.append((self._fit(tr.get("title") or t("Plan"), self.head, inner), self.head, FLAME, 0))
            for ln in tr["lines"]:
                rows.append((self._fit(ln["t"], self.body, inner), self.body, BONE, round(6 * s)))
                if ln.get("n"):
                    rows.append((self._fit(ln["n"], self.note, inner), self.note, FLAME, round(1 * s)))
            more = int(tr.get("open") or 0) - len(tr["lines"])
            if more > 0:
                rows.append((t("+{n} more on the phone", n=more), self.note, (170, 160, 140, 255), round(6 * s)))
        if not rows and tr.get("done"):
            rows.append((t("Completion"), self.head, FLAME, 0))
        for c in tr.get("done") or []:
            rows.append((self._fit(f"{c['label']}  {c['have']} / {c['of']}", self.body, inner), self.body, BONE,
                         round(10 * s) if rows and c is tr["done"][0] else round(3 * s)))
        if not rows:
            return None
        lh = {id(f): f.getbbox("Ag")[3] for f in (self.head, self.body, self.note)}
        h = pad * 2 + sum(lh[id(f)] + g for _, f, _, g in rows)
        img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle([0, 0, w - 1, h - 1], radius=round(6 * s), fill=(12, 20, 24, 195))
        d.rectangle([0, pad, max(2, round(3 * s)), h - pad], fill=FLAME)
        y = pad
        for text, f, col, gap in rows:
            y += gap
            d.text((pad, y), text, font=f, fill=col, stroke_width=1, stroke_fill=SHADOW)
            y += lh[id(f)]
        return img


# --- the window -----------------------------------------------------------------------------------------------

user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32")
kernel32 = ctypes.WinDLL("kernel32")
LRESULT = ctypes.c_ssize_t
WNDPROC = ctypes.WINFUNCTYPE(LRESULT, wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM)
user32.DefWindowProcW.argtypes = [wt.HWND, wt.UINT, wt.WPARAM, wt.LPARAM]
user32.DefWindowProcW.restype = LRESULT
user32.CreateWindowExW.argtypes = [wt.DWORD, wt.LPCWSTR, wt.LPCWSTR, wt.DWORD, ctypes.c_int, ctypes.c_int,
                                   ctypes.c_int, ctypes.c_int, wt.HWND, wt.HMENU, wt.HINSTANCE, wt.LPVOID]
user32.CreateWindowExW.restype = wt.HWND
user32.GetForegroundWindow.restype = wt.HWND
user32.GetWindowThreadProcessId.argtypes = [wt.HWND, ctypes.POINTER(wt.DWORD)]
user32.GetClientRect.argtypes = [wt.HWND, ctypes.POINTER(wt.RECT)]
user32.ClientToScreen.argtypes = [wt.HWND, ctypes.POINTER(wt.POINT)]
user32.SetWindowPos.argtypes = [wt.HWND, wt.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wt.UINT]
user32.ShowWindow.argtypes = [wt.HWND, ctypes.c_int]
user32.DestroyWindow.argtypes = [wt.HWND]
user32.GetDC.argtypes = [wt.HWND]
user32.GetDC.restype = wt.HDC
user32.ReleaseDC.argtypes = [wt.HWND, wt.HDC]
user32.PeekMessageW.argtypes = [ctypes.POINTER(wt.MSG), wt.HWND, wt.UINT, wt.UINT, wt.UINT]
user32.TranslateMessage.argtypes = [ctypes.POINTER(wt.MSG)]
user32.DispatchMessageW.argtypes = [ctypes.POINTER(wt.MSG)]
gdi32.CreateCompatibleDC.argtypes = [wt.HDC]
gdi32.CreateCompatibleDC.restype = wt.HDC
gdi32.SelectObject.argtypes = [wt.HDC, wt.HGDIOBJ]
gdi32.SelectObject.restype = wt.HGDIOBJ
gdi32.DeleteObject.argtypes = [wt.HGDIOBJ]
gdi32.DeleteDC.argtypes = [wt.HDC]
kernel32.GetModuleHandleW.restype = wt.HMODULE


class WNDCLASSW(ctypes.Structure):
    _fields_ = [("style", wt.UINT), ("lpfnWndProc", WNDPROC), ("cbClsExtra", ctypes.c_int),
                ("cbWndExtra", ctypes.c_int), ("hInstance", wt.HINSTANCE), ("hIcon", wt.HICON),
                ("hCursor", wt.HANDLE), ("hbrBackground", wt.HBRUSH), ("lpszMenuName", wt.LPCWSTR),
                ("lpszClassName", wt.LPCWSTR)]


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [("biSize", wt.DWORD), ("biWidth", wt.LONG), ("biHeight", wt.LONG), ("biPlanes", wt.WORD),
                ("biBitCount", wt.WORD), ("biCompression", wt.DWORD), ("biSizeImage", wt.DWORD),
                ("biXPelsPerMeter", wt.LONG), ("biYPelsPerMeter", wt.LONG), ("biClrUsed", wt.DWORD),
                ("biClrImportant", wt.DWORD)]


class BLENDFUNCTION(ctypes.Structure):
    _fields_ = [("BlendOp", ctypes.c_byte), ("BlendFlags", ctypes.c_byte), ("SourceConstantAlpha", ctypes.c_ubyte),
                ("AlphaFormat", ctypes.c_byte)]


gdi32.CreateDIBSection.argtypes = [wt.HDC, ctypes.POINTER(BITMAPINFOHEADER), wt.UINT,
                                   ctypes.POINTER(ctypes.c_void_p), wt.HANDLE, wt.DWORD]
gdi32.CreateDIBSection.restype = wt.HBITMAP
user32.UpdateLayeredWindow.argtypes = [wt.HWND, wt.HDC, ctypes.POINTER(wt.POINT), ctypes.POINTER(wt.SIZE), wt.HDC,
                                       ctypes.POINTER(wt.POINT), wt.COLORREF, ctypes.POINTER(BLENDFUNCTION), wt.DWORD]

WS_POPUP = 0x80000000
WS_EX = 0x00000008 | 0x00000020 | 0x00000080 | 0x00080000 | 0x08000000  # topmost, transparent, tool, layered, noactivate
SWP = 0x0001 | 0x0004 | 0x0010  # no size, no z-order, no activate


class Window:
    """A click-through, always-on-top, per-pixel transparent window that never takes the focus."""

    def __init__(self):
        self._proc = WNDPROC(lambda h, m, w, l: user32.DefWindowProcW(h, m, w, l))  # kept alive
        hinst = kernel32.GetModuleHandleW(None)
        wc = WNDCLASSW(lpfnWndProc=self._proc, hInstance=hinst, lpszClassName="EnshroudBuddyOverlay")
        user32.RegisterClassW(ctypes.byref(wc))  # fails harmlessly when already registered
        self.hwnd = user32.CreateWindowExW(WS_EX, "EnshroudBuddyOverlay", "Enshroud Buddy guide", WS_POPUP,
                                           0, 0, 1, 1, None, None, hinst, None)
        self.shown = False
        self.size = (0, 0)

    def pump(self):
        msg = wt.MSG()
        while user32.PeekMessageW(ctypes.byref(msg), None, 0, 0, 1):  # PM_REMOVE
            user32.TranslateMessage(ctypes.byref(msg))
            user32.DispatchMessageW(ctypes.byref(msg))

    def paint(self, img, x, y):
        """Shows img (RGBA) with its top left at screen pixel (x, y)."""
        w, h = img.size
        data = img.convert("RGBa").tobytes("raw", "BGRa")  # premultiplied, as Windows wants
        screen = user32.GetDC(None)
        mem = gdi32.CreateCompatibleDC(screen)
        bmi = BITMAPINFOHEADER(biSize=ctypes.sizeof(BITMAPINFOHEADER), biWidth=w, biHeight=-h, biPlanes=1,
                               biBitCount=32, biCompression=0)
        bits = ctypes.c_void_p()
        bmp = gdi32.CreateDIBSection(screen, ctypes.byref(bmi), 0, ctypes.byref(bits), None, 0)
        ctypes.memmove(bits, data, len(data))
        old = gdi32.SelectObject(mem, bmp)
        blend = BLENDFUNCTION(0, 0, 255, 1)  # AC_SRC_OVER, AC_SRC_ALPHA
        user32.UpdateLayeredWindow(self.hwnd, screen, ctypes.byref(wt.POINT(x, y)), ctypes.byref(wt.SIZE(w, h)),
                                   mem, ctypes.byref(wt.POINT(0, 0)), 0, ctypes.byref(blend), 2)  # ULW_ALPHA
        gdi32.SelectObject(mem, old)
        gdi32.DeleteObject(bmp)
        gdi32.DeleteDC(mem)
        user32.ReleaseDC(None, screen)
        self.size = (w, h)
        self.show(True)

    def move(self, x, y):
        user32.SetWindowPos(self.hwnd, None, x, y, 0, 0, SWP)

    def show(self, on):
        if on != self.shown:
            user32.ShowWindow(self.hwnd, 4 if on else 0)  # SW_SHOWNOACTIVATE / SW_HIDE
            self.shown = on

    def close(self):
        user32.DestroyWindow(self.hwnd)


def game_rect(pid):
    """The game's drawing area on screen (left, top, width, height) when its window is the one in front."""
    fg = user32.GetForegroundWindow()
    if not fg or pid is None:
        return None
    owner = wt.DWORD()
    user32.GetWindowThreadProcessId(fg, ctypes.byref(owner))
    if owner.value != pid:
        return None
    rc, pt = wt.RECT(), wt.POINT(0, 0)
    user32.GetClientRect(fg, ctypes.byref(rc))
    user32.ClientToScreen(fg, ctypes.byref(pt))
    if rc.right < 200 or rc.bottom < 200:
        return None
    return pt.x, pt.y, rc.right, rc.bottom


def run(stop, camera, target, game_pid, enabled, fonts_dir, ground=None, log=print, tracker=lambda: None):
    """The overlay's loop, in a thread of its own (the windows belong to it). camera() gives the full camera
    (livepos peek) or None, target() the phone guide's target ({"title", "x", "y", "h"}) or None, tracker() the
    plan's tracker (agent.overlay_tracker) or None, game_pid() the game's process, enabled() the tray's switch.
    The marker follows the guide's target, else the tracker's (the next thing to gather or collect)."""
    try:
        user32.SetThreadDpiAwarenessContext(ctypes.c_void_p(-4))  # per monitor v2: real pixels
    except (AttributeError, OSError):
        pass
    win, painter, last = Window(), None, None
    panel, panel_painter, panel_key = Window(), None, None
    try:
        while not stop.is_set():
            win.pump()
            panel.pump()
            on = enabled()
            tr = tracker() if on else None
            t = (target() or (tr or {}).get("target")) if on else None
            rect = game_rect(game_pid()) if (t or tr) else None
            if rect and tr:
                left, top, w, h = rect
                if panel_painter is None or (panel_painter.s, panel_painter.lang) != (h / 1080, pc_text.lang):
                    panel_painter, panel_key = PanelPainter(fonts_dir, h / 1080), None
                key = (repr(tr), panel_painter.s, rect)
                if key != panel_key:
                    img = panel_painter.draw(tr)
                    if img is None:
                        panel.show(False)
                    else:
                        panel.paint(img, left + w - img.size[0] - round(24 * panel_painter.s), top + round(h * 0.3))
                    panel_key = key
            else:
                panel.show(False)
                panel_key = None
            cam = camera() if rect and t else None
            if not (t and rect and cam):
                win.show(False)
                stop.wait(0.25 if (t or tr) else 0.5)
                continue
            left, top, w, h = rect
            if painter is None or (painter.s, painter.lang) != (h / 1080, pc_text.lang):
                painter, last = Painter(fonts_dir, h / 1080), None
            tm = target_m(t, ground)
            aim = (tm[0], cam["y"] - CAMERA_HEIGHT if tm[1] is None else tm[1], tm[2])
            sx, sy, seen = project(cam, aim, w / h)
            dist, height = describe(cam, tm)
            line = f"{dist} · {height}" if height else dist
            arrow = None if seen else round(math.degrees(math.atan2(sx, sy)) / 5) * 5
            key = (t.get("title"), line, arrow, painter.s)
            if key != last:
                img, anchor = painter.draw(str(t.get("title") or "")[:48] or pc_text.t("Target"), line, arrow)
                last, size = key, img.size
            px = left + round((sx + 1) / 2 * w) - anchor[0]
            py = top + round((1 - sy) / 2 * h) - anchor[1]
            px = min(max(px, left), left + w - size[0])
            py = min(max(py, top), top + h - size[1])
            if key is not None and (win.size != size or not win.shown or getattr(win, "key", None) != key):
                win.paint(img, px, py)
                win.key = key
            else:
                win.move(px, py)
            stop.wait(1 / FPS)
    except Exception:
        import traceback

        log("overlay failed:\n" + traceback.format_exc())
    finally:
        win.close()
        panel.close()


def main():
    """A demo over the desktop: the camera turns slowly; the target sits 120 m north and 20 m down."""
    import threading

    stop = threading.Event()
    t0 = time.time()

    def camera():
        a = math.radians((time.time() - t0) * 15 % 360)  # turning right
        return {"x": 1000.0, "y": 300.0, "z": 1000.0, "q": (0.0, math.sin(a / 2), 0.0, math.cos(a / 2)), "fov": 1.13}

    tx, ty = W.map_from_m(1000, 1120)
    target = {"title": "Siren Seeker Boots", "x": tx, "y": ty, "h": 277.0}
    pid = kernel32.GetCurrentProcessId()
    global game_rect
    real = game_rect

    def desktop(_pid):  # the whole primary screen, whatever is in front
        r = real(_pid)
        return r or (0, 0, user32.GetSystemMetrics(0), user32.GetSystemMetrics(1))

    game_rect = desktop
    fonts = pathlib.Path(__file__).resolve().parents[1] / "app" / "assets" / "fonts"
    threading.Timer(float(sys.argv[1]) if len(sys.argv) > 1 else 30, stop.set).start()
    run(stop, camera, lambda: target, lambda: pid, lambda: True, fonts)


if __name__ == "__main__":
    main()
