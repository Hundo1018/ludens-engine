"""The SDF font (ui/sdf_font.mojo) on the committed atlas assets/fonts/NotoSansTC-Regular-24.lfont: it parses, holds the
Traditional Chinese the issue asks for, wraps with real advances, counts a missing glyph and draws the box for it, and
rasterises the same text to the same bytes at three sizes. Standard library only. `pixi run -e wasm test-ui`."""
from ui.batch import build_batch_font
from ui.draw import Color, DrawList
from ui.geom import Rect
from ui.sdf_font import GLYPH_QUAD_VERTS, GLYPH_VERT_FLOATS, SdfFont, append_text, hash_bytes, render_text

comptime FONT = "assets/fonts/NotoSansTC-Regular-24.lfont"
comptime TC = "臺灣繁體中文字型測試：永遠的鬱，「你好」、。！？（）"


struct Check:
    var passed: Int
    var failed: Int

    def __init__(out self):
        self.passed = 0
        self.failed = 0

    def ok(mut self, cond: Bool, label: String):
        if cond:
            self.passed += 1
        else:
            self.failed += 1
            print("  [FAIL]", label)


def load() raises -> SdfFont:
    with open(FONT, "r") as f:
        return SdfFont(f.read_bytes())


def ink(img: List[UInt8]) -> Int:
    var n = 0
    for i in range(len(img)):
        if img[i] >= 128:
            n += 1
    return n


def picture(img: List[UInt8], w: Int, h: Int) -> String:
    var out = String()
    for y in range(h):
        for x in range(w):
            var v = Int(img[y * w + x])
            out += "#" if v >= 192 else ("+" if v >= 128 else ("." if v >= 48 else " "))
        out += "\n"
    return out


