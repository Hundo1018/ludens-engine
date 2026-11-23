"""A signed-distance-field font (ludens-engine #116): the `.lfont` atlas written by scripts/assets/convert_font.py, glyph
lookup, text layout, and the glyph quads a renderer draws.

A glyph is a cell of an 8-bit atlas; a texel is `128 + 128 * d / spread` with d the distance in atlas pixels to the
outline, positive inside. The renderer samples it bilinearly and turns the distance into coverage
(`coverage`), so one atlas serves any size (`size` is the em height in pixels; the atlas holds `em` pixels per em).

- `SdfFont` implements `GlyphMetrics`, so `ui.text.break_lines` wraps with real advances. Code point 0 of the file is a
  box outline: a code point the atlas does not hold draws as that box and is counted in `SdfFont.missing`
  (`append_text` increments it, `first_missing` keeps the first one).
- `append_text` turns a string into glyph quads: 6 vertices each, 8 floats per vertex (`x y u v r g b a`, `u v` in atlas
  texels), cut to a clip rectangle. The same function feeds the GPU (app/hud.mojo) and `render_text`, a software
  rasteriser that uses the arithmetic of the fragment shader (only + - * / and floor), so native and wasm64 produce the same bytes.

Standard library only; the file's bytes come from the caller (a file natively, the page in wasm).
"""
from std.memory import bitcast
from ui.draw import Color
from ui.geom import Rect
from ui.text import GlyphMetrics, Line, break_lines, decode_utf8

comptime MISSING_CP = 0
comptime GLYPH_VERT_FLOATS = 8
comptime GLYPH_QUAD_VERTS = 6
comptime _HEADER = 48
comptime _RECORD = 20


@fieldwise_init
struct Glyph(Copyable, ImplicitlyCopyable, Movable):
    var cp: Int
    var x: Int  # the cell in the atlas, texels
    var y: Int
    var w: Int  # 0 = no image (a space)
    var h: Int
    var xoff: Int  # cell top-left relative to the pen on the baseline, at the atlas em
    var yoff: Int
    var advance: Float32


def _u16(b: List[UInt8], o: Int) -> Int:
    return Int(b[o]) | (Int(b[o + 1]) << 8)


def _i16(b: List[UInt8], o: Int) -> Int:
    var v = _u16(b, o)
    return v - 65536 if v >= 32768 else v


def _u32(b: List[UInt8], o: Int) -> Int:
    return Int(b[o]) | (Int(b[o + 1]) << 8) | (Int(b[o + 2]) << 16) | (Int(b[o + 3]) << 24)


def _f32(b: List[UInt8], o: Int) -> Float32:
    return bitcast[DType.float32, 1](SIMD[DType.uint32, 1](UInt32(_u32(b, o)))).__getitem__(0)


def _floor(v: Float32) -> Int:
    var i = Int(v)  # truncates toward zero
    return i - 1 if Float32(i) > v else i


