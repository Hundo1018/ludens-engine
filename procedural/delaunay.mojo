"""2D Delaunay triangulation, Bowyer-Watson on exact predicates (ROADMAP 17.69).

Points are inserted one at a time into a triangulation that starts as one
large super-triangle; each insertion removes the triangles whose
circumcircle contains the point (`geometry.predicates.incircle`, exact) and
re-fans the cavity. Triangles touching the super-triangle are dropped at
the end. O(n^2) worst case (the bad-triangle search is linear); meant for
region / settlement layouts of thousands of points, not millions.

Because the predicates are exact, cocircular and collinear inputs do not
break it: every output triangle is counter-clockwise (`orient2d` > 0) and
has no input point strictly inside its circumcircle (`is_delaunay`).
Duplicate points are skipped (each is reported once in the output indices).
"""

from geometry.vec import Real, Vec2
from geometry.predicates import orient2d, incircle


def delaunay(pts: List[Vec2]) -> List[Int]:
    """Triangles as index triples into `pts`, counter-clockwise."""
    var n = len(pts)
    if n < 3:
        return List[Int]()
    var lo = pts[0]
    var hi = pts[0]
    for p in pts:
        lo = Vec2(min(lo[0], p[0]), min(lo[1], p[1]))
        hi = Vec2(max(hi[0], p[0]), max(hi[1], p[1]))
    var span = max(hi[0] - lo[0], hi[1] - lo[1])
    if span == 0:
        span = 1
    var mid = (lo + hi) * Real(0.5)
    var v = pts.copy()
    v.append(Vec2(mid[0] - 20 * span, mid[1] - 20 * span))
    v.append(Vec2(mid[0] + 20 * span, mid[1] - 20 * span))
    v.append(Vec2(mid[0], mid[1] + 20 * span))
    var tri: List[Int] = [n, n + 1, n + 2]
    for i in range(n):
        var dup = False
        for j in range(i):
            if pts[j] == pts[i]:
                dup = True
                break
        if dup:
            continue
        var p = v[i]
        var bad = List[Bool](length=len(tri) // 3, fill=False)
        for t in range(len(tri) // 3):
            if incircle(v[tri[3 * t]], v[tri[3 * t + 1]], v[tri[3 * t + 2]], p) > 0:
                bad[t] = True
        # cavity boundary: edges of bad triangles not shared by another bad one
        var edges = List[Int]()
        for t in range(len(bad)):
            if not bad[t]:
                continue
            for e in range(3):
                var a = tri[3 * t + e]
                var b = tri[3 * t + (e + 1) % 3]
                var shared = False
                for u in range(len(bad)):
                    if u == t or not bad[u]:
                        continue
                    for f in range(3):
                        if tri[3 * u + f] == b and tri[3 * u + (f + 1) % 3] == a:
                            shared = True
                if not shared:
                    edges.append(a)
                    edges.append(b)
        var keep = List[Int]()
        for t in range(len(bad)):
            if not bad[t]:
                keep.append(tri[3 * t])
                keep.append(tri[3 * t + 1])
                keep.append(tri[3 * t + 2])
        for e in range(len(edges) // 2):
            var a = edges[2 * e]
            var b = edges[2 * e + 1]
            if orient2d(v[a], v[b], p) > 0:
                keep.append(a)
                keep.append(b)
                keep.append(i)
        tri = keep^
    var out = List[Int]()
    for t in range(len(tri) // 3):
        if tri[3 * t] < n and tri[3 * t + 1] < n and tri[3 * t + 2] < n:
            out.append(tri[3 * t])
            out.append(tri[3 * t + 1])
            out.append(tri[3 * t + 2])
    return out^


def is_delaunay(pts: List[Vec2], tri: List[Int]) -> Bool:
    """Every triangle counter-clockwise with no point strictly inside its
    circumcircle (exact predicates; O(triangles x points))."""
    for t in range(len(tri) // 3):
        var a = pts[tri[3 * t]]
        var b = pts[tri[3 * t + 1]]
        var c = pts[tri[3 * t + 2]]
        if orient2d(a, b, c) <= 0:
            return False
        for p in pts:
            if incircle(a, b, c, p) > 0:
                return False
    return True


def delaunay_walk(pts: List[Vec2]) -> List[Int]:
    """`delaunay` with triangle adjacency (ROADMAP 17.69): the point is
    located by walking from the last triangle made (cross the edge it lies
    outside of, `orient2d` < 0) and the cavity grown from there through
    neighbours whose circumcircle holds it, instead of testing every
    triangle. Same exact predicates, same super-triangle and duplicate
    rule, so for points in general position the triangle set equals
    `delaunay`'s (order and rotation aside); for cocircular inputs both are
    valid Delaunay triangulations, not necessarily the same one."""
    var n = len(pts)
    if n < 3:
        return List[Int]()
    var lo = pts[0]
    var hi = pts[0]
    for p in pts:
        lo = Vec2(min(lo[0], p[0]), min(lo[1], p[1]))
        hi = Vec2(max(hi[0], p[0]), max(hi[1], p[1]))
    var span = max(hi[0] - lo[0], hi[1] - lo[1])
    if span == 0:
        span = 1
    var mid = (lo + hi) * Real(0.5)
    var v = pts.copy()
    v.append(Vec2(mid[0] - 20 * span, mid[1] - 20 * span))
    v.append(Vec2(mid[0] + 20 * span, mid[1] - 20 * span))
    v.append(Vec2(mid[0], mid[1] + 20 * span))
    # tri[3t + e]: vertices ccw; nbr[3t + e]: across edge (tri[3t+e], tri[3t+e+1])
    var tri: List[Int] = [n, n + 1, n + 2]
    var nbr: List[Int] = [-1, -1, -1]
    var alive: List[Bool] = [True]
    var last = 0
    var bad = List[Bool](length=1, fill=False)
    for i in range(n):
        var p = v[i]
        # walk
        var t = last
        var steps = 0
        while True:
            var moved = False
            for e in range(3):
                var a = tri[3 * t + e]
                var b = tri[3 * t + (e + 1) % 3]
                if orient2d(v[a], v[b], p) < 0 and nbr[3 * t + e] >= 0:
                    t = nbr[3 * t + e]
                    moved = True
                    break
            steps += 1
            if not moved or steps > 4 * len(alive) + 8:
                break
        # duplicate of a vertex already in: skip, as `delaunay` does
        var dup = False
        for e in range(3):
            if v[tri[3 * t + e]] == p:
                dup = True
        if dup:
            continue
        # cavity
        while len(bad) < len(alive):
            bad.append(False)
        var cav: List[Int] = [t]
        bad[t] = True
        var k = 0
        while k < len(cav):
            var u = cav[k]
            k += 1
            for e in range(3):
                var w = nbr[3 * u + e]
                if w >= 0 and not bad[w] and alive[w]:
                    if incircle(v[tri[3 * w]], v[tri[3 * w + 1]], v[tri[3 * w + 2]], p) > 0:
                        bad[w] = True
                        cav.append(w)
        # boundary edges (a, b, outside neighbour), one cycle around p
        var ea = List[Int]()
        var eb = List[Int]()
        var eo = List[Int]()
        for u in cav:
            for e in range(3):
                var w = nbr[3 * u + e]
                if w < 0 or not bad[w]:
                    ea.append(tri[3 * u + e])
                    eb.append(tri[3 * u + (e + 1) % 3])
                    eo.append(w)
        for u in cav:
            alive[u] = False
            bad[u] = False
        var start_of = Dict[Int, Int]()
        var base = len(alive)
        for q in range(len(ea)):
            var nt = base + q
            tri.append(ea[q])
            tri.append(eb[q])
            tri.append(i)
            nbr.append(eo[q])
            nbr.append(-1)
            nbr.append(-1)
            alive.append(True)
            start_of[ea[q]] = nt
            var w = eo[q]
            if w >= 0:
                for f in range(3):
                    if tri[3 * w + f] == eb[q] and tri[3 * w + (f + 1) % 3] == ea[q]:
                        nbr[3 * w + f] = nt
        for q in range(len(ea)):
            var nt = base + q
            # edge (b, p) borders the new triangle starting at b; edge (p, a)
            # the one ending at a, whose own (b, p) edge points back here
            try:
                nbr[3 * nt + 1] = start_of[eb[q]]
                nbr[3 * start_of[eb[q]] + 2] = nt
            except:
                pass
        last = base
    var out = List[Int]()
    for t in range(len(alive)):
        if alive[t] and tri[3 * t] < n and tri[3 * t + 1] < n and tri[3 * t + 2] < n:
            out.append(tri[3 * t])
            out.append(tri[3 * t + 1])
            out.append(tri[3 * t + 2])
    return out^
