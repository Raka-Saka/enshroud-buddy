"""Render the world map from the game's own map textures and cut it into app tiles.

    python tools/build_map.py [--textures data/export/map] [--out app/assets/map] [--size 4096]

Inputs are the UiMapResource textures exported by tools/eml-export (map/index.tsv + part_NNN.png):
baseHeight (1280x1280, the same grid as the save's fog of war; 8-bit, about 16 m per step, see
height_map) and 10x10 DetailHeight tiles (1024x1024 each, 1 m per pixel). DetailHeight(i, j) is column i
from the west and row j from the SOUTH, and holds the terrain's north-south slope, not a height: 127 is
flat, above it the ground rises northward (correlation 0.43 with the base's slope; none with the base
height or with tile rows counted from the north, which is how v0.20 and earlier drew the shading).
Tiles have zero alpha, so only the red channel is read.

Output: 256 px JPEG tiles named z_x_y.jpg (one flat folder, one pubspec line) for zoom
0..log2(size/256), plus map_preview.jpg beside the folder.
Map pixel (fog pixel) = (world_x / 16, (20480 - world_z) / 16) in half-metre save units.
"""
import argparse
import json
import math
import pathlib

import sys

import numpy as np
from PIL import Image
from scipy import ndimage

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import world as W  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
TILE = 256
# relief units (base * 3 per output pixel) per detail step: fitted, the base's north-south slope is
# -0.0425 base levels per fog pixel per detail step, i.e. -0.13 here
DETAIL_SLOPE = 0.13

# parchment palette by normalised elevation
STOPS = [
    (0.00, (30, 46, 52)), (0.04, (52, 74, 76)), (0.07, (205, 192, 152)), (0.25, (196, 182, 138)),
    (0.45, (176, 164, 120)), (0.62, (150, 141, 108)), (0.78, (136, 132, 120)), (0.90, (186, 182, 174)),
    (1.00, (240, 236, 228)),
]


def load(textures):
    rows = [line.split("\t") for line in (textures / "index.tsv").read_text(encoding="utf-8").splitlines()]
    return {r[1]: textures / f"part_{int(r[0]):03d}.png" for r in rows}


def red(path, size=None):
    im = Image.open(path).getchannel("R")
    return im if size is None else im.resize(size, Image.BILINEAR)


def render(textures, size):
    parts = load(textures)
    step = size // W.TILES
    det = np.zeros((size, size), np.float32)
    for i in range(W.TILES):
        for j in range(W.TILES):
            t = red(parts[f"DetailHeight({i},{j})"], (step, step))
            r = W.TILES - 1 - j  # tile rows count from the south
            det[r * step:(r + 1) * step, i * step:(i + 1) * step] = np.asarray(t, np.float32)
    px = size / W.MAP_PX  # output pixels per fog pixel
    # the base height is 8-bit: smooth it in float before upscaling, or contours come out as stairs
    base = ndimage.gaussian_filter(np.asarray(red(parts["_map_shader_parameters_baseHeight"]), np.float32), 1.2)
    base = ndimage.zoom(base, px, order=3)
    lo, hi = np.percentile(base, 0.5), np.percentile(base, 99.8)
    elev = np.clip((base - lo) / (hi - lo), 0, 1)
    relief = base * 3.0 * px
    gy, gx = np.gradient(relief)
    # the detail is the north-south slope at 1 m: fine shading on top (rows grow southward, so it subtracts)
    gy = gy - (det - 127) * DETAIL_SLOPE
    shade = np.clip(0.9 + (-gx * 0.6 - gy * 0.8) / np.sqrt(1 + gx * gx + gy * gy) * 0.45, 0.55, 1.15)

    xs = np.array([s[0] for s in STOPS])
    cs = np.array([s[1] for s in STOPS], np.float32)
    rgb = np.stack([np.interp(elev, xs, cs[:, c]) for c in range(3)], -1) * shade[..., None]

    # contour lines every 1/24 of the elevation range, from an extra-smooth copy
    bands = np.floor(ndimage.gaussian_filter(elev, px * 1.5) * 24)
    edge = (np.abs(np.diff(bands, axis=0, prepend=bands[:1])) + np.abs(np.diff(bands, axis=1, prepend=bands[:, :1]))) > 0
    rgb[edge & (elev > 0.07)] *= 0.78
    return Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8))


def shroud_levels(textures):
    """1280x1280 grayscale: 0 = no Shroud, otherwise estimated Shroud level + 1.

    FogZone(i,j) tiles (BC5): red >= 128 is inside the Shroud. Green is the Shroud level, 1..10 (16 = no
    gameplay Shroud in the tile; 0 in a few patches, mostly in Cinder's Cradle, where the world scene's
    zones say 10). Checked on Pikemead's Reach (green 3, "Passage Level 3 is required") and on the world
    scene's FogVoxelMapping zones, counted from 0: green = zone level + 1 for 52 of 62. Until v0.34.1 this
    read level = 10 - green, which put Springlands at 8 and Veilwater Basin at 1.
    Each 1024 px tile shrinks to 128 px by block max.

    Like DetailHeight, FogZone(i, j) is column i and row j from the SOUTH. Checked against the coast: the
    texture's sea (red 255, green 16) overlaps the height map's sea by 79% this way and at most 70%
    any other way. v0.22 and earlier counted rows from the north, which put the Shroud in the wrong
    1 km rows. Placed right, 75% of Elixir Wells and 51% of Shroud Roots fall inside (all wells and 86% of
    roots within 150 m; the rest are in cave Shroud the map doesn't draw), against 13% of random land.
    """
    parts = load(textures)
    n = W.MAP_PX // W.TILES  # map pixels per FogZone tile
    out = np.zeros((W.MAP_PX, W.MAP_PX), np.uint8)
    for i in range(W.TILES):
        for j in range(W.TILES):
            im = Image.open(parts[f"FogZone({i},{j})"])
            r = np.asarray(im.getchannel("R"))
            g = np.asarray(im.getchannel("G"))
            level = np.where(g == 0, 10, g).astype(np.int16)
            lv = np.where((r >= 128) & (g < 16), level + 1, 0).astype(np.uint8)
            row = W.TILES - 1 - j  # tile rows count from the south
            k = lv.shape[0] // n  # texture pixels per map pixel
            out[row * n:(row + 1) * n, i * n:(i + 1) * n] = lv.reshape(n, k, n, k).max(axis=(1, 3))
    return Image.fromarray(out)