@fieldwise_init
struct FontMetrics(GlyphMetrics, Copyable, Movable):
    """The glyph table of a font without its atlas: what layout needs (advances, line height, wrapping). About 140 KB for
    the 5984-glyph Traditional Chinese font, so a game can keep its own copy (`GameMode.set_font_metrics`)."""
    var glyphs: List[Glyph]  # sorted by code point; glyphs[0] is the box (code point 0)
    var em: Float32  # pixels per em in the atlas
    var spread: Float32  # distance range in atlas pixels
    var ascent: Float32  # at em
    var descent: Float32
    var line_gap: Float32

    def index_of(self, cp: Int) -> Int:
        """The index of `cp` in `glyphs`, -1 if the atlas does not hold it."""
        var lo = 0
        var hi = len(self.glyphs) - 1
        while lo <= hi:
            var mid = (lo + hi) // 2
            var v = self.glyphs[mid].cp
            if v == cp:
                return mid
            if v < cp:
                lo = mid + 1
            else:
                hi = mid - 1
        return -1

    def has(self, cp: Int) -> Bool:
        return cp > 0 and self.index_of(cp) >= 0

    def glyph_for(self, cp: Int) -> Int:
        """The glyph that draws `cp`: its own, a space for a tab, else the box (index 0)."""
        var c = 0x20 if cp == 9 else cp
        var i = self.index_of(c)
        return i if (i >= 0 and c > 0) else 0

    def advance(self, cp: Int) -> Float32:
        """The advance at the atlas em (`GlyphMetrics`)."""
        return self.glyphs[self.glyph_for(cp)].advance

    def line_height(self, size: Float32) -> Float32:
        return (self.ascent + self.descent + self.line_gap) * size / self.em

    def measure(self, text: String, size: Float32) -> Float32:
        """The width of `text` on one line at em height `size` pixels (newlines count as zero)."""
        var cps = decode_utf8(text)
        var w = Float32(0)
        for i in range(len(cps)):
            if cps[i].value != 10:
                w += self.advance(cps[i].value)
        return w * size / self.em

    def wrap(self, text: String, size: Float32, max_width: Float32) -> List[Line]:
        """`break_lines` at `size` pixels: byte ranges, with widths in pixels."""
        var k = size / self.em
        var lines = break_lines(text, self, max_width / k)
        var out = List[Line]()
        for i in range(len(lines)):
            out.append(Line(lines[i].start, lines[i].end, lines[i].width * k))
        return out^

    def text_height(self, text: String, size: Float32, max_width: Float32) -> Float32:
        """The height of `text` wrapped to `max_width` (<= 0: not wrapped): lines times the line height."""
        var n = len(self.wrap(text, size, max_width if max_width > 0 else Float32(1e30)))
        return Float32(n) * self.line_height(size)

    def missing_in(self, text: String) -> List[Int]:
        """The distinct code points of `text` the atlas does not hold (whitespace and control characters excepted)."""
        var out = List[Int]()
        var cps = decode_utf8(text)
        for i in range(len(cps)):
            var cp = cps[i].value
            if cp < 0x20 or cp == 0x7F or self.has(cp):
                continue
            var seen = False
            for j in range(len(out)):
                if out[j] == cp:
                    seen = True
                    break
            if not seen:
                out.append(cp)
        return out^


struct SdfFont(GlyphMetrics, Movable):
    var data: List[UInt8]  # the whole file; the atlas starts at atlas_off
    var atlas_off: Int
    var atlas_w: Int
    var atlas_h: Int
    var m: FontMetrics
    var missing: Int  # code points drawn as the box since the last `reset_missing`
    var first_missing: Int  # the first of them, -1 = none

    def __init__(out self, var data: List[UInt8]) raises:
        if len(data) < _HEADER or data[0] != 76 or data[1] != 70 or data[2] != 78 or data[3] != 84:  # "LFNT"
            raise Error("sdf_font: not an .lfont file")
        if _u32(data, 4) != 1:
            raise Error("sdf_font: unsupported version " + String(_u32(data, 4)))
        self.atlas_w = _u32(data, 8)
        self.atlas_h = _u32(data, 12)
        var n = _u32(data, 16)
        self.atlas_off = (_HEADER + _RECORD * n + 15) // 16 * 16
        if n < 1 or len(data) != self.atlas_off + self.atlas_w * self.atlas_h:
            raise Error("sdf_font: file size does not match its header")
        var glyphs = List[Glyph]()
        var prev = -1
        for i in range(n):
            var o = _HEADER + _RECORD * i
            var g = Glyph(_u32(data, o), _u16(data, o + 4), _u16(data, o + 6), _u16(data, o + 8), _u16(data, o + 10),
                          _i16(data, o + 12), _i16(data, o + 14), _f32(data, o + 16))
            if g.cp <= prev:
                raise Error("sdf_font: glyph table is not sorted by code point")
            if g.w > 0 and (g.x + g.w > self.atlas_w or g.y + g.h > self.atlas_h):
                raise Error("sdf_font: a glyph cell is outside the atlas")
            prev = g.cp
            glyphs.append(g)
        if glyphs[0].cp != MISSING_CP:
            raise Error("sdf_font: the file has no box glyph (code point 0)")
        self.m = FontMetrics(glyphs^, _f32(data, 20), _f32(data, 24), _f32(data, 28), _f32(data, 32), _f32(data, 36))
        self.data = data^
        self.missing = 0
        self.first_missing = -1

    def index_of(self, cp: Int) -> Int:
        return self.m.index_of(cp)

    def has(self, cp: Int) -> Bool:
        return self.m.has(cp)

    def glyph_for(self, cp: Int) -> Int:
        return self.m.glyph_for(cp)

    def advance(self, cp: Int) -> Float32:
        return self.m.advance(cp)

    def line_height(self, size: Float32) -> Float32:
        return self.m.line_height(size)

    def measure(self, text: String, size: Float32) -> Float32:
        return self.m.measure(text, size)

    def wrap(self, text: String, size: Float32, max_width: Float32) -> List[Line]:
        return self.m.wrap(text, size, max_width)

    def text_height(self, text: String, size: Float32, max_width: Float32) -> Float32:
        return self.m.text_height(text, size, max_width)

    def missing_in(self, text: String) -> List[Int]:
        return self.m.missing_in(text)

    def reset_missing(mut self):
        self.missing = 0
        self.first_missing = -1

    def texel(self, x: Int, y: Int) -> Float32:
        """The atlas value at integer texel (x, y), 0..255, clamped to the atlas."""
        var cx = 0 if x < 0 else (self.atlas_w - 1 if x >= self.atlas_w else x)
        var cy = 0 if y < 0 else (self.atlas_h - 1 if y >= self.atlas_h else y)
        return Float32(Int(self.data[self.atlas_off + cy * self.atlas_w + cx]))


