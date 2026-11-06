"""ui/ layout and focus navigation (ludens-shell #17). Standard library only: `ui/` stands alone.

Expected rectangles in the first cases are worked out by hand; the last cases are properties over generated trees
(inside the parent, siblings do not overlap, the same tree gives the same bits) and a pinned hash.

Build and run: `pixi run -e wasm test-ui`."""
from ui.focus import DIR_DOWN, DIR_LEFT, DIR_RIGHT, DIR_UP, focus_next
from ui.geom import Insets, Rect
from ui.layout import (
    ALIGN_CENTER,
    ALIGN_START,
    COLUMN,
    JUSTIFY_CENTER,
    JUSTIFY_END,
    JUSTIFY_SPACE_BETWEEN,
    ROW,
    Node,
    Tree,
)
from ui.testing import Lcg, box, hash_tree, random_tree


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

    def eqi_zero(mut self, got: Int, label: String):
        self.ok(got == 0, label + " (violations: " + String(got) + ")")

    def near(mut self, got: Float32, want: Float32, label: String):
        var d = got - want
        if d < 0:
            d = -d
        self.ok(d <= 1e-4, label + " (got " + String(got) + " want " + String(want) + ")")

    def rect(mut self, r: Rect, x: Float32, y: Float32, w: Float32, h: Float32, label: String):
        self.near(r.x, x, label + ".x")
        self.near(r.y, y, label + ".y")
        self.near(r.w, w, label + ".w")
        self.near(r.h, h, label + ".h")


def inside(inner: Rect, outer: Rect) -> Bool:
    return inner.x >= outer.x - 1e-3 and inner.y >= outer.y - 1e-3 and inner.right() <= outer.right() + 1e-3 and inner.bottom() <= outer.bottom() + 1e-3


