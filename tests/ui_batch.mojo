"""Draw list to batches (ludens-engine #17): vertex counts, positions, strokes, nested clips, text runs.
Standard library only. `pixi run -e wasm test-ui`."""
from ui.batch import FLOATS_PER_VERTEX, build_batch
from ui.draw import Color, DrawList
from ui.geom import Rect


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


def main() raises:
    var c = Check()
    var red = Color.rgb(1, 0, 0)
    var blue = Color.rgb(0, 0, 1)

    # one fill: two triangles covering the rectangle
    var l = DrawList()
    l.fill(Rect(10, 20, 30, 40), red)
    var b = build_batch(l)
    c.ok(b.vertex_count() == 6 and len(b.segments) == 1 and b.segments[0].vertex_count == 6 and not b.segments[0].clipped, "a fill is 6 vertices in one unclipped segment")
    var minx = b.verts[0]
    var maxx = b.verts[0]
    var miny = b.verts[1]
    var maxy = b.verts[1]
    for v in range(6):
        var x = b.verts[v * FLOATS_PER_VERTEX]
        var y = b.verts[v * FLOATS_PER_VERTEX + 1]
        minx = x if x < minx else minx
        maxx = x if x > maxx else maxx
        miny = y if y < miny else miny
        maxy = y if y > maxy else maxy
    c.ok(minx == 10 and maxx == 40 and miny == 20 and maxy == 60, "the vertices span x 10..40, y 20..60")
    c.ok(b.verts[2] == 1 and b.verts[3] == 0 and b.verts[5] == 1, "the colour rides on every vertex (r, g, b, a)")

    # degenerate rectangles produce nothing
    l = DrawList()
    l.fill(Rect(0, 0, 0, 10), red)
    l.fill(Rect(0, 0, 10, -1), red)
    c.ok(build_batch(l).vertex_count() == 0, "a rectangle with no area draws nothing")

    # a stroke: four rectangles, none overlapping
    l = DrawList()
    l.stroke(Rect(0, 0, 20, 10), blue, 2)
    b = build_batch(l)
    c.ok(b.vertex_count() == 24, "a stroke is four rectangles (24 vertices)")
    l = DrawList()
    l.stroke(Rect(0, 0, 3, 10), blue, 2)
    c.ok(build_batch(l).vertex_count() == 6, "a stroke thicker than half the width is one solid rectangle")

    # clips cut segments; nested clips intersect; popping restores
    l = DrawList()
    l.fill(Rect(0, 0, 10, 10), red)
    l.push_clip(Rect(0, 0, 50, 50))
    l.fill(Rect(5, 5, 10, 10), red)
    l.push_clip(Rect(20, 20, 100, 100))
    l.fill(Rect(25, 25, 10, 10), blue)
    l.pop_clip()
    l.fill(Rect(6, 6, 10, 10), blue)
    l.pop_clip()
    l.fill(Rect(1, 1, 5, 5), red)
    b = build_batch(l)
    c.ok(len(b.segments) == 5, "five segments: open, clip, nested clip, back in the first clip, open again")
    c.ok(not b.segments[0].clipped and b.segments[1].clipped and b.segments[1].scissor.w == 50, "the first clip is 50 wide")
    c.ok(b.segments[2].scissor.x == 20 and b.segments[2].scissor.w == 30 and b.segments[2].scissor.h == 30, "the nested clip is the intersection: x 20, 30 x 30")
    c.ok(b.segments[3].scissor.w == 50 and b.segments[4].clipped == False, "popping restores the outer clip, then no clip")
    var total = 0
    var contiguous = True
    for i in range(len(b.segments)):
        if b.segments[i].first_vertex != total:
            contiguous = False
        total += b.segments[i].vertex_count
    c.ok(total == b.vertex_count() and contiguous, "segments cover the vertex array exactly, in order")

    # a clip that does not overlap draws into an empty scissor; an unbalanced pop is ignored
    l = DrawList()
    l.pop_clip()
    l.push_clip(Rect(0, 0, 10, 10))
    l.push_clip(Rect(50, 50, 10, 10))
    l.fill(Rect(0, 0, 100, 100), red)
    b = build_batch(l)
    c.ok(len(b.segments) == 1 and b.segments[0].scissor.w == 0 and b.segments[0].scissor.h == 0, "disjoint clips intersect to an empty scissor; a stray pop is ignored")

    # text runs keep their segment
    l = DrawList()
    l.text(Rect(0, 0, 50, 20), "hello", red, 14)
    l.push_clip(Rect(0, 0, 30, 20))
    l.text(Rect(0, 0, 50, 20), "clipped", blue, 12)
    b = build_batch(l)
    c.ok(len(b.texts) == 2 and b.texts[0].text == "hello" and b.texts[0].segment == 0 and b.texts[1].segment == 1 and b.segments[b.texts[1].segment].scissor.w == 30, "text runs carry string, colour and the scissor of their segment")
    c.ok(b.texts[1].size == 12 and b.texts[1].color.b == 1, "size and colour are kept")

    print("ui_batch:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("ui_batch: " + String(c.failed) + " checks failed")
