"""Separation distance and closest points of two convex shapes (ROADMAP 17.53).

`geometry.gjk` answers only "do they intersect". This is the distance form of
GJK (Gilbert-Johnson-Keerthi 1988; the simplex step as in Ericson,
Real-Time Collision Detection 9.5): it keeps the simplex point of the
Minkowski difference A - B closest to the origin, with its barycentric
weights, so the witness points on A and on B come out as the same
combinations of the support points that built the simplex.

A shape is a CORE point cloud plus a radius: a sphere is one point and r, a
capsule its segment and r, a box its 8 corners, a hull its vertices, a
triangle its 3 corners. The core distance comes from GJK; the radii are
subtracted along the separating direction afterwards, which is exact for
these Minkowski sums. Overlapping cores report `overlap` with distance
`-(ra + rb)` and both witnesses at A's first point (no depth: EPA gives the
depth when needed).

Computation is in Float64 whatever `WorldType` is: the simplex weights are
ratios of small determinants and lose too much in f32 for a stopping test.
"""

from std.math import sqrt
from .vec import Real, Vec3
from .gjk import Support3

comptime _ITERS = 64
comptime _REL_EPS = 1e-10


@fieldwise_init
struct _D3(Copyable, ImplicitlyCopyable, Movable):
    var x: Float64
    var y: Float64
    var z: Float64

    @staticmethod
    def of(v: Vec3) -> Self:
        return Self(Float64(v[0]), Float64(v[1]), Float64(v[2]))

    def vec(self) -> Vec3:
        return Vec3(Real(self.x), Real(self.y), Real(self.z), 0)

    def __add__(self, o: Self) -> Self:
        return Self(self.x + o.x, self.y + o.y, self.z + o.z)

    def __sub__(self, o: Self) -> Self:
        return Self(self.x - o.x, self.y - o.y, self.z - o.z)

    def __mul__(self, s: Float64) -> Self:
        return Self(self.x * s, self.y * s, self.z * s)

    def __neg__(self) -> Self:
        return Self(-self.x, -self.y, -self.z)


@always_inline
def _dot(a: _D3, b: _D3) -> Float64:
    return a.x * b.x + a.y * b.y + a.z * b.z


@always_inline
def _cross(a: _D3, b: _D3) -> _D3:
    return _D3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)


@fieldwise_init
struct ConvexDistance(Copyable, ImplicitlyCopyable, Movable):
    """`dist` between the surfaces (<= 0 when they overlap), the closest point
    on each, and `normal` from A toward B (unit; +y when undefined)."""

    var dist: Real
    var pa: Vec3
    var pb: Vec3
    var normal: Vec3
    var overlap: Bool


trait _Src:
    """What the distance driver needs from a shape: its support point along
    a Float64 direction."""

    def sup(self, d: _D3) -> _D3:
        ...

    def first(self) -> _D3:
        """The seed point (and the witness reported on overlap)."""
        ...

    def tol(self) -> Float64:
        """Relative stopping gap: a polytope converges exactly in a few
        steps, a curved support (ellipsoid, cylinder rim) only linearly."""
        ...

    def abs_tol(self) -> Float64:
        """Absolute stop: the distance improves by less than this (m)."""
        ...


struct _Cloud(_Src):
    """A borrowed point cloud: argmax of the Float64 dot, so a list behaves
    exactly as before the 17.52 generalisation."""

    var p: Pointer[List[Vec3], ImmUntrackedOrigin]

    def __init__(out self, pts: List[Vec3]):
        self.p = Pointer(to=pts).unsafe_origin_cast[ImmUntrackedOrigin]()

    def sup(self, d: _D3) -> _D3:
        ref pts = self.p[]
        var best = 0
        var bd = _dot(_D3.of(pts[0]), d)
        for i in range(1, len(pts)):
            var v = _dot(_D3.of(pts[i]), d)
            if v > bd:
                bd = v
                best = i
        return _D3.of(pts[best])

    def first(self) -> _D3:
        return _D3.of(self.p[][0])

    def tol(self) -> Float64:
        return _REL_EPS

    def abs_tol(self) -> Float64:
        return 0


struct _Shape[S: Support3](_Src):
    """Any `Support3` shape (ROADMAP 17.52): the direction is rounded to the
    world scalar for the call."""

    var s: Pointer[Self.S, ImmUntrackedOrigin]

    def __init__(out self, s: Self.S):
        self.s = Pointer(to=s).unsafe_origin_cast[ImmUntrackedOrigin]()

    def sup(self, d: _D3) -> _D3:
        return _D3.of(self.s[].support_point(d.vec()))

    def first(self) -> _D3:
        return _D3.of(self.s[].support_point(Vec3(1, 0, 0, 0)))

    def tol(self) -> Float64:
        # distance error <= 1e-6 of the distance: below f32 resolution,
        # and 64 linear steps to 1e-10 cost 12 us per cylinder query
        return 1e-6

    def abs_tol(self) -> Float64:
        # 0.1 um: near contact the relative gap (1e-6 x distance^2) is
        # tiny and a curved shape on a flat face took 16 us to reach it
        return 1e-7