def main() raises:
    var c = Check()

    # 1. A row of fixed widths with padding and a gap; the cross axis stretches.
    var t1 = Tree()
    var root = box(ROW, 300, 100)
    root.padding = Insets.all(5)
    root.gap = 10
    var r1 = t1.add(root^)
    _ = t1.add(box(ROW, 100), r1)
    _ = t1.add(box(ROW, 50), r1)
    _ = t1.add(box(ROW, 25), r1)
    t1.layout(r1, Rect(0, 0, 300, 100))
    c.rect(t1.rect(1), 5, 5, 100, 90, "row child 0")
    c.rect(t1.rect(2), 115, 5, 50, 90, "row child 1")
    c.rect(t1.rect(3), 175, 5, 25, 90, "row child 2")

    # 2. Grow shares the space left over by weight: 400 - 100 = 300 split 1 : 3.
    var t2 = Tree()
    var r2 = t2.add(box(ROW, 400, 50))
    _ = t2.add(box(ROW, 100), r2)
    _ = t2.add(box(ROW, -1, -1, 1), r2)
    _ = t2.add(box(ROW, -1, -1, 3), r2)
    t2.layout(r2, Rect(0, 0, 400, 50))
    c.rect(t2.rect(1), 0, 0, 100, 50, "grow fixed")
    c.rect(t2.rect(2), 100, 0, 75, 50, "grow 1")
    c.rect(t2.rect(3), 175, 0, 225, 50, "grow 3")

    # 3. A column that centres its children across; sizes come from the content.
    var t3 = Tree()
    var col = box(COLUMN, 200, 300)
    col.align = ALIGN_CENTER
    var r3 = t3.add(col^)
    var a = Node()
    a.content_w = 100
    a.content_h = 40
    _ = t3.add(a^, r3)
    var b = Node()
    b.content_w = 60
    b.content_h = 20
    _ = t3.add(b^, r3)
    t3.layout(r3, Rect(0, 0, 200, 300))
    c.rect(t3.rect(1), 50, 0, 100, 40, "centred child 0")
    c.rect(t3.rect(2), 70, 40, 60, 20, "centred child 1")

    # 4. Justify: space-between, center, end.
    for j in range(3):
        var t = Tree()
        var rw = box(ROW, 350, 20)
        rw.justify = JUSTIFY_SPACE_BETWEEN if j == 0 else (JUSTIFY_CENTER if j == 1 else JUSTIFY_END)
        rw.align = ALIGN_START
        var rid = t.add(rw^)
        for _ in range(3):
            _ = t.add(box(ROW, 50, 20), rid)
        t.layout(rid, Rect(0, 0, 350, 20))
        if j == 0:
            c.near(t.rect(1).x, 0, "space-between first")
            c.near(t.rect(2).x, 150, "space-between middle")
            c.near(t.rect(3).x, 300, "space-between last")
        elif j == 1:
            c.near(t.rect(1).x, 100, "center first")
            c.near(t.rect(3).x, 200, "center last")
        else:
            c.near(t.rect(1).x, 200, "end first")
            c.near(t.rect(3).x, 300, "end last")

    # 5. Overflow shrinks children in proportion to their size: three of 200 in 400.
    var t5 = Tree()
    var r5 = t5.add(box(ROW, 400, 40))
    for _ in range(3):
        var n = Node()
        n.content_w = 200
        n.content_h = 10
        _ = t5.add(n^, r5)
    t5.layout(r5, Rect(0, 0, 400, 40))
    c.near(t5.rect(1).w, 400.0 / 3.0, "shrunk width")
    c.near(t5.rect(2).x, 400.0 / 3.0, "second child starts after the first")
    c.near(t5.rect(3).right(), 400, "the row is exactly filled")

    # 6. Bad input raises and adds nothing.
    var t6 = Tree()
    var bad = box(ROW, Float32(0) / Float32(0))
    var raised = False
    try:
        _ = t6.add(bad^)
    except:
        raised = True
    c.ok(raised and len(t6.nodes) == 0, "a NaN width raises and adds no node")
    raised = False
    try:
        _ = t6.add(box(ROW), 5)
    except:
        raised = True
    c.ok(raised, "a parent that does not exist raises")

    # 7. Properties over generated trees.
    var rng = Lcg(12345)
    var all_hash = UInt64(0xCBF29CE484222325)
    var bad_main = 0
    var bad_cross = 0
    var bad_overlap = 0
    var bad_repeat = 0
    for _ in range(200):
        var t = Tree()
        var rt = t.add(box(ROW, -1, -1))
        random_tree(rng, t, rt, 2)
        t.layout(rt, Rect(0, 0, 500, 400))
        var h1 = hash_tree(t)
        t.layout(rt, Rect(0, 0, 500, 400))
        if hash_tree(t) != h1:
            bad_repeat += 1
        all_hash = (all_hash ^ h1) * UInt64(0x100000001B3)
        for i in range(len(t.nodes)):
            ref n = t.nodes[i]
            var row = n.direction == ROW
            var inner = n.rect.inset(n.padding)
            var gaps = n.gap * Float32(len(n.children) - 1) if len(n.children) > 0 else Float32(0)
            var main_room = inner.w if row else inner.h
            if gaps > main_room:
                continue  # degenerate: the gaps alone do not fit, children may spill
            for k in range(len(n.children)):
                var cid = n.children[k]
                var cr = t.nodes[cid].rect
                # the main axis always fits: sizes shrink to what is left
                var main_ok = (cr.x >= inner.x - 1e-3 and cr.right() <= inner.right() + 1e-3) if row else (cr.y >= inner.y - 1e-3 and cr.bottom() <= inner.bottom() + 1e-3)
                if not main_ok:
                    bad_main += 1
                # the cross axis fits unless the child itself needs more than the parent has (a fixed size, as in CSS)
                var m = t.measure(cid)
                var need = m[1] if row else m[0]
                var room = inner.h if row else inner.w
                if need <= room + 1e-3:
                    var cross_ok = (cr.y >= inner.y - 1e-3 and cr.bottom() <= inner.bottom() + 1e-3) if row else (cr.x >= inner.x - 1e-3 and cr.right() <= inner.right() + 1e-3)
                    if not cross_ok:
                        bad_cross += 1
                if k > 0:
                    var pr = t.nodes[n.children[k - 1]].rect
                    var ok_order = (cr.x >= pr.right() - 1e-3) if row else (cr.y >= pr.bottom() - 1e-3)
                    if not ok_order:
                        bad_overlap += 1
    c.eqi_zero(bad_main, "200 generated trees: children stay inside the parent along the main axis")
    c.eqi_zero(bad_cross, "200 generated trees: ...and across it, unless the child needs more than the parent has")
    c.eqi_zero(bad_overlap, "200 generated trees: siblings never overlap along the main axis")
    c.eqi_zero(bad_repeat, "200 generated trees: laying out twice gives identical bits")
    print("  info: hash over 200 generated layouts", all_hash)

    # 8. Focus navigation on a 3 x 3 grid.
    var grid = List[Rect]()
    for row in range(3):
        for col in range(3):
            grid.append(Rect(Float32(col) * 120, Float32(row) * 120, 100, 100))
    c.ok(focus_next(grid, 4, DIR_RIGHT) == 5, "grid: right of the centre")
    c.ok(focus_next(grid, 4, DIR_LEFT) == 3, "grid: left of the centre")
    c.ok(focus_next(grid, 4, DIR_UP) == 1, "grid: up from the centre")
    c.ok(focus_next(grid, 4, DIR_DOWN) == 7, "grid: down from the centre")
    c.ok(focus_next(grid, 0, DIR_LEFT) == -1 and focus_next(grid, 0, DIR_UP) == -1, "grid: nothing beyond the top-left corner")
    c.ok(focus_next(grid, 0, DIR_LEFT, True) == 2, "grid: wrapping left from 0 lands on 2")
    c.ok(focus_next(grid, 1, DIR_UP, True) == 7, "grid: wrapping up from 1 lands on 7")
    c.ok(focus_next(grid, 8, DIR_DOWN, True) == 2, "grid: wrapping down from 8 lands on 2")
    c.ok(focus_next(grid, 8, DIR_RIGHT, True) == 6, "grid: wrapping right from 8 lands on 6")
    c.ok(focus_next(grid, -1, DIR_DOWN) == 0, "no focus yet: the first in reading order")
    c.ok(focus_next(List[Rect](), 0, DIR_DOWN) == -1, "no rectangles: -1")

    # 9. Focus on an irregular layout, and the weighting.
    var wide = List[Rect]()
    wide.append(Rect(0, 0, 220, 40))  # 0 a wide button on top
    wide.append(Rect(0, 60, 100, 40))  # 1 two small ones below
    wide.append(Rect(120, 60, 100, 40))  # 2
    c.ok(focus_next(wide, 0, DIR_DOWN) == 1, "irregular: equal scores go to the lower index")
    c.ok(focus_next(wide, 2, DIR_UP) == 0, "irregular: up from the right button")
    c.ok(focus_next(wide, 1, DIR_RIGHT) == 2, "irregular: right from the left button")
    var aim = List[Rect]()
    aim.append(Rect(0, 0, 100, 100))  # 0 current
    aim.append(Rect(120, 150, 100, 100))  # 1 near in x (gap 20) but 150 off to the side
    aim.append(Rect(130, 0, 100, 100))  # 2 straight ahead, gap 30
    c.ok(focus_next(aim, 0, DIR_RIGHT) == 2, "weighting: straight ahead beats a nearer target far off to the side")

    print("ui_layout:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("ui_layout: " + String(c.failed) + " checks failed")
