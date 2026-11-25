"""Mesh levels of detail (#141): a chain of simplified copies of a static mesh, made offline, and the choice of a level per
instance from its size on the screen, with hysteresis.

    var chain = LodChain.build(reg, mesh, [1.0, 0.5, 0.25, 0.125])   # registers levels 1 .. 3 in `reg`
    var state = LodState()                                            # one per instance
    var id = chain.pick(state, centre, scale, view, height_px)        # the mesh id to draw this frame
    r.push(DrawItem(..., id, ...))

Simplification (`simplify`) is edge collapse ordered by the quadric error metric (Garland and Heckbert 1997). The kept
vertex is one of the two ends (no new positions), so normals and uv are the original ones. Vertices at the same position
(uv seams, hard edges) are welded for the topology: a seam does not open, and a corner that loses its vertex takes the
copy of the kept position whose normal is closest to its own. Boundary edges get a penalty plane perpendicular to the
face, so an open border keeps its outline. A collapse that would turn a neighbouring triangle over (its normal by more
than about 78 degrees) is refused. The collapses run in passes: each pass sorts every edge by cost and collapses the
cheapest edges whose ends no earlier collapse of the pass touched, until the triangle count reaches the target.

Every level records its error: the largest distance (object units) from a vertex of the full mesh to the level's
surface, and from a vertex of the level to the full surface (both directions, so it is the symmetric Hausdorff
distance measured at vertices). `pick` projects that error to pixels at the instance's distance and uses the coarsest
level whose error is at most `tol_px` (1 pixel by default). That is a choice by screen-space size: the error in pixels
is the level's error relative to the mesh's radius times the mesh's radius in pixels.

Hysteresis: from level k the choice moves to a coarser level only when that level's error is at most
`tol_px * (1 - band)`, and back to a finer one only when level k's own error passes `tol_px * (1 + band)`. With the
default band of 0.15 an instance whose distance wobbles by less than about 15 % around a switch distance keeps its level.
"""
from std.math import sqrt
from geometry.vec import Real, Vec3
from game.camera_view import View
from app.mesh_data import MeshData
from app.mesh_pass import MeshRegistry

comptime LOD_MAX_LEVELS = 8
comptime LOD_BAND = 0.15
comptime BOUNDARY_WEIGHT = 100.0  # the boundary planes' weight against the faces' own (both are squared distances)


# ---------------------------------------------------------------------------------------------------------------------
# small vector helpers in Float64


@fieldwise_init
struct _P(Copyable, ImplicitlyCopyable, Movable):
    var x: Float64
    var y: Float64
    var z: Float64


def _sub(a: _P, b: _P) -> _P:
    return _P(a.x - b.x, a.y - b.y, a.z - b.z)


def _cross(a: _P, b: _P) -> _P:
    return _P(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)


def _dot(a: _P, b: _P) -> Float64:
    return a.x * b.x + a.y * b.y + a.z * b.z


def _len(a: _P) -> Float64:
    return sqrt(_dot(a, a))


def _pos(m: MeshData, v: Int) -> _P:
    return _P(Float64(m.positions[3 * v]), Float64(m.positions[3 * v + 1]), Float64(m.positions[3 * v + 2]))


def _nrm(m: MeshData, v: Int) -> _P:
    return _P(Float64(m.normals[3 * v]), Float64(m.normals[3 * v + 1]), Float64(m.normals[3 * v + 2]))


# ---------------------------------------------------------------------------------------------------------------------
# quadrics: the symmetric 4 x 4 matrix of a sum of squared plane distances, as its 10 distinct entries


def _add_plane(mut q: List[Float64], at: Int, n: _P, d: Float64, w: Float64):
    """Add w * (n . p + d)^2 to quadric `at` (10 floats)."""
    q[at + 0] += w * n.x * n.x
    q[at + 1] += w * n.x * n.y
    q[at + 2] += w * n.x * n.z
    q[at + 3] += w * n.x * d
    q[at + 4] += w * n.y * n.y
    q[at + 5] += w * n.y * n.z
    q[at + 6] += w * n.y * d
    q[at + 7] += w * n.z * n.z
    q[at + 8] += w * n.z * d
    q[at + 9] += w * d * d