struct _Simplex(Copyable, Movable):
    """Up to four vertices of A - B with the A / B support points behind
    each (`sa`, `sb`), an identity per vertex (`vid`), and the barycentric
    weights of the closest point. Fixed four-slot storage: with `List`
    fields every iteration allocated a dozen times, 1.5 us per GJK step."""

    var w: Array[_D3, 4]
    var sa: Array[_D3, 4]
    var sb: Array[_D3, 4]
    var vid: Array[Int, 4]
    var lam: Array[Float64, 4]
    var n: Int

    def __init__(out self):
        self.w = Array[_D3, 4](fill=_D3(0, 0, 0))
        self.sa = Array[_D3, 4](fill=_D3(0, 0, 0))
        self.sb = Array[_D3, 4](fill=_D3(0, 0, 0))
        self.vid = Array[Int, 4](fill=0)
        self.lam = Array[Float64, 4](fill=0)
        self.n = 0

    def push(mut self, w: _D3, a: _D3, b: _D3, id: Int):
        self.w[self.n] = w
        self.sa[self.n] = a
        self.sb[self.n] = b
        self.vid[self.n] = id
        self.n += 1

    def keep(mut self, cnt: Int, i0: Int, i1: Int, i2: Int, l0: Float64, l1: Float64, l2: Float64):
        """Reduce to vertices i0 (, i1 (, i2)) with weights l0, l1, l2."""
        var idx = Array[Int, 3](fill=0)
        idx[0] = i0
        idx[1] = i1
        idx[2] = i2
        var w = self.w.copy()
        var sa = self.sa.copy()
        var sb = self.sb.copy()
        var vid = self.vid.copy()
        for k in range(cnt):
            self.w[k] = w[idx[k]]
            self.sa[k] = sa[idx[k]]
            self.sb[k] = sb[idx[k]]
            self.vid[k] = vid[idx[k]]
        self.lam[0] = l0
        self.lam[1] = l1
        self.lam[2] = l2
        self.n = cnt


def _closest_segment(mut s: _Simplex, i: Int, j: Int) -> _D3:
    var a = s.w[i]
    var b = s.w[j]
    var ab = b - a
    var den = _dot(ab, ab)
    var t = Float64(0) if den <= 0 else -_dot(a, ab) / den
    if t <= 0:
        s.keep(1, i, 0, 0, 1.0, 0, 0)
        return a
    if t >= 1:
        s.keep(1, j, 0, 0, 1.0, 0, 0)
        return b
    s.keep(2, i, j, 0, 1 - t, t, 0)
    return a + ab * t


def _closest_triangle(mut s: _Simplex, i: Int, j: Int, k: Int) -> _D3:
    """Ericson 5.1.5 with p = origin; reduces the simplex to the feature."""
    var a = s.w[i]
    var b = s.w[j]
    var c = s.w[k]
    var ab = b - a
    var ac = c - a
    var ap = -a
    var d1 = _dot(ab, ap)
    var d2 = _dot(ac, ap)
    if d1 <= 0 and d2 <= 0:
        s.keep(1, i, 0, 0, 1.0, 0, 0)
        return a
    var bp = -b
    var d3 = _dot(ab, bp)
    var d4 = _dot(ac, bp)
    if d3 >= 0 and d4 <= d3:
        s.keep(1, j, 0, 0, 1.0, 0, 0)
        return b
    var vc = d1 * d4 - d3 * d2
    if vc <= 0 and d1 >= 0 and d3 <= 0:
        var v = d1 / (d1 - d3)
        s.keep(2, i, j, 0, 1 - v, v, 0)
        return a + ab * v
    var cp = -c
    var d5 = _dot(ab, cp)
    var d6 = _dot(ac, cp)
    if d6 >= 0 and d5 <= d6:
        s.keep(1, k, 0, 0, 1.0, 0, 0)
        return c
    var vb = d5 * d2 - d1 * d6
    if vb <= 0 and d2 >= 0 and d6 <= 0:
        var w = d2 / (d2 - d6)
        s.keep(2, i, k, 0, 1 - w, w, 0)
        return a + ac * w
    var va = d3 * d6 - d5 * d4
    if va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0:
        var w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
        s.keep(2, j, k, 0, 1 - w, w, 0)
        return b + (c - b) * w
    var den = va + vb + vc
    if den == 0:
        s.keep(1, i, 0, 0, 1.0, 0, 0)
        return a
    var v = vb / den
    var w = vc / den
    s.keep(3, i, j, k, 1 - v - w, v, w)
    return a + ab * v + ac * w


