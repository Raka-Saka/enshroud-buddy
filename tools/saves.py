"""Where Enshrouded keeps its saves on this PC, and what is in them.

Steam keeps them in <Steam>/userdata/<account id>/1203620/remote (1203620 is the game's Steam app id), one
folder per Steam account that played; the Steam folder comes from the registry. Without Steam Cloud they
can sit in "Saved Games/Enshrouded" instead. A folder holds worldN.ksd and characterN.ksd, each numbered by
its slot in the game's menus.

    python tools/saves.py    lists every folder with its worlds and characters
"""
import os
import pathlib
import shutil
import struct
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from ksd import Save  # noqa: E402

APP_ID = "1203620"  # Enshrouded on Steam


def copy_shared(src, dst):
    """Copies a save like shutil.copy2, but opened with every share flag (read, write and delete): while it
    reads, the game can still write, delete or rename the file (its backup rotation), which Python's own
    open() would block on Windows. The copy keeps the original's modified time."""
    src, dst = pathlib.Path(src), pathlib.Path(dst)
    if sys.platform != "win32":
        shutil.copy2(src, dst)
        return
    import ctypes
    import msvcrt
    from ctypes import wintypes as wt

    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.CreateFileW.restype = wt.HANDLE
    k32.CreateFileW.argtypes = [wt.LPCWSTR, wt.DWORD, wt.DWORD, wt.LPVOID, wt.DWORD, wt.DWORD, wt.HANDLE]
    h = k32.CreateFileW(str(src), 0x80000000, 0x7, None, 3, 0x80, None)  # GENERIC_READ, share all, OPEN_EXISTING
    if h in (None, wt.HANDLE(-1).value):
        raise OSError(ctypes.get_last_error(), "can't open", str(src))
    fd = msvcrt.open_osfhandle(h, os.O_RDONLY | os.O_BINARY)
    with open(fd, "rb") as f:
        data = f.read()
    dst.write_bytes(data)
    st = src.stat()
    os.utime(dst, ns=(st.st_atime_ns, st.st_mtime_ns))


def steam_dir():
    try:
        import winreg

        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as k:
            return pathlib.Path(winreg.QueryValueEx(k, "SteamPath")[0])
    except (OSError, ImportError):
        return pathlib.Path(r"C:\Program Files (x86)\Steam")


def folders():
    """Every folder with Enshrouded saves, most recently saved first."""
    found = list((steam_dir() / "userdata").glob(f"*/{APP_ID}/remote"))
    found.append(pathlib.Path.home() / "Saved Games" / "Enshrouded")
    found = [f for f in found if any(f.glob("world*.ksd")) or any(f.glob("character*.ksd"))]
    return sorted(found, key=lambda f: max(p.stat().st_mtime for p in f.glob("*.ksd")), reverse=True)


def label(folder):
    """"Steam account 12345678" or "Saved Games"."""
    parts = pathlib.Path(folder).parts
    return f"Steam account {parts[-3]}" if APP_ID in parts else "Saved Games"


def _slot(path, kind):
    try:
        return int(path.stem[len(kind):])
    except ValueError:
        return None


def _name(save, kind):
    if kind == "world":
        meta = save.blocks["world_metadata"].data
        (ln,) = struct.unpack_from("<I", meta, 0x39)
        return meta[0x3D:0x3D + ln].decode("utf-8", "replace")
    blk = save.blocks["character_data"].data
    (ln,) = struct.unpack_from("<I", blk, 5)
    return blk[9:9 + ln].decode("utf-8", "replace")


def listing(folder):
    """{"folder", "label", "worlds": [...], "characters": [...]}, each {"slot", "name", "saved_at"}, newest first.
    Read from copies, like everything the agent reads, so a save being written is never touched."""
    folder = pathlib.Path(folder)
    out = {"folder": str(folder), "label": label(folder), "worlds": [], "characters": []}
    with tempfile.TemporaryDirectory(prefix="ensh_saves_") as tmp:
        for kind in ("world", "character"):
            for path in folder.glob(f"{kind}*.ksd"):
                slot = _slot(path, kind)
                if slot is None:
                    continue
                try:
                    copy = pathlib.Path(tmp) / path.name
                    copy_shared(path, copy)
                    save = Save(copy)
                    out[kind + "s"].append({"slot": slot, "name": _name(save, kind),
                                            "saved_at": save.saved_at.isoformat(timespec="seconds")})
                except Exception:  # an unreadable or half-written file: leave it out of the list
                    continue
            out[kind + "s"].sort(key=lambda e: e["saved_at"], reverse=True)
    return out


def newest():
    """(folder, world slot, character slot) last saved on this PC, or None without any saves."""
    for f in folders():
        found = listing(f)
        if found["worlds"] and found["characters"]:
            return f, found["worlds"][0]["slot"], found["characters"][0]["slot"]
    return None


if __name__ == "__main__":
    for f in folders():
        found = listing(f)
        print(found["label"], f)
        for kind in ("worlds", "characters"):
            for e in found[kind]:
                print(f"  {kind[:-1]} {e['slot']}: {e['name']} (saved {e['saved_at']})")
