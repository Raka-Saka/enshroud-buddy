"""The world's size, read from the game's own map textures (data/export/map/index.tsv, from tools/eml-export).

baseHeight has one pixel per cell of the save's fog of war: that is the map grid every tool and the app use.
The DetailHeight(i, j) tiles hold 1 m a pixel, so their count across times their width is the world's side.
Saves count positions in half-metres; the live camera (tools/livepos.py) in metres. North is +z, while map
rows grow southward.

    MAP_PX      map grid side (1280 in this game version)
    SIZE_M      world side in metres (10240)
    M_PER_PX    metres per map pixel (8)
    TILES       map texture tiles across (10: DetailHeight and FogZone (i, j))
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
INDEX = ROOT / "data" / "export" / "map" / "index.tsv"


def _read(index=INDEX):
    rows = [line.split("\t") for line in index.read_text(encoding="utf-8").splitlines() if line.strip()]
    size = {r[1]: tuple(int(v) for v in r[2].split("x")) for r in rows if len(r) > 2 and "x" in r[2]}
    px = size["_map_shader_parameters_baseHeight"][0]
    tiles = [size[k][0] for k in size if k.startswith("DetailHeight(")]
    cols = 1 + max(int(re.match(r"DetailHeight\((\d+),", k)[1]) for k in size if k.startswith("DetailHeight("))
    return px, cols * tiles[0], cols


try:
    MAP_PX, SIZE_M, TILES = _read()
except (OSError, KeyError, ValueError, TypeError, IndexError):
    MAP_PX, SIZE_M, TILES = 1280, 10240, 10  # this game version, when the export isn't there
M_PER_PX = SIZE_M / MAP_PX


def map_from_m(x, z):
    """Map pixel (x, y) of a position in metres."""
    return x / M_PER_PX, (SIZE_M - z) / M_PER_PX


def map_from_half(x, z):
    """Map pixel (x, y) of a save position in half-metres."""
    return map_from_m(x / 2, z / 2)
