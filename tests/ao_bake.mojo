"""app/ao_bake.mojo (ludens-engine#79): a 2 m pillar in the middle of a 40 m floor. Cells far from it are open (1.0);
the cells around it are occluded, the most at its foot; the grid is the same on a second bake; no boxes gives an open
grid; bad parameters raise."""
from harness.runner import Suite
from geometry.vec import Vec3
from geometry.aabb import AABB
from app.ao_bake import ao_bake


def main() raises:
    var s = Suite("ao_bake")
    var boxes = List[AABB[3]]()
    boxes.append(AABB[3](Vec3(-1.0, 0.0, -1.0, 0.0), Vec3(1.0, 2.0, 1.0, 0.0)))
    var g = ao_bake(boxes)
    s.check(len(g) == 1600, "40 x 40 cells")
    s.check(g[0] == Float32(1.0) and g[1599] == Float32(1.0), "the corners, 27 m from the pillar, are open")
    var beside = g[19 * 40 + 18]  # the cell centred at (-1.5, -0.5): half a metre off the pillar's west face
    s.check(beside < Float32(0.95), "beside the pillar is occluded (" + String(beside) + ")")
    var two_m = g[19 * 40 + 16]  # centred at (-3.5, -0.5)
    s.check(beside < two_m, "occlusion falls off with distance (" + String(beside) + " < " + String(two_m) + ")")
    var lo = Float32(1.0)
    for c in g:
        lo = min(lo, c)
    s.check(lo >= Float32(0.3), "no cell below 1 - strength (" + String(lo) + ")")
    var g2 = ao_bake(boxes)
    var same = True
    for i in range(len(g)):
        same = same and g[i] == g2[i]
    s.check(same, "a second bake is bit for bit the same")
    var empty = ao_bake(List[AABB[3]](), 4)
    var open = True
    for c in empty:
        open = open and c == Float32(1.0)
    s.check(len(empty) == 16 and open, "no boxes: every cell open")
    var raised = 0
    try:
        _ = ao_bake(boxes, 0)
    except:
        raised += 1
    try:
        _ = ao_bake(boxes, 4, size=0.0)
    except:
        raised += 1
    s.check(raised == 2, "n 0 and size 0 raise")
    s.finish()
