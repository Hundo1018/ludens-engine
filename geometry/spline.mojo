"""Parametric curves: piecewise cubic Bezier and Catmull-Rom (uniform /
centripetal / chordal, selected by a comptime `alpha`), dimension-generic like
`geometry.vec` (`SIMD[WorldType, PadW[dim]]`). Arc-length tables (build once,
then binary-search `sample_at_distance`), closest-point queries (coarse sample
+ Newton), and rotation-minimising (parallel-transport) frames as PGA motors
(`geometry.motor`) — the math substrate 17.4 (vehicle racing lines), 17.14/
17.15 (AI patrol paths / navigation smoothing) and 17.3 (IK look-at paths) all
need: a body riding a motor frame down the curve does not twist, which is the
advantage over "position + separately re-derived look-at quaternion" (a
look-at recomputed independently at each sample has no memory of the previous
frame's roll, so it drifts/flips near vertical tangents; a transported frame
does not).

Unifying trick: BOTH families reduce to one evaluator. A Catmull-Rom segment
(any `alpha`, i.e. any knot spacing) is, as a function of its LOCAL parameter
u in [0,1], a cubic polynomial — so it has an exact Hermite (endpoint value +
tangent) representation, which converts to an exact equivalent `CubicBezier`
via the standard `B1 = P(0) + P'(0)/3`, `B2 = P(1) - P'(1)/3` formula
(`CatmullRom.segment_bezier`). All the shared machinery (arc-length table,
`sample_at_distance`, `closest_point`, RMF frames) therefore operates on ONE
type, `BezierPath[dim]`; `CatmullRom` is a constructor for it. Feeding the
uniform case (`alpha = 0`) through this general path reproduces the textbook
closed-form uniform-Catmull-Rom-as-Bezier control points
`P1, P1 + (P2-P0)/6, P2 - (P3-P1)/6, P2` exactly — that equivalence is the
seam parity check in `tests/test_spline_parity.mojo`.

Value+derivative are propagated TOGETHER through the Barry-Goldman nested-lerp
construction (`_bg_eval_deriv`) as a forward-mode (value, d/dt) pair: every
stage is an affine blend with a parameter-linear weight, so differentiating it
is exact algebra, not a finite difference — no epsilon to tune, no truncation
error, and it stays well-defined (no NaN) even across a zero-length segment
(coincident control points) because knot deltas are floored above zero rather
than divided-by-raw-distance.
"""

from std.math import sqrt, acos, isfinite, pow
from .vec import Real, WorldType, PadW, Vec3, dot, length, length_sq, normalize
from .quat import Quat
from .motor import Motor3
from .galie import geodesic3

comptime _EPS: Real = 1e-8
comptime _KNOT_EPS: Real = 1e-3
"""Floor for a Catmull-Rom knot delta (`CatmullRom._knot_delta`), distinct
from the general `_EPS`. Knot values accumulate (t1, t2, t3 are running
sums), so flooring a coincident-point delta at `_EPS` (1e-8) is not enough:
float32 has ~1.2e-7 relative precision, so adding 1e-8 to an accumulated
knot around magnitude 1 is a NO-OP after rounding -- `t2` rounds back to
exactly `t1`, `1/(t2-t1)` becomes float `Inf`, and the Barry-Goldman
derivative comes out NaN instead of merely large. 1e-3 stays representable
against accumulated knots up to O(100-1000) and keeps the derivative
amplification (`1/delta`) from turning ordinary floating-point rounding
noise into an O(1) error (found empirically: `tests/test_spline.mojo`'s
coincident-point case NaN'd with the smaller floor)."""


def _cross3(a: Vec3, b: Vec3) -> Vec3:
    return Vec3(
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
        0,
    )


# ------------------------------------------------------------- Barry-Goldman
def _lerp_vd[dim: Int](
    ts: Real, te: Real, t: Real,
    lv: SIMD[WorldType, PadW[dim]], ld: SIMD[WorldType, PadW[dim]],
    rv: SIMD[WorldType, PadW[dim]], rd: SIMD[WorldType, PadW[dim]],
) -> Tuple[SIMD[WorldType, PadW[dim]], SIMD[WorldType, PadW[dim]]]:
    """One affine blend `lv*bl(t) + rv*br(t)` (bl+br=1, both linear in t),
    propagating (value, d/dt) through it via the product rule. `te == ts`
    never reaches here: callers floor every knot delta above zero."""
    var inv = Real(1) / (te - ts)
    var bl = (te - t) * inv
    var br = (t - ts) * inv
    var dbl = -inv
    var dbr = inv
    var v = lv * bl + rv * br
    var d = ld * bl + lv * dbl + rd * br + rv * dbr
    return (v, d)


