# tier: unit
"""Level structure generators (ROADMAP 17.69, `procedural.levelgen`).

  1. Maze 20 x 15: a perfect maze -- 300 cells, 299 passages (a tree),
     every floor cell reachable from the start; the same seed gives the
     same grid bit for bit, another seed a different one.
  2. BSP 60 x 40, leaves >= 10: every room's floor reachable from the
     first room (corridors connect the tree); rooms inside the area.
  3. L-system: the Koch curve F -> F+F-F-F+F after 2 rewrites has 25 F's
     (5^2) and the turtle draws 25 segments; brackets restore position.
  4. WFC on 3 tiles (0 sea, 1 shore, 2 land; sea never touches land) on
     20 x 20: every adjacent pair is allowed by the table; same seed ->
     same map; a table with no consistent tiling raises.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec2
from procedural.levelgen import Grid, maze, bsp_rooms, lsystem, turtle, wfc


def main() raises:
    var s = Suite("levelgen")

    # 1. maze
    var m = maze(20, 15, 7)
    var floor = m.count(1)
    var passages = floor - 20 * 15
    var reach = m.reachable(1, 1)
    print("maze 20 x 15:", floor, "floor cells,", passages, "passages, reachable", reach)
    s.check(passages == 299 and reach == floor, "perfect maze: a spanning tree, all floor connected")
    var m2 = maze(20, 15, 7)
    var m3 = maze(20, 15, 8)
    var same = True
    var diff = 0
    for k in range(len(m.c)):
        same = same and m.c[k] == m2.c[k]
        if m.c[k] != m3.c[k]:
            diff += 1
    s.check(same and diff > 0, "same seed same maze, another seed differs")

    # 2. BSP
    var b = bsp_rooms(60, 40, 10, 3)
    var g = b[0].copy()
    var rooms = b[1].copy()
    var r0 = rooms[0]
    var reach_b = g.reachable(r0.x, r0.y)
    var inside = True
    for r in rooms:
        inside = inside and r.x >= 1 and r.y >= 1 and r.x + r.w <= 59 and r.y + r.h <= 39
    print("bsp 60 x 40:", len(rooms), "rooms, floor", g.count(1), "reachable from room 0", reach_b)
    s.check(len(rooms) >= 4 and reach_b == g.count(1) and inside, "BSP rooms all connected and inside the area")

    # 3. L-system
    var rules = Dict[String, String]()
    rules["F"] = "F+F-F-F+F"
    var koch = lsystem("F", rules, 2)
    var nf = 0
    for ch in koch.codepoint_slices():
        if String(ch) == "F":
            nf += 1
    var segs = turtle(koch, 1.0, 1.5707963267948966)
    var br = turtle("F[+F]F", 1.0, 1.5707963267948966)
    print("koch 2 rewrites:", nf, "F,", len(segs) // 2, "segments; bracket end", br[len(br) - 1][0], br[len(br) - 1][1])
    s.check(nf == 25 and len(segs) == 50, "Koch: 5^2 F's, one segment each")
    s.check(abs(br[len(br) - 1][0]) < 1e-5 and abs(br[len(br) - 1][1] - 2) < 1e-5, "brackets restore position and heading")

    # 4. WFC
    var n = 3
    var adj = List[Bool](length=n * n * 4, fill=False)
    for a in range(n):
        for bb in range(n):
            var ok = abs(a - bb) <= 1
            for d in range(4):
                adj[(a * n + bb) * 4 + d] = ok
    var map1 = wfc(20, 20, adj, n, 11)
    var map2 = wfc(20, 20, adj, n, 11)
    var bad = 0
    var counts = List[Int](length=3, fill=0)
    for y in range(20):
        for x in range(20):
            counts[map1.at(x, y)] += 1
            if x + 1 < 20 and abs(map1.at(x, y) - map1.at(x + 1, y)) > 1:
                bad += 1
            if y + 1 < 20 and abs(map1.at(x, y) - map1.at(x, y + 1)) > 1:
                bad += 1
    var same_w = True
    for k in range(400):
        same_w = same_w and map1.c[k] == map2.c[k]
    print("wfc 20 x 20: sea / shore / land", counts[0], counts[1], counts[2], " forbidden pairs", bad)
    s.check(bad == 0 and same_w, "WFC: every neighbour pair allowed; same seed same map")
    var none = List[Bool](length=2 * 2 * 4, fill=False)
    var raised = False
    try:
        _ = wfc(4, 4, none, 2, 1, 3)
    except:
        raised = True
    s.check(raised, "no consistent tiling raises")
    s.finish()
