"""Reader for Enshrouded .ksd saves (SV2C container, game 1.0).

Layout, as decoded from world1.ksd / character1.ksd / global.ksd:

  header (48 B)
    0   "SV2C"
    4   u16 version (2), u16 header size (48)
    8   u32 file size
    12  16 B guid (world or character id)
    28  u32 save counter
    32  u64 unix time of the save
    40  u32 directory offset, relative to this field
    44  u32 block count
  blocks, each "S2BH" + u32 version (2) + u8 type + u8 zstd flag + u32 type version + payload
  directory: block count x (u32 name offset rel. to the entry, u32 name length,
             u32 block offset, u32 block size, u32 hash), then the packed names

Usage:  python tools/ksd.py SAVE.ksd [--dump DIR]
"""
import argparse
import datetime
import io
import pathlib
import struct
import sys

import zstandard


# the most a block may unpack to (the biggest real one, a world's entities, is a few MB): a crafted file that
# unpacks without end is refused instead of filling the PC's memory
MAX_BLOCK = 256 * 1024 * 1024


def unzstd(data):
    reader = zstandard.ZstdDecompressor().stream_reader(io.BytesIO(data))
    out, total = [], 0
    while chunk := reader.read(1 << 20):
        total += len(chunk)
        if total > MAX_BLOCK:
            raise ValueError("save block unpacks to more than 256 MB")
        out.append(chunk)
    return b"".join(out)


class Block:
    def __init__(self, name, offset, size, hash_, raw):
        self.name, self.offset, self.size, self.hash = name, offset, size, hash_
        if raw[:4] != b"S2BH":
            raise ValueError(f"block {name} at {offset}: bad magic {raw[:4]!r}")
        self.type, self.compressed = raw[8], bool(raw[9])
        (self.type_version,) = struct.unpack_from("<I", raw, 10)
        payload = raw[14:]
        if self.compressed:
            payload = unzstd(payload)
        self.data = payload


class Save:
    def __init__(self, path):
        b = pathlib.Path(path).read_bytes()
        magic, self.version, hsize, fsize = struct.unpack_from("<4sHHI", b, 0)
        if magic != b"SV2C" or fsize != len(b):
            raise ValueError(f"{path}: not an SV2C save ({magic!r}, {fsize} vs {len(b)})")
        self.guid = b[12:28].hex()
        self.counter, ts, dir_rel, count = struct.unpack_from("<IQII", b, 28)
        self.saved_at = datetime.datetime.fromtimestamp(ts)
        d = 40 + dir_rel
        self.blocks = {}
        for i in range(count):
            e = d + i * 20
            name_rel, name_len, off, size, h = struct.unpack_from("<5I", b, e)
            name = b[e + name_rel : e + name_rel + name_len].decode()
            self.blocks[name] = Block(name, off, size, h, b[off : off + size])

    def custom_strings(self):
        """World only: altar renames, {8-byte id hex: name}."""
        blk = self.blocks.get("custom_strings")
        if not blk:
            return {}
        data, out = blk.data, {}
        (n,) = struct.unpack_from("<I", data, 0)
        p = 4
        for _ in range(n):
            key = data[p : p + 8].hex()
            (ln,) = struct.unpack_from("<I", data, p + 8)
            out[key] = data[p + 12 : p + 12 + ln].decode("utf-8")
            p += 12 + ln
        return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("save")
    ap.add_argument("--dump", help="write each decompressed block to DIR/<name>.bin")
    a = ap.parse_args()
    s = Save(a.save)
    print(f"{a.save}: guid={s.guid} counter={s.counter} saved={s.saved_at}")
    for blk in s.blocks.values():
        z = "zstd" if blk.compressed else "raw "
        print(f"  {blk.name:24s} type=0x{blk.type:02x} v{blk.type_version:<3d} {z} {len(blk.data):9d} B")
    for k, v in s.custom_strings().items():
        print(f"  altar {k}: {v}")
    if a.dump:
        out = pathlib.Path(a.dump)
        out.mkdir(parents=True, exist_ok=True)
        for blk in s.blocks.values():
            (out / f"{blk.name}.bin").write_bytes(blk.data)


if __name__ == "__main__":
    sys.exit(main())