def _bg_eval_deriv[dim: Int](
    p0: SIMD[WorldType, PadW[dim]], p1: SIMD[WorldType, PadW[dim]],
    p2: SIMD[WorldType, PadW[dim]], p3: SIMD[WorldType, PadW[dim]],
    t0: Real, t1: Real, t2: Real, t3: Real, t: Real,
) -> Tuple[SIMD[WorldType, PadW[dim]], SIMD[WorldType, PadW[dim]]]:
    """Barry-Goldman recursive evaluation of a generalized Catmull-Rom
    segment (arbitrary knot spacing t0<t1<t2<t3, so uniform / centripetal /
    chordal share this one formula) as (value, d/dt) at global parameter t."""
    var zero = p0 * 0
    var a1 = _lerp_vd[dim](t0, t1, t, p0, zero, p1, zero)
    var a2 = _lerp_vd[dim](t1, t2, t, p1, zero, p2, zero)
    var a3 = _lerp_vd[dim](t2, t3, t, p2, zero, p3, zero)
    var b1 = _lerp_vd[dim](t0, t2, t, a1[0], a1[1], a2[0], a2[1])
    var b2 = _lerp_vd[dim](t1, t3, t, a2[0], a2[1], a3[0], a3[1])
    var c = _lerp_vd[dim](t1, t2, t, b1[0], b1[1], b2[0], b2[1])
    return c


# ------------------------------------------------------------- CubicBezier
struct CubicBezier[dim: Int](Copyable, Movable):
    """One cubic Bezier segment over local parameter u in [0,1]."""

    comptime W = PadW[Self.dim]
    var p0: SIMD[WorldType, Self.W]
    var p1: SIMD[WorldType, Self.W]
    var p2: SIMD[WorldType, Self.W]
    var p3: SIMD[WorldType, Self.W]

    def __init__(
        out self,
        p0: SIMD[WorldType, Self.W],
        p1: SIMD[WorldType, Self.W],
        p2: SIMD[WorldType, Self.W],
        p3: SIMD[WorldType, Self.W],
    ):
        self.p0 = p0
        self.p1 = p1
        self.p2 = p2
        self.p3 = p3

    def eval(self, u: Real) -> SIMD[WorldType, Self.W]:
        var mu = Real(1) - u
        var mu2 = mu * mu
        var u2 = u * u
        return (
            self.p0 * (mu2 * mu)
            + self.p1 * (3 * mu2 * u)
            + self.p2 * (3 * mu * u2)
            + self.p3 * (u2 * u)
        )

    def deriv(self, u: Real) -> SIMD[WorldType, Self.W]:
        """Derivative d/du, NOT normalized — magnitude is the local parametric speed."""
        var mu = Real(1) - u
        return (
            (self.p1 - self.p0) * (3 * mu * mu)
            + (self.p2 - self.p1) * (6 * mu * u)
            + (self.p3 - self.p2) * (3 * u * u)
        )

    def eval_deriv(
        self, u: Real
    ) -> Tuple[SIMD[WorldType, Self.W], SIMD[WorldType, Self.W]]:
        """Value and derivative together, sharing the `mu`/`u` powers."""
        var mu = Real(1) - u
        var mu2 = mu * mu
        var u2 = u * u
        var value = (
            self.p0 * (mu2 * mu)
            + self.p1 * (3 * mu2 * u)
            + self.p2 * (3 * mu * u2)
            + self.p3 * (u2 * u)
        )
        var deriv = (
            (self.p1 - self.p0) * (3 * mu2)
            + (self.p2 - self.p1) * (6 * mu * u)
            + (self.p3 - self.p2) * (3 * u2)
        )
        return (value, deriv)


