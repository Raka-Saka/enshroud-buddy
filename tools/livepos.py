"""Live player position from the running game's memory (read-only): the view camera's transform.

    python tools/livepos.py            # print the position once a second

The game keeps the view camera as: i64 x, y, z (metres, 32.32 fixed point), f32 quaternion, f32 scale (1, 1, 1),
4 bytes, then f32 near plane (0.01), far plane (10000) and field of view (radians, about 1.13). It is found
once by scanning the game's read-write memory for that shape (about 7 s for 5 GB), then 72 bytes are read
each second; when they stop matching (new session, loading) it is found again. The camera sits about 3 m
above and behind the character, under half a pixel of the 8 m map. Its local +z is where it looks.

Only PROCESS_VM_READ is asked for: nothing is written to the game, nothing is injected.
"""
import ctypes
import ctypes.wintypes as wt
import math
import pathlib
import struct
import sys
import time

PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_READ = 0x0010
MEM_COMMIT = 0x1000
PAGE_READWRITE = 0x04
NEAR = struct.pack("<f", 0.01)
ONES = struct.pack("<3f", 1.0, 1.0, 1.0)
SIZE = 0x48  # position .. field of view
NEAR_AT = 0x38
CHUNK = 32 << 20
FIND_EVERY = 60  # seconds between searches while the camera isn't found
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import world as W  # noqa: E402

WORLD = W.SIZE_M  # metres across the map


class _MBI(ctypes.Structure):
    _fields_ = [
        ("BaseAddress", ctypes.c_ulonglong),
        ("AllocationBase", ctypes.c_ulonglong),
        ("AllocationProtect", wt.DWORD),
        ("PartitionId", wt.WORD),
        ("RegionSize", ctypes.c_ulonglong),
        ("State", wt.DWORD),
        ("Protect", wt.DWORD),
        ("Type", wt.DWORD),
    ]


_k32 = ctypes.WinDLL("kernel32", use_last_error=True)
_k32.OpenProcess.restype = wt.HANDLE
_k32.CloseHandle.argtypes = [wt.HANDLE]
_k32.VirtualQueryEx.argtypes = [wt.HANDLE, ctypes.c_ulonglong, ctypes.POINTER(_MBI), ctypes.c_size_t]
_k32.VirtualQueryEx.restype = ctypes.c_size_t
_k32.ReadProcessMemory.argtypes = [wt.HANDLE, ctypes.c_ulonglong, ctypes.c_void_p, ctypes.c_size_t,
                                   ctypes.POINTER(ctypes.c_size_t)]
_k32.GetExitCodeProcess.argtypes = [wt.HANDLE, ctypes.POINTER(wt.DWORD)]


def _game_pid():
    import psutil

    for p in psutil.process_iter(["name"]):
        if (p.info["name"] or "").lower() == "enshrouded.exe":
            return p.pid
    return None


def decode(raw):
    """The camera as {"x", "y", "z", "heading", "map"}, or None when the bytes aren't a camera."""
    if len(raw) < SIZE or raw[NEAR_AT:NEAR_AT + 4] != NEAR or raw[0x28:0x34] != ONES:
        return None
    x, y, z = (v / 2 ** 32 for v in struct.unpack_from("<3q", raw, 0))
    qx, qy, qz, qw = struct.unpack_from("<4f", raw, 0x18)
    far, fov = struct.unpack_from("<2f", raw, 0x3C)
    if not (0 < x < WORLD and 0 < z < WORLD and -500 < y < 3000 and far >= 1000 and 0.2 < fov < 2.5):
        return None
    if abs(qx * qx + qy * qy + qz * qz + qw * qw - 1) > 0.01:
        return None
    # local +z turned by the quaternion: where the camera looks
    fx = 2 * (qx * qz + qw * qy)
    fz = 1 - 2 * (qx * qx + qy * qy)
    return {
        "x": round(x, 2),
        "y": round(y, 2),
        "z": round(z, 2),
        "heading": round(math.degrees(math.atan2(fx, fz)) % 360, 1),  # 0 = north, 90 = east
        "map": [round(v, 1) for v in W.map_from_m(x, z)],  # pixel of the map grid
    }


class LivePos:
    def __init__(self, log=print):
        self.log = log
        self.handle = None
        self.addrs = []
        self.last_find = 0.0
        self.buf = bytearray(CHUNK + SIZE)

    def close(self):
        if self.handle:
            _k32.CloseHandle(self.handle)
        self.handle, self.addrs = None, []

    def _alive(self):
        code = wt.DWORD()
        return bool(_k32.GetExitCodeProcess(self.handle, ctypes.byref(code))) and code.value == 259  # STILL_ACTIVE

    def _read(self, addr, size):
        buf = (ctypes.c_char * size).from_buffer(self.buf)
        done = ctypes.c_size_t()
        ok = _k32.ReadProcessMemory(self.handle, addr, buf, size, ctypes.byref(done))
        return bytes(self.buf[:size]) if ok and done.value == size else None

    def _regions(self):
        addr, mbi = 0, _MBI()
        while _k32.VirtualQueryEx(self.handle, addr, ctypes.byref(mbi), ctypes.sizeof(mbi)):
            if mbi.State == MEM_COMMIT and mbi.Protect == PAGE_READWRITE:
                yield mbi.BaseAddress, mbi.RegionSize
            addr = mbi.BaseAddress + mbi.RegionSize
            if addr >= 0x7FFFFFFFFFFF:
                return

    def find(self):
        """Every live camera in the game's memory, by address."""
        found = []
        done = ctypes.c_size_t()
        for base, size in self._regions():
            for o in range(0, size, CHUNK):
                k = min(CHUNK + SIZE, size - o)
                buf = (ctypes.c_char * k).from_buffer(self.buf)
                if not _k32.ReadProcessMemory(self.handle, base + o, buf, k, ctypes.byref(done)):
                    continue
                view = memoryview(self.buf)[:done.value]
                i = self.buf.find(NEAR, 0, done.value)
                while i >= 0:
                    start = i - NEAR_AT
                    if start >= 0 and start + SIZE <= done.value and decode(bytes(view[start:start + SIZE])):
                        found.append(base + o + start)
                    i = self.buf.find(NEAR, i + 1, done.value)
                view.release()
        return sorted(set(found))

    def poll(self):
        """Where the camera is now, or None (game not running, loading, or not found yet)."""
        if self.handle and not self._alive():
            self.log("live position: game closed")
            self.close()
        if not self.handle:
            pid = _game_pid()
            if not pid:
                return None
            self.handle = _k32.OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, False, pid)
            if not self.handle:
                self.handle = None
                return None
        if not self.addrs:
            if time.time() - self.last_find < FIND_EVERY:
                return None
            self.last_find = time.time()
            t = time.time()
            self.addrs = self.find()
            if not self.addrs:
                return None
            self.log(f"live position: camera found ({len(self.addrs)} copies, {time.time() - t:.0f} s)")
        return self._vote()

    def _vote(self):
        """The camera most copies agree on; copies that stop reading as a camera (scratch buffers) are dropped."""
        seen = {}
        for a in list(self.addrs):
            raw = self._read(a, SIZE)
            pos = decode(raw) if raw else None
            if pos is None:
                self.addrs.remove(a)
                continue
            seen.setdefault((pos["x"], pos["z"]), []).append(pos)
        if not seen:
            return None
        return max(seen.values(), key=len)[0]


def main():
    lp = LivePos()
    while True:
        print(time.strftime("%H:%M:%S"), lp.poll(), flush=True)
        time.sleep(1)


if __name__ == "__main__":
    sys.exit(main())