def _q_eval(q: List[Float64], a: Int, b: Int, p: _P) -> Float64:
    """(p, 1)^T (Q_a + Q_b) (p, 1)."""
    var s = 0.0
    var c = List[Float64](length=10, fill=0.0)
    for i in range(10):
        c[i] = q[10 * a + i] + q[10 * b + i]
    s += c[0] * p.x * p.x + 2.0 * c[1] * p.x * p.y + 2.0 * c[2] * p.x * p.z + 2.0 * c[3] * p.x
    s += c[4] * p.y * p.y + 2.0 * c[5] * p.y * p.z + 2.0 * c[6] * p.y
    s += c[7] * p.z * p.z + 2.0 * c[8] * p.z + c[9]
    return max(s, 0.0)


# ---------------------------------------------------------------------------------------------------------------------
# a deterministic heap sort of edge records (cost, a, b, keep), by cost, then a, then b


@fieldwise_init
struct _Edge(Copyable, ImplicitlyCopyable, Movable):
    var cost: Float64
    var a: Int  # the welded vertex that goes
    var b: Int  # the welded vertex that stays


def _less(x: _Edge, y: _Edge) -> Bool:
    if x.cost != y.cost:
        return x.cost < y.cost
    if x.a != y.a:
        return x.a < y.a
    return x.b < y.b


def _sift(mut e: List[_Edge], start: Int, end: Int):
    var root = start
    while 2 * root + 1 < end:
        var child = 2 * root + 1
        if child + 1 < end and _less(e[child], e[child + 1]):
            child += 1
        if _less(e[root], e[child]):
            var t = e[root]
            e[root] = e[child]
            e[child] = t
            root = child
        else:
            return


def _sort_edges(mut e: List[_Edge]):
    var n = len(e)
    var i = n // 2 - 1
    while i >= 0:
        _sift(e, i, n)
        i -= 1
    var end = n - 1
    while end > 0:
        var t = e[0]
        e[0] = e[end]
        e[end] = t
        _sift(e, 0, end)
        end -= 1


# ---------------------------------------------------------------------------------------------------------------------
# simplification


def _key_less(q: List[Int], a: Int, b: Int) -> Bool:
    """Order of vertices a and b by their rounded position (q holds x, y, z per vertex), then by index."""
    for k in range(3):
        if q[3 * a + k] != q[3 * b + k]:
            return q[3 * a + k] < q[3 * b + k]
    return a < b


def _sift_idx(mut e: List[Int], q: List[Int], start: Int, end: Int):
    var root = start
    while 2 * root + 1 < end:
        var child = 2 * root + 1
        if child + 1 < end and _key_less(q, e[child], e[child + 1]):
            child += 1
        if _key_less(q, e[root], e[child]):
            var t = e[root]
            e[root] = e[child]
            e[child] = t
            root = child
        else:
            return


def weld_ids(m: MeshData) -> List[Int]:
    """For each vertex, the lowest index of a vertex at the same position: positions are compared after rounding to
    1e-6 of the mesh's largest coordinate, so a seam whose two copies differ in the last bits (sin(2 pi) is not 0)
    is welded. Two positions closer than that but on two sides of a rounding step stay apart."""
    var nv = len(m.positions) // 3
    var big = 1e-30
    for x in m.positions:
        big = max(big, abs(Float64(x)))
    var step = big * 1e-6
    var q = List[Int]()
    for x in m.positions:
        q.append(Int(round(Float64(x) / step)))
    var order = List[Int]()
    for v in range(nv):
        order.append(v)
    var i = nv // 2 - 1
    while i >= 0:
        _sift_idx(order, q, i, nv)
        i -= 1
    var end = nv - 1
    while end > 0:
        var t = order[0]
        order[0] = order[end]
        order[end] = t
        _sift_idx(order, q, 0, end)
        end -= 1
    var out = List[Int](length=nv, fill=0)
    var a = 0
    while a < nv:
        var b = a
        var first = order[a]  # sorted by index inside a group: the lowest
        while b < nv and q[3 * order[b]] == q[3 * first] and q[3 * order[b] + 1] == q[3 * first + 1] and q[3 * order[b] + 2] == q[3 * first + 2]:
            out[order[b]] = first
            b += 1
        a = b
    return out^