# ------------------------------------------------------------- BezierPath
struct BezierPath[dim: Int](Copyable, Movable):
    """A chain of `CubicBezier[dim]` segments, C0-joined; global parameter t
    in [0, segment_count], segment i owning [i, i+1]. This is the ONE
    evaluatable curve type every piece of shared machinery below (arc-length
    table, closest point, RMF frames) is written against."""

    comptime W = PadW[Self.dim]
    var segs: List[CubicBezier[Self.dim]]

    def __init__(out self, var segs: List[CubicBezier[Self.dim]]) raises:
        if len(segs) == 0:
            raise Error("BezierPath requires at least 1 segment")
        self.segs = segs^

    def segment_count(self) -> Int:
        return len(self.segs)

    def domain_max(self) -> Real:
        return Real(len(self.segs))

    def _locate(self, t: Real) -> Tuple[Int, Real]:
        var dmax = self.domain_max()
        var tt = t
        if tt < 0:
            tt = 0
        if tt > dmax:
            tt = dmax
        var i = Int(tt)
        var nseg = len(self.segs)
        if i >= nseg:
            i = nseg - 1
        var u = tt - Real(i)
        return (i, u)

    def eval(self, t: Real) -> SIMD[WorldType, Self.W]:
        var loc = self._locate(t)
        return self.segs[loc[0]].eval(loc[1])

    def deriv(self, t: Real) -> SIMD[WorldType, Self.W]:
        var loc = self._locate(t)
        return self.segs[loc[0]].deriv(loc[1])

    def eval_deriv(
        self, t: Real
    ) -> Tuple[SIMD[WorldType, Self.W], SIMD[WorldType, Self.W]]:
        var loc = self._locate(t)
        return self.segs[loc[0]].eval_deriv(loc[1])


# ------------------------------------------------------------- CatmullRom
struct CatmullRom[dim: Int, alpha: Float64 = 0.5](Copyable, Movable):
    """Generalized Catmull-Rom through `points`: `alpha = 0` uniform,
    `0.5` centripetal (the usual default -- avoids cusps/self-intersections
    that uniform can produce on unevenly-spaced points), `1` chordal.
    Missing neighbours at the open ends are synthesized by mirror
    reflection (`P[-1] = 2 P[0] - P[1]`), which is why 2 control points is
    already a valid (single-segment) curve, not a degenerate one."""

    comptime W = PadW[Self.dim]
    var points: List[SIMD[WorldType, Self.W]]
    var closed: Bool

    def __init__(
        out self,
        var points: List[SIMD[WorldType, Self.W]],
        closed: Bool = False,
    ) raises:
        if len(points) < 2:
            raise Error("CatmullRom requires at least 2 control points")
        self.points = points^
        self.closed = closed

    def _n(self) -> Int:
        return len(self.points)

    def _at(self, i: Int) -> SIMD[WorldType, Self.W]:
        var n = self._n()
        if self.closed:
            var j = i % n
            if j < 0:
                j += n
            return self.points[j]
        if i < 0:
            return self.points[0] * 2 - self.points[1]
        if i >= n:
            return self.points[n - 1] * 2 - self.points[n - 2]
        return self.points[i]

    def segment_count(self) -> Int:
        return self._n() if self.closed else self._n() - 1

    def domain_max(self) -> Real:
        return Real(self.segment_count())

    def _knot_delta(
        self, a: SIMD[WorldType, Self.W], b: SIMD[WorldType, Self.W]
    ) -> Real:
        comptime if Self.alpha == 0.0:
            return Real(1)
        else:
            var d = length(a - b)
            var dp = pow(d, Real(Self.alpha))
            return dp if dp > _KNOT_EPS else _KNOT_EPS

    def segment_bezier(self, i: Int) -> CubicBezier[Self.dim]:
        """The `alpha`-parameterized segment i, converted to its exact
        equivalent `CubicBezier` (Hermite-to-Bezier on the Barry-Goldman
        value/tangent at the segment's two ends, w.r.t. LOCAL u)."""
        var p0 = self._at(i - 1)
        var p1 = self._at(i)
        var p2 = self._at(i + 1)
        var p3 = self._at(i + 2)
        var t0: Real = 0
        var t1 = t0 + self._knot_delta(p0, p1)
        var t2 = t1 + self._knot_delta(p1, p2)
        var t3 = t2 + self._knot_delta(p2, p3)
        var vd1 = _bg_eval_deriv[Self.dim](p0, p1, p2, p3, t0, t1, t2, t3, t1)
        var vd2 = _bg_eval_deriv[Self.dim](p0, p1, p2, p3, t0, t1, t2, t3, t2)
        var dt = t2 - t1
        var m1 = vd1[1] * dt  # tangent w.r.t. LOCAL u (chain rule: dt/du = t2-t1)
        var m2 = vd2[1] * dt
        return CubicBezier[Self.dim](
            vd1[0], vd1[0] + m1 / 3.0, vd2[0] - m2 / 3.0, vd2[0]
        )

    def _locate(self, t: Real) -> Tuple[Int, Real]:
        var dmax = self.domain_max()
        var tt = t
        if tt < 0:
            tt = 0
        if tt > dmax:
            tt = dmax
        var i = Int(tt)
        var nseg = self.segment_count()
        if i >= nseg:
            i = nseg - 1
        var u = tt - Real(i)
        return (i, u)

    def eval(self, t: Real) -> SIMD[WorldType, Self.W]:
        var loc = self._locate(t)
        return self.segment_bezier(loc[0]).eval(loc[1])

    def deriv(self, t: Real) -> SIMD[WorldType, Self.W]:
        var loc = self._locate(t)
        return self.segment_bezier(loc[0]).deriv(loc[1])

    def to_bezier_path(self) raises -> BezierPath[Self.dim]:
        var segs = List[CubicBezier[Self.dim]]()
        for i in range(self.segment_count()):
            segs.append(self.segment_bezier(i))
        return BezierPath[Self.dim](segs^)


