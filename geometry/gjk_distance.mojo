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


def _support(pts: List[Vec3], d: _D3) -> Int:
    var best = 0
    var bd = _dot(_D3.of(pts[0]), d)
    for i in range(1, len(pts)):
        var v = _dot(_D3.of(pts[i]), d)
        if v > bd:
            bd = v
            best = i
    return best


struct _Simplex(Movable):
    """Up to four vertices of A - B with the A / B support indices behind
    each, and the barycentric weights of the closest point."""

    var w: List[_D3]
    var ia: List[Int]
    var ib: List[Int]
    var lam: List[Float64]

    def __init__(out self):
        self.w = List[_D3]()
        self.ia = List[Int]()
        self.ib = List[Int]()
        self.lam = List[Float64]()

    def keep(mut self, idx: List[Int], lam: List[Float64]):
        var w = List[_D3]()
        var ia = List[Int]()
        var ib = List[Int]()
        for k in range(len(idx)):
            w.append(self.w[idx[k]])
            ia.append(self.ia[idx[k]])
            ib.append(self.ib[idx[k]])
        self.w = w^
        self.ia = ia^
        self.ib = ib^
        self.lam = lam.copy()


def _closest_segment(mut s: _Simplex, i: Int, j: Int) -> _D3:
    var a = s.w[i]
    var b = s.w[j]
    var ab = b - a
    var den = _dot(ab, ab)
    var t = Float64(0) if den <= 0 else -_dot(a, ab) / den
    if t <= 0:
        s.keep([i], [1.0])
        return a
    if t >= 1:
        s.keep([j], [1.0])
        return b
    s.keep([i, j], [1 - t, t])
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
        s.keep([i], [1.0])
        return a
    var bp = -b
    var d3 = _dot(ab, bp)
    var d4 = _dot(ac, bp)
    if d3 >= 0 and d4 <= d3:
        s.keep([j], [1.0])
        return b
    var vc = d1 * d4 - d3 * d2
    if vc <= 0 and d1 >= 0 and d3 <= 0:
        var v = d1 / (d1 - d3)
        s.keep([i, j], [1 - v, v])
        return a + ab * v
    var cp = -c
    var d5 = _dot(ab, cp)
    var d6 = _dot(ac, cp)
    if d6 >= 0 and d5 <= d6:
        s.keep([k], [1.0])
        return c
    var vb = d5 * d2 - d1 * d6
    if vb <= 0 and d2 >= 0 and d6 <= 0:
        var w = d2 / (d2 - d6)
        s.keep([i, k], [1 - w, w])
        return a + ac * w
    var va = d3 * d6 - d5 * d4
    if va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0:
        var w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
        s.keep([j, k], [1 - w, w])
        return b + (c - b) * w
    var den = va + vb + vc
    if den == 0:
        s.keep([i], [1.0])
        return a
    var v = vb / den
    var w = vc / den
    s.keep([i, j, k], [1 - v - w, v, w])
    return a + ab * v + ac * w


def _closest(mut s: _Simplex) -> Tuple[_D3, Bool]:
    """Closest point of the simplex hull to the origin; True when the origin
    is inside a full tetrahedron."""
    var n = len(s.w)
    if n == 1:
        s.lam = [1.0]
        return (s.w[0], False)
    if n == 2:
        return (_closest_segment(s, 0, 1), False)
    if n == 3:
        return (_closest_triangle(s, 0, 1, 2), False)
    # tetrahedron: the origin is inside unless it lies outside some face
    var faces: List[Int] = [0, 1, 2, 3, 0, 1, 3, 2, 0, 2, 3, 1, 1, 2, 3, 0]
    var best_v = _D3(0, 0, 0)
    var best_d = Float64(1e300)
    var best_idx = List[Int]()
    var best_lam = List[Float64]()
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
            t.w = [p, q, r]
            t.ia = [s.ia[faces[4 * f]], s.ia[faces[4 * f + 1]], s.ia[faces[4 * f + 2]]]
            t.ib = [s.ib[faces[4 * f]], s.ib[faces[4 * f + 1]], s.ib[faces[4 * f + 2]]]
            var v = _closest_triangle(t, 0, 1, 2)
            var dv = _dot(v, v)
            if dv < best_d:
                best_d = dv
                best_v = v
                # map t's kept vertices back to s's indices
                best_idx = List[Int]()
                for m in range(len(t.w)):
                    for z in range(4):
                        if t.ia[m] == s.ia[z] and t.ib[m] == s.ib[z]:
                            best_idx.append(z)
                            break
                best_lam = t.lam.copy()
    if not outside:
        return (_D3(0, 0, 0), True)
    s.keep(best_idx, best_lam)
    return (best_v, False)


def convex_distance(a: List[Vec3], ra: Real, b: List[Vec3], rb: Real) -> ConvexDistance:
    """Distance between conv(a) + ball(ra) and conv(b) + ball(rb). Both clouds
    non-empty."""
    var s = _Simplex()
    var ia = 0
    var ib = 0
    s.w.append(_D3.of(a[ia]) - _D3.of(b[ib]))
    s.ia.append(ia)
    s.ib.append(ib)
    s.lam.append(1.0)
    var v = s.w[0]
    var inside = False
    for _ in range(_ITERS):
        var vv = _dot(v, v)
        if vv <= 1e-24:
            inside = True
            break
        var na = _support(a, -v)
        var nb = _support(b, v)
        var w = _D3.of(a[na]) - _D3.of(b[nb])
        # converged: no support point gets meaningfully closer than v
        if vv - _dot(v, w) <= _REL_EPS * vv:
            break
        var dup = False
        for k in range(len(s.w)):
            if s.ia[k] == na and s.ib[k] == nb:
                dup = True
        if dup:
            break
        var keep_w = s.w.copy()
        var keep_ia = s.ia.copy()
        var keep_ib = s.ib.copy()
        var keep_lam = s.lam.copy()
        s.w.append(w)
        s.ia.append(na)
        s.ib.append(nb)
        var res = _closest(s)
        if res[1]:
            inside = True
            break
        var nv = res[0]
        if _dot(nv, nv) >= vv:  # no progress (round-off): the previous simplex stands
            s.w = keep_w^
            s.ia = keep_ia^
            s.ib = keep_ib^
            s.lam = keep_lam^
            break
        v = nv
    var pa = _D3.of(a[0])
    var pb = pa
    if not inside:  # on overlap the witnesses are undefined: both at a[0]
        pa = _D3(0, 0, 0)
        pb = _D3(0, 0, 0)
        for k in range(len(s.w)):
            pa = pa + _D3.of(a[s.ia[k]]) * s.lam[k]
            pb = pb + _D3.of(b[s.ib[k]]) * s.lam[k]
    var core = sqrt(_dot(v, v)) if not inside else Float64(0)
    var n = Vec3(0, 1, 0, 0)
    if core > 1e-12:
        var u = (pb - pa) * (1 / core)
        n = u.vec()
        pa = pa + u * Float64(ra)
        pb = pb - u * Float64(rb)
    var dist = Real(core) - ra - rb
    return ConvexDistance(dist, pa.vec(), pb.vec(), n, inside or dist <= 0)
