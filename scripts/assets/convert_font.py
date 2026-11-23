#!/usr/bin/env python3
"""Convert a TTF / OTF into the engine's SDF font format (.lfont, v1; read by ui/sdf_font.mojo).

Usage:
  python3 scripts/assets/convert_font.py <font.otf> <out.lfont> [--em 24] [--spread 4] [--extra "text"]
  python3 scripts/assets/convert_font.py --selftest

Glyph set (the same for every font, so two fonts are interchangeable at run time):
  U+0020-007E and U+00A0-00FF (Latin, with the accented letters pseudo-localization uses),
  Big5 symbols 0xA140-0xA3BF (full-width punctuation, Bopomofo, arrows, math: 408 code points),
  Big5 level 1 ideographs 0xA440-0xC67E (the 5401 most frequently used Traditional Chinese characters),
  plus every character of --extra. A code point the font has no outline for is left out and printed.
Code point 0 is always present: a box outline, drawn for any character the atlas does not hold.

Each glyph is rendered at 2x, thresholded, turned into a signed distance (exact Euclidean distance to the nearest pixel on
the other side, searched up to `spread` atlas pixels) and averaged down to the atlas size. A texel is
clamp(128 + 128 * d / spread, 0, 255) with d in atlas pixels, positive inside the outline: 128 is the outline.
Needs Pillow with FreeType (pinned in pixi.toml) and numpy.

Format (little-endian):
  0   magic b"LFNT"; u32 version = 1; u32 atlas_w; u32 atlas_h; u32 glyph_count
  20  f32 em (px size of the glyphs in the atlas); f32 spread (px); f32 ascent; f32 descent; f32 line_gap (px at em)
  40  8 zero bytes
  48  glyph_count records of 20 bytes, sorted by code point:
        u32 code point; u16 x, y, w, h (the glyph's cell in the atlas, padding included; w = h = 0: no image);
        i16 xoff, yoff (cell top-left relative to the pen on the baseline, px at em; yoff < 0 is above it); f32 advance
  then, from the next 16-byte boundary, atlas_w * atlas_h bytes of u8 distance, row-major, top row first.
"""
import argparse
import hashlib
import math
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

MAGIC = b"LFNT"
VERSION = 1
HEADER_BYTES = 48
RECORD_BYTES = 20
SS = 2  # supersampling of the source rendering
ATLAS_W = 2048
GAP = 1  # empty texels between two cells


def big5_range(lo: int, hi: int) -> list[str]:
    out = []
    for b1 in range(lo >> 8, (hi >> 8) + 1):
        for b2 in list(range(0x40, 0x7F)) + list(range(0xA1, 0xFF)):
            code = (b1 << 8) | b2
            if lo <= code <= hi:
                try:
                    out.append(bytes([b1, b2]).decode("big5"))
                except UnicodeDecodeError:
                    pass
    return out


def charset(extra: str) -> list[str]:
    chars = [chr(c) for c in range(0x20, 0x7F)] + [chr(c) for c in range(0xA0, 0x100)]
    chars += big5_range(0xA140, 0xA3BF) + big5_range(0xA440, 0xC67E)
    chars += list(extra)
    return sorted({c for c in chars if ord(c) > 0})


def edt_to(feature: np.ndarray, radius: int) -> np.ndarray:
    """Euclidean distance from each pixel to the nearest True pixel, exact up to `radius`, `radius + 1` beyond."""
    h, w = feature.shape
    far = radius + 1
    pad = np.pad(feature, ((radius, radius), (0, 0)), constant_values=False)
    col = np.full((h, w), far, dtype=np.float32)
    for dy in range(-radius, radius + 1):
        hit = pad[radius + dy:radius + dy + h, :]
        col = np.where(hit, np.minimum(col, abs(dy)), col)
    padc = np.pad(col, ((0, 0), (radius, radius)), constant_values=far)
    best = np.full((h, w), float(far * far), dtype=np.float32)
    for dx in range(-radius, radius + 1):
        g = padc[:, radius + dx:radius + dx + w]
        best = np.minimum(best, dx * dx + g * g)
    return np.minimum(np.sqrt(best), far)