# ------------------------------------------------------------- arc length
struct ArcLengthTable(Copyable, Movable):
    """Cumulative chord length sampled at N uniform PARAMETER steps.
    `sample_at_distance` inverts it: binary search for the bracketing pair,
    then one linear (chord) refine inside it -- exact for a straight chord,
    approximate (to the table's sampling density) for the true curve."""

    var ts: List[Real]
    var cum: List[Real]

    def __init__(out self, var ts: List[Real], var cum: List[Real]):
        self.ts = ts^
        self.cum = cum^

    def total_length(self) -> Real:
        return self.cum[len(self.cum) - 1]

    def sample_at_distance(self, s: Real) -> Real:
        var n = len(self.cum)
        if s <= 0:
            return self.ts[0]
        var total = self.cum[n - 1]
        if s >= total:
            return self.ts[n - 1]
        var lo = 0
        var hi = n - 1
        while hi - lo > 1:
            var mid = (lo + hi) // 2
            if self.cum[mid] <= s:
                lo = mid
            else:
                hi = mid
        var s0 = self.cum[lo]
        var s1 = self.cum[hi]
        var t0 = self.ts[lo]
        var t1 = self.ts[hi]
        var span = s1 - s0
        if span < _EPS:
            return t0
        var frac = (s - s0) / span
        return t0 + frac * (t1 - t0)


def build_arc_length_table[dim: Int](
    path: BezierPath[dim], n_samples: Int
) -> ArcLengthTable:
    debug_assert(n_samples >= 2, "arc-length table needs >= 2 samples")
    var ts = List[Real]()
    var cum = List[Real]()
    var dmax = path.domain_max()
    var prev = path.eval(Real(0))
    ts.append(Real(0))
    cum.append(Real(0))
    var acc: Real = 0
    var denom = Real(n_samples - 1)
    for i in range(1, n_samples):
        var t = dmax * Real(i) / denom
        var p = path.eval(t)
        acc += length(p - prev)
        ts.append(t)
        cum.append(acc)
        prev = p
    return ArcLengthTable(ts^, cum^)


# ------------------------------------------------------------- closest point
def closest_point[dim: Int](
    path: BezierPath[dim],
    query: SIMD[WorldType, PadW[dim]],
    n_coarse: Int = 16,
    newton_iters: Int = 8,
) -> Real:
    """Coarse uniform-parameter sampling to bracket the nearest segment, then
    Gauss-Newton on `f(t) = (C(t)-query) . C'(t) = 0` (drops the C'' term of
    the true Newton step -- standard for point-projection, avoids needing a
    second derivative, stable once bracketed). Every step is clamped back
    into [best-h, best+h] and checked for finiteness, so a query at infinity
    (or any other pathological input) still returns a finite in-domain t
    rather than propagating a NaN/Inf out."""
    var dmax = path.domain_max()
    debug_assert(n_coarse >= 1, "closest_point needs >= 1 coarse sample")
    var best_t: Real = 0
    var best_d2 = length_sq(path.eval(Real(0)) - query)
    for i in range(1, n_coarse + 1):
        var t = dmax * Real(i) / Real(n_coarse)
        var d2 = length_sq(path.eval(t) - query)
        if d2 < best_d2:
            best_d2 = d2
            best_t = t
    var h = dmax / Real(n_coarse)
    var lo = best_t - h
    var hi = best_t + h
    if lo < 0:
        lo = 0
    if hi > dmax:
        hi = dmax
    var t = best_t
    for _ in range(newton_iters):
        var vd = path.eval_deriv(t)
        var diff = vd[0] - query
        var num = dot(diff, vd[1])
        var dd = dot(vd[1], vd[1])
        if dd < _EPS:
            break
        var tn = t - num / dd
        if not Bool(isfinite(tn).reduce_and()):
            break
        if tn < lo:
            tn = lo
        if tn > hi:
            tn = hi
        t = tn
    return t