def triangle_count(m: MeshData) -> Int:
    return len(m.indices) // 3


def simplify(m: MeshData, target_triangles: Int) raises -> MeshData:
    """The mesh with at most about `target_triangles` triangles (fewer only if a pass overshoots by its last collapse;
    more if no allowed collapse is left). Vertices that no triangle uses any more are dropped and the rest renumbered in
    their original order."""
    if target_triangles < 1:
        raise Error("mesh lod: the target is at least one triangle")
    var nv = len(m.positions) // 3
    var weld = weld_ids(m)
    var copies = List[List[Int]]()  # per welded id: the original vertices at that position
    for _ in range(nv):
        copies.append(List[Int]())
    for v in range(nv):
        copies[weld[v]].append(v)
    var tris = List[Int]()  # corners: original vertex ids; triangles with two corners at one position are dropped
    for t in range(len(m.indices) // 3):
        var a = Int(m.indices[3 * t])
        var b = Int(m.indices[3 * t + 1])
        var c = Int(m.indices[3 * t + 2])
        if weld[a] == weld[b] or weld[b] == weld[c] or weld[a] == weld[c]:
            continue
        tris.append(a)
        tris.append(b)
        tris.append(c)
    var wp = List[_P]()  # welded positions (only welded ids are read)
    for v in range(nv):
        wp.append(_pos(m, v))
    # the quadrics of the faces, area weighted, and the boundary penalties
    var q = List[Float64](length=10 * nv, fill=0.0)
    var nt = len(tris) // 3
    for t in range(nt):
        var a = weld[tris[3 * t]]
        var b = weld[tris[3 * t + 1]]
        var c = weld[tris[3 * t + 2]]
        var n = _cross(_sub(wp[b], wp[a]), _sub(wp[c], wp[a]))
        var l = _len(n)
        if l <= 0.0:
            continue
        var u = _P(n.x / l, n.y / l, n.z / l)
        var area = 0.5 * l
        for w in [a, b, c]:
            _add_plane(q, 10 * w, u, -_dot(u, wp[a]), area)
    # boundary edges: welded edges used by one triangle only
    var halfs = List[_Edge]()
    for t in range(nt):
        for k in range(3):
            var a = weld[tris[3 * t + k]]
            var b = weld[tris[3 * t + (k + 1) % 3]]
            halfs.append(_Edge(Float64(min(a, b)) * Float64(nv) + Float64(max(a, b)), t, k))
    _sort_edges(halfs)
    var i = 0
    while i < len(halfs):
        var j = i
        while j < len(halfs) and halfs[j].cost == halfs[i].cost:
            j += 1
        if j - i == 1:
            var t = halfs[i].a
            var k = halfs[i].b
            var a = weld[tris[3 * t + k]]
            var b = weld[tris[3 * t + (k + 1) % 3]]
            var c = weld[tris[3 * t + (k + 2) % 3]]
            var fn_ = _cross(_sub(wp[b], wp[a]), _sub(wp[c], wp[a]))
            var e = _sub(wp[b], wp[a])
            var pn = _cross(e, fn_)
            var pl = _len(pn)
            if pl > 0.0:
                var u = _P(pn.x / pl, pn.y / pl, pn.z / pl)
                var w = BOUNDARY_WEIGHT * _dot(e, e)
                for x in [a, b]:
                    _add_plane(q, 10 * x, u, -_dot(u, wp[a]), w)
        i = j
    var gone = List[Bool](length=nv, fill=False)  # welded ids collapsed away
    var live = nt
    while live > target_triangles:
        # this pass's triangles per welded vertex
        var around = List[List[Int]]()
        for _ in range(nv):
            around.append(List[Int]())
        for t in range(len(tris) // 3):
            if tris[3 * t] < 0:
                continue
            for k in range(3):
                around[weld[tris[3 * t + k]]].append(t)
        var edges = List[_Edge]()
        for t in range(len(tris) // 3):
            if tris[3 * t] < 0:
                continue
            for k in range(3):
                var a0 = weld[tris[3 * t + k]]
                var b0 = weld[tris[3 * t + (k + 1) % 3]]
                var a = min(a0, b0)
                var b = max(a0, b0)
                if a != b:  # an inner edge is listed twice (once per side); the second copy is refused as touched
                    var ca = _q_eval(q, a, b, wp[b])  # a goes, b stays
                    var cb = _q_eval(q, a, b, wp[a])
                    if ca <= cb:
                        edges.append(_Edge(ca, a, b))
                    else:
                        edges.append(_Edge(cb, b, a))
        if len(edges) == 0:
            break
        _sort_edges(edges)
        var touched = List[Bool](length=nv, fill=False)
        var collapsed = 0
        var limit = max(1, len(edges) // 4)  # at most a quarter of the edges per pass, so costs are re-read often
        for e in edges:
            if live <= target_triangles or collapsed >= limit:
                break
            if touched[e.a] or touched[e.b] or gone[e.a] or gone[e.b]:
                continue
            # refuse a collapse that turns over a triangle around a that stays
            var ok = True
            var removed = 0
            for t in around[e.a]:
                if tris[3 * t] < 0:
                    continue
                var w0 = weld[tris[3 * t]]
                var w1 = weld[tris[3 * t + 1]]
                var w2 = weld[tris[3 * t + 2]]
                if w0 == e.b or w1 == e.b or w2 == e.b:
                    removed += 1
                    continue
                var p0 = wp[w0]
                var p1 = wp[w1]
                var p2 = wp[w2]
                var n0 = _cross(_sub(p1, p0), _sub(p2, p0))
                if w0 == e.a:
                    p0 = wp[e.b]
                elif w1 == e.a:
                    p1 = wp[e.b]
                else:
                    p2 = wp[e.b]
                var n1 = _cross(_sub(p1, p0), _sub(p2, p0))
                var l0 = _len(n0)
                var l1 = _len(n1)
                if l1 <= 1e-12 * max(l0, 1e-30) or _dot(n0, n1) < 0.2 * l0 * l1:
                    ok = False
                    break
            if not ok or removed == 0:
                continue
            # collapse: every corner on a welded copy of a moves to the copy of b with the closest normal
            for t in around[e.a]:
                if tris[3 * t] < 0:
                    continue
                var drop = False
                for k in range(3):
                    if weld[tris[3 * t + k]] == e.b:
                        drop = True
                if drop:
                    tris[3 * t] = -1
                    tris[3 * t + 1] = -1
                    tris[3 * t + 2] = -1
                    continue
                for k in range(3):
                    var v = tris[3 * t + k]
                    if weld[v] == e.a:
                        var best = copies[e.b][0]
                        var bd = -2.0
                        var nv_ = _nrm(m, v)
                        for c in copies[e.b]:
                            var d = _dot(nv_, _nrm(m, c))
                            if d > bd:
                                bd = d
                                best = c
                        tris[3 * t + k] = best
            for i in range(10):
                q[10 * e.b + i] += q[10 * e.a + i]
            gone[e.a] = True
            touched[e.a] = True
            touched[e.b] = True
            live -= removed
            collapsed += 1
        if collapsed == 0:
            break
    # the kept triangles, renumbered
    var remap = List[Int](length=nv, fill=-1)
    var out = MeshData(List[Float32](), List[Float32](), List[Float32](), List[UInt32]())
    var used = List[Bool](length=nv, fill=False)
    for c in tris:
        if c >= 0:
            used[c] = True
    for v in range(nv):
        if used[v]:
            remap[v] = len(out.positions) // 3
            for k in range(3):
                out.positions.append(m.positions[3 * v + k])
                out.normals.append(m.normals[3 * v + k])
            out.uv.append(m.uv[2 * v])
            out.uv.append(m.uv[2 * v + 1])
    for c in tris:
        if c >= 0:
            out.indices.append(UInt32(remap[c]))
    if len(out.indices) == 0:
        raise Error("mesh lod: the simplification removed every triangle")
    return out^


# ---------------------------------------------------------------------------------------------------------------------
# error: the symmetric Hausdorff distance measured at vertices


def _point_tri(p: _P, a: _P, b: _P, c: _P) -> Float64:
    """Distance from p to triangle abc (Ericson, Real-Time Collision Detection 5.1.5)."""
    var ab = _sub(b, a)
    var ac = _sub(c, a)
    var ap = _sub(p, a)
    var d1 = _dot(ab, ap)
    var d2 = _dot(ac, ap)
    if d1 <= 0.0 and d2 <= 0.0:
        return _len(ap)
    var bp = _sub(p, b)
    var d3 = _dot(ab, bp)
    var d4 = _dot(ac, bp)
    if d3 >= 0.0 and d4 <= d3:
        return _len(bp)
    var vc = d1 * d4 - d3 * d2
    if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
        var v = d1 / (d1 - d3)
        return _len(_sub(p, _P(a.x + ab.x * v, a.y + ab.y * v, a.z + ab.z * v)))
    var cp = _sub(p, c)
    var d5 = _dot(ab, cp)
    var d6 = _dot(ac, cp)
    if d6 >= 0.0 and d5 <= d6:
        return _len(cp)
    var vb = d5 * d2 - d1 * d6
    if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
        var w = d2 / (d2 - d6)
        return _len(_sub(p, _P(a.x + ac.x * w, a.y + ac.y * w, a.z + ac.z * w)))
    var va = d3 * d6 - d5 * d4
    if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
        var w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
        var bc = _sub(c, b)
        return _len(_sub(p, _P(b.x + bc.x * w, b.y + bc.y * w, b.z + bc.z * w)))
    var den = 1.0 / (va + vb + vc)
    var v = vb * den
    var w = vc * den
    return _len(_sub(p, _P(a.x + ab.x * v + ac.x * w, a.y + ab.y * v + ac.y * w, a.z + ab.z * v + ac.z * w)))


def _one_way(src: MeshData, dst: MeshData) -> Float64:
    """The largest distance from a vertex of src to the surface of dst."""
    var worst = 0.0
    var nt = len(dst.indices) // 3
    for v in range(len(src.positions) // 3):
        var p = _pos(src, v)
        var best = 1e300
        for t in range(nt):
            var d = _point_tri(p, _pos(dst, Int(dst.indices[3 * t])), _pos(dst, Int(dst.indices[3 * t + 1])), _pos(dst, Int(dst.indices[3 * t + 2])))
            if d < best:
                best = d
                if best == 0.0:
                    break
        if best > worst:
            worst = best
    return worst


def surface_error(full: MeshData, level: MeshData) -> Float64:
    """The symmetric Hausdorff distance between the two surfaces, measured at their vertices (object units)."""
    return max(_one_way(full, level), _one_way(level, full))


def mesh_radius(m: MeshData) -> Float64:
    """The largest distance of a vertex from the origin: the radius `pick` scales and projects."""
    var r = 0.0
    for v in range(len(m.positions) // 3):
        r = max(r, _len(_pos(m, v)))
    return r


# ---------------------------------------------------------------------------------------------------------------------
# the chain and the choice


struct LodState(Copyable, ImplicitlyCopyable, Movable):
    """One instance's current level: -1 before its first pick."""

    var level: Int
    var switches: Int  # how many times the level changed (for tests and counters)

    def __init__(out self):
        self.level = -1
        self.switches = 0


struct LodChain(Copyable, Movable):
    var ids: List[Int]  # the mesh id of each level, finest first
    var triangles: List[Int]
    var errors: List[Float64]  # surface_error of each level against level 0 (0 for level 0), object units
    var radius: Float64
    var band: Float64

    def __init__(out self):
        self.ids = List[Int]()
        self.triangles = List[Int]()
        self.errors = List[Float64]()
        self.radius = 0.0
        self.band = LOD_BAND

    @staticmethod
    def build(mut reg: MeshRegistry, mesh: Int, ratios: List[Float64]) raises -> Self:
        """Levels of the static mesh `mesh` at these fractions of its triangle count (the first must be 1: the mesh
        itself). Each level is simplified from the full mesh and registered; a level that did not get smaller than the
        one before is not kept."""
        if len(ratios) < 1 or ratios[0] != 1.0 or len(ratios) > LOD_MAX_LEVELS:
            raise Error("mesh lod: ratios start at 1.0, at most " + String(LOD_MAX_LEVELS) + " levels")
        if mesh < 0 or mesh >= reg.count() or reg.versions[mesh] != 0:
            raise Error("mesh lod: a chain is built from a static mesh")
        var full = reg.meshes[mesh].copy()
        var c = Self()
        c.radius = mesh_radius(full)
        c.ids.append(mesh)
        c.triangles.append(triangle_count(full))
        c.errors.append(0.0)
        for i in range(1, len(ratios)):
            if not (ratios[i] > 0.0 and ratios[i] < ratios[i - 1]):
                raise Error("mesh lod: ratios decrease and stay above 0")
            var target = max(1, Int(Float64(triangle_count(full)) * ratios[i]))
            var lv = simplify(full, target)
            var n = triangle_count(lv)
            if n >= c.triangles[len(c.triangles) - 1]:
                continue
            var err = surface_error(full, lv)
            c.errors.append(max(err, c.errors[len(c.errors) - 1]))  # a coarser level is never claimed to be better
            c.triangles.append(n)
            var id = reg.add_static(lv.positions.copy(), lv.normals.copy(), lv.uv.copy(), lv.indices.copy())
            c.ids.append(id)
        return c^

    def levels(self) -> Int:
        return len(self.ids)

    def pixel_error(self, level: Int, centre: Vec3, scale: Float64, view: View, height_px: Float64) -> Float64:
        """Level `level`'s error in pixels for an instance at `centre` scaled by `scale` (its largest axis). Behind or at
        the eye the error counts as infinite, so the finest level is used."""
        var e = self.errors[level] * scale
        if view.ortho:
            return e * Float64(view.sy) * height_px * 0.5
        var z = (Float64(centre[0]) - Float64(view.eye[0])) * Float64(view.fwd[0])
        z += (Float64(centre[1]) - Float64(view.eye[1])) * Float64(view.fwd[1])
        z += (Float64(centre[2]) - Float64(view.eye[2])) * Float64(view.fwd[2])
        z = max(z - self.radius * scale, 0.0)  # the nearest point of the bounding sphere along the view axis
        if z <= Float64(view.near):
            return 1e300 if e > 0.0 else 0.0
        return e * Float64(view.sy) * height_px * 0.5 / z

    def pick_level(self, mut state: LodState, centre: Vec3, scale: Float64, view: View, height_px: Float64, tol_px: Float64 = 1.0) -> Int:
        var n = len(self.ids)
        var want = 0
        for k in range(n):
            if self.pixel_error(k, centre, scale, view, height_px) <= tol_px:
                want = k
        if state.level < 0:
            state.level = want
            return want
        var cur = state.level
        if want > cur:
            # coarser: the coarsest level inside the lower edge of the band
            var to = cur
            for k in range(cur + 1, n):
                if self.pixel_error(k, centre, scale, view, height_px) <= tol_px * (1.0 - self.band):
                    to = k
            if to != cur:
                state.level = to
                state.switches += 1
        elif self.pixel_error(cur, centre, scale, view, height_px) > tol_px * (1.0 + self.band):
            # finer: the coarsest level inside the upper edge of the band, and never coarser than `want`
            var to = 0
            for k in range(cur):
                if self.pixel_error(k, centre, scale, view, height_px) <= tol_px * (1.0 + self.band):
                    to = k
            state.level = min(to, cur - 1) if to < cur else cur - 1
            state.switches += 1
        return state.level

    def pick(self, mut state: LodState, centre: Vec3, scale: Float64, view: View, height_px: Float64, tol_px: Float64 = 1.0) -> Int:
        """The mesh id to draw this frame (see the file's header)."""
        return self.ids[self.pick_level(state, centre, scale, view, height_px, tol_px)]