def _push(mut v: List[Float32], x: Float32, y: Float32, u: Float32, w: Float32, c: Color):
    v.append(x)
    v.append(y)
    v.append(u)
    v.append(w)
    v.append(c.r)
    v.append(c.g)
    v.append(c.b)
    v.append(c.a)


def _quad(mut v: List[Float32], x0: Float32, y0: Float32, x1: Float32, y1: Float32, u0: Float32, v0: Float32,
          u1: Float32, v1: Float32, c: Color, clip: Rect, clipped: Bool):
    var ax = x0
    var ay = y0
    var bx = x1
    var by = y1
    var au = u0
    var av = v0
    var bu = u1
    var bv = v1
    if clipped:
        var cx0 = clip.x if clip.x > ax else ax
        var cy0 = clip.y if clip.y > ay else ay
        var cx1 = clip.right() if clip.right() < bx else bx
        var cy1 = clip.bottom() if clip.bottom() < by else by
        if not (cx1 > cx0 and cy1 > cy0):
            return
        var fu = (u1 - u0) / (x1 - x0)
        var fv = (v1 - v0) / (y1 - y0)
        au = u0 + (cx0 - x0) * fu
        bu = u0 + (cx1 - x0) * fu
        av = v0 + (cy0 - y0) * fv
        bv = v0 + (cy1 - y0) * fv
        ax = cx0
        ay = cy0
        bx = cx1
        by = cy1
    _push(v, ax, ay, au, av, c)
    _push(v, bx, ay, bu, av, c)
    _push(v, ax, by, au, bv, c)
    _push(v, bx, ay, bu, av, c)
    _push(v, bx, by, bu, bv, c)
    _push(v, ax, by, au, bv, c)


def append_text(
    mut verts: List[Float32], mut font: SdfFont, rect: Rect, text: String, c: Color, size: Float32, clip: Rect, clipped: Bool,
):
    """Glyph quads for `text` with its top-left at (rect.x, rect.y), em height `size` pixels, wrapped to `rect.w` when
    that is > 0 (a `\\n` always breaks). Each line is `line_height(size)` below the last. A code point the atlas does not
    hold draws as the box and increments `font.missing`."""
    var k = size / font.m.em
    var lines = font.wrap(text, size, rect.w) if rect.w > 0 else font.wrap(text, size, Float32(1e30))
    var cps = decode_utf8(text)
    var ci = 0
    var lh = font.line_height(size)
    for li in range(len(lines)):
        var pen = rect.x
        var base = rect.y + font.m.ascent * k + Float32(li) * lh
        while ci < len(cps) and cps[ci].start < lines[li].start:
            ci += 1
        while ci < len(cps) and cps[ci].start < lines[li].end:
            var cp = cps[ci].value
            ci += 1
            if cp < 0x20 and cp != 9:
                continue
            var gi = font.glyph_for(cp)
            if gi == 0:
                font.missing += 1
                if font.first_missing < 0:
                    font.first_missing = cp
            var g = font.m.glyphs[gi]
            if g.w > 0:
                var x0 = pen + Float32(g.xoff) * k
                var y0 = base + Float32(g.yoff) * k
                _quad(verts, x0, y0, x0 + Float32(g.w) * k, y0 + Float32(g.h) * k, Float32(g.x), Float32(g.y),
                      Float32(g.x + g.w), Float32(g.y + g.h), c, clip, clipped)
            pen += g.advance * k


