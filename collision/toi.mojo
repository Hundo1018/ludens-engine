"""Swept/TOI CCD: exact linear-cast time of impact between oriented boxes.

Speculative margins (first-stage CCD, `solver6._collect_pairs`) stop fast
movers *near* the surface but tolerate a transient overshoot — the solver only
sees the gap at substep granularity. The second stage closes that hole: sweep
the box along its per-substep displacement and clamp the pose advance to the
time of impact, so surfaces can never interpenetrate no matter the speed
(Jolt LinearCast / Box2D TOI direction).

`swept_box_toi` is a SWEPT SAT: for two convex boxes under linear relative
motion the earliest touching time is the latest axis-interval entry over the
15 OBB separating axes (6 faces + 9 edge crosses), and the pair misses iff
some axis interval never overlaps or the entry/exit windows are disjoint.
This is exact (not conservative-advancement iteration) because projections of
a linear motion onto a fixed axis move linearly. Axis normalization is skipped
on purpose: entry/exit times are ratios along the axis, invariant to |L|.

Rotation during the step is ignored (linear cast) — the standard trade: the
solver's speculative stage already bounds angular tunnelling for box-scale
spin, and the cast is re-run every substep.
"""

from geometry.vec import Real, Vec3, dot
from collision.manifold import Axes3


@fieldwise_init
struct ToiResult(Copyable, ImplicitlyCopyable, Movable):
    var hit: Bool
    var t: Real  # fraction of the displacement in [0, 1] (0 = already touching)


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return Vec3(
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def _radius(ax: Axes3, h: Vec3, l: Vec3) -> Real:
    """Projection half-width of an oriented box onto (unnormalized) axis `l`."""
    return (
        h[0] * abs(dot(ax[0], l))
        + h[1] * abs(dot(ax[1], l))
        + h[2] * abs(dot(ax[2], l))
    )


def swept_box_toi(
    ca: Vec3,
    axa: Axes3,
    ha: Vec3,
    cb: Vec3,
    axb: Axes3,
    hb: Vec3,
    rel_disp: Vec3,
) -> ToiResult:
    """Earliest touching time of box `b` displaced by `rel_disp` relative to a
    stationary box `a`, as a fraction of `rel_disp` in [0, 1]."""
    var axes = InlineArray[Vec3, 15](fill=Vec3(0, 0, 0))
    var count = 0
    comptime for i in range(3):
        axes[count] = axa[i]
        count += 1
        axes[count] = axb[i]
        count += 1
    comptime for i in range(3):
        comptime for j in range(3):
            axes[count] = _cross(axa[i], axb[j])
            count += 1

    var t_enter = Real(0)
    var t_exit = Real(1)
    var d = cb - ca
    for k in range(count):
        var l = axes[k]
        if dot(l, l) < 1e-12:  # near-parallel edge cross: degenerate axis
            continue
        var d0 = dot(d, l)
        var v = dot(rel_disp, l)
        var r = _radius(axa, ha, l) + _radius(axb, hb, l)
        if abs(v) < 1e-12:
            if abs(d0) > r:
                return ToiResult(False, 1)  # separated on l for all t
            continue  # overlapping on l for all t: no constraint
        var t0 = (-r - d0) / v
        var t1 = (r - d0) / v
        if t0 > t1:
            var tmp = t0
            t0 = t1
            t1 = tmp
        if t0 > t_enter:
            t_enter = t0
        if t1 < t_exit:
            t_exit = t1
        if t_enter > t_exit:
            return ToiResult(False, 1)
    return ToiResult(True, t_enter)
