"""app/debug_view.mojo (ludens-engine#80): DEBUG_FLAT marks exactly the colour-only items, DEBUG_SKY turns exactly the sky
items into colour-only marked ones, DEBUG_NONE changes nothing."""
from harness.runner import Suite
from app.debug_view import DEBUG_NONE, DEBUG_FLAT, DEBUG_SKY, debug_recolor, MARK
from game.draw_item import DrawItem
from geometry.vec import Real, Vec3


def scene() -> List[DrawItem]:
    var out = List[DrawItem]()
    var c = Vec3(Real(0.2), Real(0.4), Real(0.6), Real(0.0))
    var h = Vec3(Real(1.0), Real(1.0), Real(1.0), Real(0.0))
    var p = Vec3(Real(0.0), Real(0.0), Real(0.0), Real(0.0))
    out.append(DrawItem(0, p, 0.0, 0.0, 0.0, 1.0, h, c))  # colour-only box
    out.append(DrawItem(0, p, 0.0, 0.0, 0.0, 1.0, h, c, -1, -1, 1, 5))  # textured box
    out.append(DrawItem(1, p, 0.0, 0.0, 0.0, 1.0, h, c, -1, -1, 3, 0))  # sky
    return out^


def same(a: Vec3, b: Vec3) -> Bool:
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2]


def main() raises:
    var s = Suite("debug_view")
    var n = scene()
    debug_recolor(n, DEBUG_NONE)
    var ref_items = scene()
    var unchanged = True
    for i in range(3):
        unchanged = unchanged and same(n[i].color, ref_items[i].color) and n[i].material == ref_items[i].material
    s.check(unchanged, "DEBUG_NONE changes nothing")
    var f = scene()
    debug_recolor(f, DEBUG_FLAT)
    s.check(same(f[0].color, MARK) and not same(f[1].color, MARK) and not same(f[2].color, MARK),
            "DEBUG_FLAT marks the colour-only item only")
    var k = scene()
    debug_recolor(k, DEBUG_SKY)
    s.check(same(k[2].color, MARK) and k[2].material == 0, "DEBUG_SKY makes the sky a colour-only marked item")
    s.check(not same(k[0].color, MARK) and k[1].material == 1, "DEBUG_SKY leaves the other items")
    s.finish()