def sample(font: SdfFont, u: Float32, v: Float32) -> Float32:
    """The distance at atlas position (u, v) in texels, bilinear: atlas pixels, positive inside (the fragment shader's `sample`)."""
    var fu = u - 0.5
    var fv = v - 0.5
    var ix = _floor(fu)
    var iy = _floor(fv)
    var tx = fu - Float32(ix)
    var ty = fv - Float32(iy)
    var a = font.texel(ix, iy)
    var b = font.texel(ix + 1, iy)
    var c = font.texel(ix, iy + 1)
    var d = font.texel(ix + 1, iy + 1)
    var s = (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
    return (s - 128.0) * font.m.spread / 128.0


def coverage(dist: Float32, texels_per_pixel: Float32) -> Float32:
    """Edge coverage 0..1 for a distance in atlas pixels when one screen pixel spans `texels_per_pixel` texels."""
    var t = dist / texels_per_pixel + 0.5
    return 0.0 if t < 0 else (1.0 if t > 1 else t)


def render_text(
    mut font: SdfFont, text: String, size: Float32, max_width: Float32, width: Int, height: Int,
) -> List[UInt8]:
    """Rasterise `text` at (0, 0) into a width x height coverage image (one byte per pixel, 255 = fully covered) by
    the same sampling and coverage as the fragment shader."""
    var verts = List[Float32]()
    append_text(verts, font, Rect(0, 0, max_width, 0), text, Color.rgb(1, 1, 1), size, Rect(0, 0, 0, 0), False)
    var img = List[UInt8](length=width * height, fill=0)
    var f = GLYPH_VERT_FLOATS
    for q in range(len(verts) // (f * GLYPH_QUAD_VERTS)):
        var o = q * f * GLYPH_QUAD_VERTS
        var x0 = verts[o]
        var y0 = verts[o + 1]
        var u0 = verts[o + 2]
        var v0 = verts[o + 3]
        var x1 = verts[o + 4 * f]  # vertex 4 is the bottom-right corner
        var y1 = verts[o + 4 * f + 1]
        var u1 = verts[o + 4 * f + 2]
        var v1 = verts[o + 4 * f + 3]
        var tpp = (u1 - u0) / (x1 - x0)
        var py0 = max(0, _floor(y0))
        var py1 = min(height - 1, _floor(y1))
        var px0 = max(0, _floor(x0))
        var px1 = min(width - 1, _floor(x1))
        for py in range(py0, py1 + 1):
            for px in range(px0, px1 + 1):
                var cx = Float32(px) + 0.5
                var cy = Float32(py) + 0.5
                if cx < x0 or cx >= x1 or cy < y0 or cy >= y1:
                    continue
                var u = u0 + (cx - x0) * (u1 - u0) / (x1 - x0)
                var v = v0 + (cy - y0) * (v1 - v0) / (y1 - y0)
                var cov = coverage(sample(font, u, v), tpp)
                var val = Int(cov * 255.0 + 0.5)
                var idx = py * width + px
                if val > Int(img[idx]):
                    img[idx] = UInt8(val)
    return img^


def hash_bytes(b: List[UInt8]) -> UInt64:
    var h = UInt64(0xCBF29CE484222325)
    for i in range(len(b)):
        h = (h ^ UInt64(b[i])) * UInt64(0x100000001B3)
    return h