def sdf_cell(mask: np.ndarray, spread: int) -> np.ndarray:
    """u8 cell (h / SS x w / SS) from a boolean mask rendered at SS times the atlas size."""
    r = spread * SS
    d_out = edt_to(~mask, r)  # for an inside pixel: distance to the nearest outside pixel
    d_in = edt_to(mask, r)
    sd = np.where(mask, d_out - 0.5, -(d_in - 0.5)) / SS  # atlas pixels, positive inside
    h, w = sd.shape
    sd = sd.reshape(h // SS, SS, w // SS, SS).mean(axis=(1, 3))
    return np.clip(np.floor(128.0 + 128.0 * sd / spread + 0.5), 0, 255).astype(np.uint8)


class Glyph:
    def __init__(self, cp: int, advance: float, cell: np.ndarray | None, xoff: int, yoff: int):
        self.cp = cp
        self.advance = advance
        self.cell = cell
        self.xoff = xoff
        self.yoff = yoff
        self.x = self.y = 0


def render(font, ch: str, spread: int, em: int) -> Glyph | None:
    """The glyph of `ch` at SS x em, or None when the font has no outline for it. `font` is loaded at em * SS."""
    adv = font.getlength(ch) / SS
    x0, y0, x1, y1 = font.getbbox(ch, anchor="ls")
    if x1 <= x0 or y1 <= y0:
        return Glyph(ord(ch), adv, None, 0, 0)
    ox = math.floor(x0 / SS) - spread
    oy = math.floor(y0 / SS) - spread
    w = math.ceil(x1 / SS) + spread - ox
    h = math.ceil(y1 / SS) + spread - oy
    img = Image.new("L", (w * SS, h * SS), 0)
    ImageDraw.Draw(img).text((-ox * SS, -oy * SS), ch, font=font, fill=255, anchor="ls")
    mask = np.asarray(img) >= 128
    return Glyph(ord(ch), adv, sdf_cell(mask, spread), ox, oy)


def missing_box(em: int, spread: int) -> Glyph:
    """Code point 0: a hollow box 0.5 em wide and 0.7 em high on the baseline, stroke em / 12."""
    bw, bh, st = round(0.5 * em), round(0.7 * em), max(1, round(em / 12))
    ox, oy = round(0.05 * em) - spread, -bh - spread
    w, h = bw + 2 * spread, bh + 2 * spread
    img = Image.new("L", (w * SS, h * SS), 0)
    d = ImageDraw.Draw(img)
    x0, y0 = spread * SS, spread * SS
    x1, y1 = (spread + bw) * SS - 1, (spread + bh) * SS - 1
    d.rectangle((x0, y0, x1, y1), fill=255)
    d.rectangle((x0 + st * SS, y0 + st * SS, x1 - st * SS, y1 - st * SS), fill=0)
    return Glyph(0, 0.6 * em, sdf_cell(np.asarray(img) >= 128, spread), ox, oy)


def has_outline(font, ch: str, notdef: bytes) -> bool:
    if ch.isspace():
        return True
    m = font.getmask(ch)
    return m.getbbox() is not None and bytes(m) != notdef


def pack(glyphs: list[Glyph]) -> tuple[int, int]:
    """Shelf packing, tallest first; sets x, y on every glyph that has a cell. Returns the atlas size."""
    todo = sorted((g for g in glyphs if g.cell is not None), key=lambda g: (-g.cell.shape[0], g.cp))
    x = y = shelf = 0
    for g in todo:
        h, w = g.cell.shape
        if x + w > ATLAS_W:
            x, y, shelf = 0, y + shelf + GAP, 0
        g.x, g.y = x, y
        x += w + GAP
        shelf = max(shelf, h)
    return ATLAS_W, (y + shelf + 15) // 16 * 16


def build(font_path: str | None, em: int, spread: int, extra: str, chars: list[str] | None = None) -> tuple[bytes, dict]:
    big = ImageFont.load_default(em * SS) if font_path is None else ImageFont.truetype(font_path, em * SS)
    notdef = bytes(big.getmask(""))
    glyphs, skipped = [missing_box(em, spread)], []
    for ch in chars if chars is not None else charset(extra):
        if not has_outline(big, ch, notdef):
            skipped.append(ch)
            continue
        glyphs.append(render(big, ch, spread, em))
    glyphs.sort(key=lambda g: g.cp)
    aw, ah = pack(glyphs)
    atlas = np.zeros((ah, aw), dtype=np.uint8)
    atlas[:] = 0
    for g in glyphs:
        if g.cell is not None:
            h, w = g.cell.shape
            atlas[g.y:g.y + h, g.x:g.x + w] = g.cell
    asc, desc = big.getmetrics()
    line_gap = 0.0
    out = bytearray()
    out += MAGIC + struct.pack("<IIII", VERSION, aw, ah, len(glyphs))
    out += struct.pack("<fffff", float(em), float(spread), asc / SS, desc / SS, line_gap)
    out += bytes(8)
    for g in glyphs:
        h, w = g.cell.shape if g.cell is not None else (0, 0)
        out += struct.pack("<IHHHHhhf", g.cp, g.x, g.y, w, h, g.xoff, g.yoff, g.advance)
    out += bytes(-len(out) % 16)
    out += atlas.tobytes()
    stats = {"glyphs": len(glyphs), "atlas": (aw, ah), "bytes": len(out), "skipped": skipped,
             "ink": sum(1 for g in glyphs if g.cell is not None)}
    return bytes(out), stats


def selftest() -> int:
    """Pillow's bundled font, ASCII only: the file parses back, the outline is at 128, inside is brighter than outside."""
    chars = [chr(c) for c in range(0x20, 0x7F)]
    data, st = build(None, 24, 4, "", chars)
    assert data[:4] == MAGIC and struct.unpack_from("<I", data, 4)[0] == VERSION
    aw, ah, n = struct.unpack_from("<III", data, 8)
    assert (aw, ah) == st["atlas"] and n == len(chars) + 1, (aw, ah, n)
    atlas_off = (HEADER_BYTES + RECORD_BYTES * n + 15) // 16 * 16
    assert len(data) == atlas_off + aw * ah
    atlas = np.frombuffer(data, dtype=np.uint8, offset=atlas_off).reshape(ah, aw)
    cps, boxes = [], {}
    for i in range(n):
        cp, x, y, w, h, xo, yo, adv = struct.unpack_from("<IHHHHhhf", data, HEADER_BYTES + RECORD_BYTES * i)
        cps.append(cp)
        boxes[cp] = (x, y, w, h)
        assert adv > 0
    assert cps == sorted(cps) and cps[0] == 0
    x, y, w, h = boxes[ord("I")]
    cell = atlas[y:y + h, x:x + w].astype(int)
    assert cell[0, 0] < 128 and cell.max() > 140, "the corner is outside and the stem is inside"
    assert (cell[:, 0] == 0).all(), "the padding column is fully outside"
    x, y, w, h = boxes[0]
    box = atlas[y:y + h, x:x + w]
    assert box.shape[0] > 10 and box[h // 2, w // 2] < 128, "the box is hollow"
    assert build(None, 24, 4, "", chars)[0] == data, "two runs give the same bytes"
    print(f"convert_font selftest: ok ({n} glyphs, atlas {aw}x{ah}, {len(data)} bytes)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("font", nargs="?")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--em", type=int, default=24)
    ap.add_argument("--spread", type=int, default=4)
    ap.add_argument("--extra", default="")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not (a.font and a.out):
        ap.error("font and out are required")
    data, st = build(a.font, a.em, a.spread, a.extra)
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_bytes(data)
    print(f"{a.out}: {st['glyphs']} glyphs ({st['ink']} with an image), atlas {st['atlas'][0]}x{st['atlas'][1]}, "
          f"{st['bytes']} bytes, sha256 {hashlib.sha256(data).hexdigest()}")
    if st["skipped"]:
        print(f"skipped {len(st['skipped'])} code points the font has no outline for: " + "".join(st["skipped"][:60]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