# ------------------------------------------------------------- RMF frames
def _min_rotation(from_dir: Vec3, to_dir: Vec3) -> Quat:
    """Minimal-angle quaternion rotating unit `from_dir` onto unit `to_dir`.
    The rotation axis (`from_dir x to_dir`) is perpendicular to BOTH tangent
    directions by construction, so composing this once per curve sample is a
    parallel-transport update: it carries zero rotation component about
    either tangent, i.e. no twist is introduced -- the defining property of
    a rotation-minimising frame (Hanson & Ma 1995's "parallel transport
    approach to curve framing")."""
    var d = dot(from_dir, to_dir)
    if d > Real(0.999999):
        return Quat.identity()
    if d < Real(-0.999999):
        # 180-degree flip: any axis perpendicular to from_dir works.
        var axis = _cross3(Vec3(1, 0, 0, 0), from_dir)
        if length_sq(axis) < _EPS:
            axis = _cross3(Vec3(0, 1, 0, 0), from_dir)
        return Quat.from_axis_angle(normalize(axis), Real(3.14159265358979))
    var axis = normalize(_cross3(from_dir, to_dir))
    var clamped = d
    if clamped > 1:
        clamped = 1
    if clamped < -1:
        clamped = -1
    return Quat.from_axis_angle(axis, acos(clamped))


def build_rmf_frames(path: BezierPath[3], table: ArcLengthTable) -> List[Motor3]:
    """Rotation-minimising frames as `Motor3`, one per sample of `table`
    (so `frame_at_distance` can reuse the same bracket search). A frame's
    local +Z is the unit tangent; +X/+Y are propagated by `_min_rotation`
    from the PREVIOUS tangent, never re-derived from scratch, which is what
    keeps the ride twist-free. A near-zero local speed (a coincident-point
    / zero-length segment) holds the previous tangent instead of normalizing
    a near-zero vector."""
    var n = len(table.ts)
    debug_assert(n >= 1, "build_rmf_frames needs a non-empty table")
    var frames = List[Motor3]()
    var prev_tan = Vec3(0, 0, 1, 0)
    var q = Quat.identity()
    for i in range(n):
        var t = table.ts[i]
        var vd = path.eval_deriv(t)
        var speed_sq = length_sq(vd[1])
        var tan: Vec3
        if speed_sq < _EPS * _EPS:
            tan = prev_tan
        else:
            tan = vd[1] / sqrt(speed_sq)
        if i == 0:
            q = _min_rotation(Vec3(0, 0, 1, 0), tan)
        else:
            q = _min_rotation(prev_tan, tan) * q
        prev_tan = tan
        frames.append(Motor3.from_quat_translation(q, vd[0]))
    return frames^


def frame_at_distance(
    frames: List[Motor3], table: ArcLengthTable, s: Real
) -> Motor3:
    """The RMF at arc length `s`, by screw (geodesic) interpolation between
    the two bracketing discrete frames — a straight line on the motor
    manifold between two twist-free frames stays twist-free, unlike
    re-deriving a look-at quaternion at the query point would."""
    var n = len(table.cum)
    debug_assert(
        len(frames) == n, "frames must come from build_rmf_frames(path, table)"
    )
    if s <= 0:
        return frames[0]
    var total = table.cum[n - 1]
    if s >= total:
        return frames[n - 1]
    var lo = 0
    var hi = n - 1
    while hi - lo > 1:
        var mid = (lo + hi) // 2
        if table.cum[mid] <= s:
            lo = mid
        else:
            hi = mid
    var s0 = table.cum[lo]
    var s1 = table.cum[hi]
    var span = s1 - s0
    var frac: Real = 0
    if span > _EPS:
        frac = (s - s0) / span
    return geodesic3(frames[lo], frames[hi], frac)