def cut(img, out):
    levels = int(math.log2(img.width // TILE))
    for z in range(levels + 1):
        n = 2 ** z
        level = img.resize((n * TILE, n * TILE), Image.LANCZOS) if n * TILE != img.width else img
        for x in range(n):
            for y in range(n):
                tile = level.crop((x * TILE, y * TILE, (x + 1) * TILE, (y + 1) * TILE))
                tile.save(out / f"{z}_{x}_{y}.jpg", quality=82, optimize=True)
    return levels


def height_map(textures, export):
    """app/assets/height.png (the 1280 x 1280 base height as is) and the metres it stands for,
    {"m_per_step", "offset_m"}: ground height = m_per_step * value + offset_m, sampled at texel centres
    (map pixel - 0.5). Fitted against the exported spots' heights (poi.tsv, half-metres), dropping the ones
    off the ground (caves, dungeons, roofs) over a few rounds; typically within about 6 m, as the steps are
    about 16 m."""
    img = red(load(textures)["_map_shader_parameters_baseHeight"])
    base = np.asarray(img, np.float64)
    pts = []
    for line in (export / "poi.tsv").read_text(encoding="utf-8").splitlines():
        p = line.split("\t")
        if len(p) >= 7:
            x, y, z = float(p[4]) / 2, float(p[5]) / 2, float(p[6]) / 2
            if 0 < x < W.SIZE_M and 0 < z < W.SIZE_M:
                mx, my = W.map_from_m(x, z)
                pts.append((mx - 0.5, my - 0.5, y))
    u, v, h = (np.array(c) for c in zip(*pts))
    u, v = np.clip(u, 0, 1278.999), np.clip(v, 0, 1278.999)
    u0, v0 = u.astype(int), v.astype(int)
    fu, fv = u - u0, v - v0
    b = (base[v0, u0] * (1 - fu) * (1 - fv) + base[v0, u0 + 1] * fu * (1 - fv)
         + base[v0 + 1, u0] * (1 - fu) * fv + base[v0 + 1, u0 + 1] * fu * fv)
    keep = np.ones(len(h), bool)
    for _ in range(6):
        coef = np.polyfit(b[keep], h[keep], 1)
        res = h - np.polyval(coef, b)
        keep = np.abs(res) < max(3 * np.median(np.abs(res[keep])), 2)
    fit = {"m_per_step": round(float(coef[0]), 3), "offset_m": round(float(coef[1]), 1),
           "median_error_m": round(float(np.median(np.abs(res[keep]))), 1), "ground_spots": int(keep.sum())}
    return img, fit


def cold_map(export):
    """app/assets/cold.png: 640 x 640 (16 m per pixel, the 1280 grid halved), 0 = mild, else the coldest
    value in that column of the game's temperature grid. The grid is in metres from cold.json's origin;
    checked: 176 of 178 Cold Heights places fall inside it, and almost nothing from other regions."""
    meta = json.loads((export / "cold.json").read_text(encoding="utf-8"))
    ox, _, oz = (float(v) for v in meta["origin"].split(","))
    src = Image.open(export / "cold_max.pgm")
    w, h = src.size
    px = src.load()
    out = Image.new("L", (640, 640))
    dst = out.load()
    for y in range(640):
        z = W.SIZE_M - 16 * (y + 0.5)  # metres north
        gz = int((z - oz) // 16)
        if not 0 <= gz < h:
            continue
        for x in range(640):
            gx = int((16 * (x + 0.5) - ox) // 16)
            if 0 <= gx < w:
                dst[x, y] = px[gx, gz]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--textures", type=pathlib.Path, default=ROOT / "data" / "export" / "map")
    ap.add_argument("--out", type=pathlib.Path, default=ROOT / "app" / "assets" / "map")
    ap.add_argument("--size", type=int, default=4096)
    a = ap.parse_args()
    img = render(a.textures, a.size)
    a.out.mkdir(parents=True, exist_ok=True)
    img.resize((1024, 1024), Image.LANCZOS).save(a.out.parent / "map_preview.jpg", quality=85)
    levels = cut(img, a.out)
    shroud_levels(a.textures).save(a.out.parent / "shroud_levels.png", optimize=True)
    if (a.textures.parent / "cold.json").exists():
        cold_map(a.textures.parent).save(a.out.parent / "cold.png", optimize=True)
    if (a.textures.parent / "poi.tsv").exists():
        img, fit = height_map(a.textures, a.textures.parent)
        img.save(a.out.parent / "height.png", optimize=True)
        (a.out.parent / "height.json").write_text(json.dumps(fit), encoding="utf-8")
        print("height:", fit)
    total = sum(f.stat().st_size for f in a.out.rglob("*.jpg"))
    print(f"{a.out}: zoom 0..{levels}, {sum(1 for _ in a.out.rglob('*.jpg'))} tiles, {total // 1024} KB")


if __name__ == "__main__":
    main()