def _closest(mut s: _Simplex) -> Tuple[_D3, Bool]:
    """Closest point of the simplex hull to the origin; True when the origin
    is inside a full tetrahedron."""
    var n = s.n
    if n == 1:
        s.lam[0] = 1.0
        return (s.w[0], False)
    if n == 2:
        return (_closest_segment(s, 0, 1), False)
    if n == 3:
        return (_closest_triangle(s, 0, 1, 2), False)
    # tetrahedron: the origin is inside unless it lies outside some face
    var faces: Array[Int, 16] = [0, 1, 2, 3, 0, 1, 3, 2, 0, 2, 3, 1, 1, 2, 3, 0]
    var best_v = _D3(0, 0, 0)
    var best_d = Float64(1e300)
    var best_cnt = 0
    var best_idx = Array[Int, 3](fill=0)
    var best_lam = Array[Float64, 3](fill=0)
    var outside = False
    for f in range(4):
        var p = s.w[faces[4 * f]]
        var q = s.w[faces[4 * f + 1]]
        var r = s.w[faces[4 * f + 2]]
        var o = s.w[faces[4 * f + 3]]
        var nrm = _cross(q - p, r - p)
        var side_o = _dot(nrm, -p)
        var side_x = _dot(nrm, o - p)
        if side_o * side_x < 0:  # origin and the 4th vertex on opposite sides
            outside = True
            var t = _Simplex()
            for m in range(3):
                var z = faces[4 * f + m]
                t.push(s.w[z], s.sa[z], s.sb[z], s.vid[z])
            var v = _closest_triangle(t, 0, 1, 2)
            var dv = _dot(v, v)
            if dv < best_d:
                best_d = dv
                best_v = v
                # map t's kept vertices back to s's indices
                best_cnt = t.n
                for m in range(t.n):
                    for z in range(4):
                        if t.vid[m] == s.vid[z]:
                            best_idx[m] = z
                            break
                    best_lam[m] = t.lam[m]
    if not outside:
        return (_D3(0, 0, 0), True)
    s.keep(best_cnt, best_idx[0], best_idx[1], best_idx[2], best_lam[0], best_lam[1], best_lam[2])
    return (best_v, False)


def _same(a: _D3, b: _D3) -> Bool:
    return a.x == b.x and a.y == b.y and a.z == b.z


def _distance[A: _Src, B: _Src](a: A, ra: Real, b: B, rb: Real) -> ConvexDistance:
    """The GJK distance driver over two support sources."""
    var s = _Simplex()
    var a0 = a.first()
    var b0 = b.first()
    s.push(a0 - b0, a0, b0, 0)
    s.lam[0] = 1.0
    var next_id = 1
    var eps = max(a.tol(), b.tol())
    var eps_abs = max(a.abs_tol(), b.abs_tol())
    var v = s.w[0]
    var inside = False
    for _ in range(_ITERS):
        var vv = _dot(v, v)
        if vv <= 1e-24:
            inside = True
            break
        var na = a.sup(-v)
        var nb = b.sup(v)
        var w = na - nb
        # converged: no support point gets meaningfully closer than v
        var gap = vv - _dot(v, w)
        if gap <= eps * vv or gap <= eps_abs * sqrt(vv):
            break
        var dup = False
        for k in range(s.n):
            if _same(s.sa[k], na) and _same(s.sb[k], nb):
                dup = True
        if dup:
            break
        var keep = s.copy()
        s.push(w, na, nb, next_id)
        next_id += 1
        var res = _closest(s)
        if res[1]:
            inside = True
            break
        var nv = res[0]
        if _dot(nv, nv) >= vv:  # no progress (round-off): the previous simplex stands
            s = keep^
            break
        v = nv
    var pa = a0
    var pb = pa
    if not inside:  # on overlap the witnesses are undefined: both at A's seed point
        pa = _D3(0, 0, 0)
        pb = _D3(0, 0, 0)
        for k in range(s.n):
            pa = pa + s.sa[k] * s.lam[k]
            pb = pb + s.sb[k] * s.lam[k]
    var core = sqrt(_dot(v, v)) if not inside else Float64(0)
    var n = Vec3(0, 1, 0, 0)
    if core > 1e-12:
        var u = (pb - pa) * (1 / core)
        n = u.vec()
        pa = pa + u * Float64(ra)
        pb = pb - u * Float64(rb)
    var dist = Real(core) - ra - rb
    return ConvexDistance(dist, pa.vec(), pb.vec(), n, inside or dist <= 0)


def convex_distance(a: List[Vec3], ra: Real, b: List[Vec3], rb: Real) -> ConvexDistance:
    """Distance between conv(a) + ball(ra) and conv(b) + ball(rb). Both clouds
    non-empty."""
    return _distance(_Cloud(a), ra, _Cloud(b), rb)


def support_distance[A: Support3, B: Support3](a: A, ra: Real, b: B, rb: Real) -> ConvexDistance:
    """Distance between two `Support3` shapes, each grown by a radius
    (ROADMAP 17.52): an ellipsoid or cylinder exactly, with no sampled hull.
    Same result fields as `convex_distance`."""
    return _distance(_Shape(a), ra, _Shape(b), rb)