def main() raises:
    var c = Check()
    var font = load()
    print("  atlas", font.atlas_w, "x", font.atlas_h, ",", len(font.m.glyphs), "glyphs, em", font.m.em, "spread", font.m.spread)
    c.ok(font.atlas_w == 2048 and len(font.m.glyphs) == 5984, "the committed atlas: 2048 wide, 5984 glyphs")
    c.ok(font.m.em == 24 and font.m.spread == 4, "em 24, spread 4")

    # coverage of the requested set
    var absent = font.missing_in(TC)
    c.ok(len(absent) == 0, "every character of the Traditional Chinese sample is in the atlas (" + String(len(absent)) + " absent)")
    c.ok(len(font.missing_in("The quick brown fox 0123456789 àéîõü ÀÉÎÕÜ ñç")) == 0, "Latin and the accented letters pseudo-localization uses")
    c.ok(len(font.missing_in("\t\n")) == 0, "tab and newline are not 'missing'")
    c.ok(len(font.missing_in("😀ก")) == 2, "an emoji and a Thai letter are not in the atlas")

    # metrics
    c.ok(font.advance(0x6C38) == 24 and font.advance(0x3002) == 24, "an ideograph and a full-width stop advance one em")
    c.ok(font.advance(Int(ord("i"))) < font.advance(Int(ord("m"))), "proportional Latin: i is narrower than m")
    c.ok(font.advance(9) == font.advance(32), "a tab advances like a space")
    c.ok(font.measure("永遠", 48) == 96 and font.measure("永遠", 12) == 24, "measure scales with size")
    var lines = font.wrap("永遠的臺灣繁體中文", 24, 24 * 4)
    c.ok(len(lines) == 3 and lines[0].width == 96, "9 ideographs at 24 px in 96 px: 4 + 4 + 1 (" + String(len(lines)) + " lines)")
    var lines2 = font.wrap("永遠的臺灣繁體中文", 48, 24 * 4)
    c.ok(len(lines2) == 5, "the same text at 48 px in the same width: 2 per line, 5 lines (" + String(len(lines2)) + ")")

    # a missing glyph: visible box, counted
    var verts = List[Float32]()
    font.reset_missing()
    append_text(verts, font, Rect(0, 0, 0, 0), "A😀ก", Color.rgb(1, 1, 1), 24, Rect(0, 0, 0, 0), False)
    c.ok(font.missing == 2 and font.first_missing == 0x1F600, "two code points counted as missing, the first is U+1F600")
    c.ok(len(verts) == 3 * GLYPH_QUAD_VERTS * GLYPH_VERT_FLOATS, "A and two boxes: 3 quads (a visible fallback, not nothing)")
    var box = font.m.glyphs[0]
    c.ok(verts[GLYPH_QUAD_VERTS * GLYPH_VERT_FLOATS + 2] == Float32(box.x), "the second quad samples the box glyph's cell")
    font.reset_missing()
    var v2 = List[Float32]()
    append_text(v2, font, Rect(0, 0, 0, 0), TC + " Taiwan\n 123", Color.rgb(1, 1, 1), 24, Rect(0, 0, 0, 0), False)
    c.ok(font.missing == 0, "the Traditional Chinese sample draws with 0 missing glyphs")

    # clipping keeps every vertex inside the clip rectangle
    var v3 = List[Float32]()
    var clip = Rect(10, 5, 30, 20)
    append_text(v3, font, Rect(0, 0, 0, 0), "臺灣繁體", Color.rgb(1, 1, 1), 24, clip, True)
    var inside = len(v3) > 0
    for i in range(len(v3) // GLYPH_VERT_FLOATS):
        var x = v3[i * GLYPH_VERT_FLOATS]
        var y = v3[i * GLYPH_VERT_FLOATS + 1]
        if x < clip.x or x > clip.right() or y < clip.y or y > clip.bottom():
            inside = False
    c.ok(inside, "clipped quads stay inside the clip rectangle")

    # a draw list through the batch builder
    var dl = DrawList()
    dl.fill(Rect(0, 0, 200, 40), Color.rgb(0, 0, 0))
    dl.text(Rect(4, 4, 0, 0), "永遠 Ab", Color.rgb(1, 1, 1), 24)
    dl.push_clip(Rect(0, 0, 30, 40))
    dl.text(Rect(4, 4, 0, 0), "臺灣", Color.rgb(1, 1, 1), 24)
    dl.pop_clip()
    font.reset_missing()
    var batch = build_batch_font(dl, font)
    var expect = (4 + 2) * GLYPH_QUAD_VERTS * GLYPH_VERT_FLOATS  # 永 遠 A b, then 臺 and 灣 cut by the clip: 灣 starts at x = 28
    c.ok(len(batch.glyph_verts) == expect, "draw list -> 1 fill, 4 glyph quads, then 2 clipped ones (" + String(len(batch.glyph_verts) // (GLYPH_QUAD_VERTS * GLYPH_VERT_FLOATS)) + " quads)")
    var max_x = Float32(0)
    for i in range(4 * GLYPH_QUAD_VERTS, len(batch.glyph_verts) // GLYPH_VERT_FLOATS):
        var x = batch.glyph_verts[i * GLYPH_VERT_FLOATS]
        max_x = x if x > max_x else max_x
    c.ok(max_x <= 30 and batch.vertex_count() == 6, "the clipped run ends at x = 30; the fill is 6 vertices")

    # rasterised text, three sizes
    var ink16 = 0
    var ink24 = 0
    var ink48 = 0
    var h24 = UInt64(0)
    for pass_ in range(2):
        var a = render_text(font, "永", 24, 0, 32, 32)
        var b = render_text(font, "永", 48, 0, 64, 64)
        var d = render_text(font, "永", 16, 0, 24, 24)
        ink24 = ink(a)
        ink48 = ink(b)
        ink16 = ink(d)
        if pass_ == 0:
            h24 = hash_bytes(a)
        else:
            c.ok(hash_bytes(a) == h24, "rendering twice gives the same bytes")
    print("  ink pixels of 永: 16 px", ink16, ", 24 px", ink24, ", 48 px", ink48)
    c.ok(ink24 > 80 and ink24 < 500, "永 at 24 px covers a plausible area")
    var ratio = Float32(ink48) / Float32(ink24)
    c.ok(ratio > 3.0 and ratio < 5.0, "doubling the size roughly quadruples the area (ratio " + String(ratio) + ")")
    var sp = render_text(font, " ", 24, 0, 16, 16)
    c.ok(ink(sp) == 0, "a space has no ink")
    var bx = render_text(font, "😀", 24, 0, 24, 24)
    c.ok(ink(bx) > 20, "the missing-glyph box has ink (" + String(ink(bx)) + " pixels)")
    print(picture(render_text(font, "臺灣", 24, 0, 52, 30), 52, 30))
    print(picture(render_text(font, "Aa永", 16, 0, 36, 20), 36, 20))
    print("ui_sdf_font:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("ui_sdf_font: " + String(c.failed) + " checks failed")
