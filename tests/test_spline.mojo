# tier: unit
"""`geometry.spline` contract: `CubicBezier`, `BezierPath` and `CatmullRom`
(uniform / centripetal / chordal), the arc-length table, and `closest_point`.
Ordinary cases first, then the extreme cases the design note calls out: 2
control points, coincident control points (zero-length segment, no NaN
tangent), a closed loop, a query exactly on the curve, and a query at
infinity."""

from std.math import isfinite
from harness.runner import Suite
from geometry.vec import Real, WorldType, PadW, Vec2, Vec3, length, length_sq
from geometry.spline import (
    CubicBezier, BezierPath, CatmullRom, ArcLengthTable,
    build_arc_length_table, closest_point,
)


def _finite3(v: Vec3) -> Bool:
    return Bool(isfinite(v).reduce_and())


def _near3(mut s: Suite, a: Vec3, b: Vec3, label: String, tol: Float64 = 1e-4):
    s.almost(Float64(a[0]), Float64(b[0]), label + " .x", tol)
    s.almost(Float64(a[1]), Float64(b[1]), label + " .y", tol)
    s.almost(Float64(a[2]), Float64(b[2]), label + " .z", tol)


def main() raises:
    var s = Suite("spline")

    # ============================================================ ordinary
    # --- CubicBezier: endpoints, and eval_deriv agrees with eval/deriv ---
    var bez = CubicBezier[3](
        Vec3(0, 0, 0, 0), Vec3(1, 2, 0, 0), Vec3(2, 2, 0, 0), Vec3(3, 0, 0, 0)
    )
    _near3(s, bez.eval(0.0), Vec3(0, 0, 0, 0), "bezier eval(0) == p0")
    _near3(s, bez.eval(1.0), Vec3(3, 0, 0, 0), "bezier eval(1) == p3")
    for i in range(5):
        var u = Real(i) / 4.0
        var vd = bez.eval_deriv(u)
        _near3(s, vd[0], bez.eval(u), "bezier eval_deriv value == eval")
        _near3(s, vd[1], bez.deriv(u), "bezier eval_deriv deriv == deriv")

    # --- CatmullRom uniform: passes through every control point, C0 at
    # segment joins ---
    var pts5 = List[Vec3]()
    pts5.append(Vec3(0, 0, 0, 0))
    pts5.append(Vec3(1, 1, 0, 0))
    pts5.append(Vec3(2, -1, 0, 0))
    pts5.append(Vec3(3, 2, 0, 0))
    pts5.append(Vec3(4, 0, 0, 0))
    var cr = CatmullRom[3, 0.0](pts5.copy())
    s.eqi(cr.segment_count(), 4, "uniform CR: 5 points -> 4 segments")
    for i in range(5):
        _near3(s, cr.eval(Real(i)), pts5[i], "uniform CR passes through control point " + String(i))
    # C0 continuity: end of segment i == start of segment i+1
    for i in range(3):
        _near3(
            s, cr.eval(Real(i + 1) - 1e-6), cr.eval(Real(i + 1)),
            "uniform CR C0 continuity at joint " + String(i), 1e-3,
        )

    # --- centripetal / chordal: still interpolate the control points ---
    var cr_cent = CatmullRom[3, 0.5](pts5.copy())
    var cr_chord = CatmullRom[3, 1.0](pts5.copy())
    for i in range(5):
        _near3(s, cr_cent.eval(Real(i)), pts5[i], "centripetal CR passes through point " + String(i))
        _near3(s, cr_chord.eval(Real(i)), pts5[i], "chordal CR passes through point " + String(i))

    # --- dimension-generic: dim=2 works too ---
    var pts2 = List[SIMD[WorldType, PadW[2]]]()
    pts2.append(Vec2(0, 0))
    pts2.append(Vec2(1, 1))
    pts2.append(Vec2(2, 0))
    var cr2 = CatmullRom[2, 0.5](pts2^)
    var p2 = cr2.eval(1.0)
    s.almost(Float64(p2[0]), 1.0, "dim=2 CR passes through point 1 .x", 1e-4)
    s.almost(Float64(p2[1]), 1.0, "dim=2 CR passes through point 1 .y", 1e-4)

    # --- BezierPath domain clamp ---
    var path = cr.to_bezier_path()
    _near3(s, path.eval(-5.0), path.eval(0.0), "BezierPath clamps t < 0")
    _near3(
        s, path.eval(100.0), path.eval(path.domain_max()),
        "BezierPath clamps t > domain_max",
    )

    # --- arc-length table: monotonic, endpoints exact ---
    var table = build_arc_length_table[3](path, 64)
    s.check(table.total_length() > 0, "arc-length table: nonzero total length")
    var prev_cum: Real = -1
    var monotonic = True
    for i in range(len(table.cum)):
        if table.cum[i] < prev_cum:
            monotonic = False
        prev_cum = table.cum[i]
    s.check(monotonic, "arc-length table: cumulative length is monotonic")
    s.almost(Float64(table.sample_at_distance(0.0)), Float64(table.ts[0]), "sample_at_distance(0) == ts[0]", 1e-5)
    s.almost(
        Float64(table.sample_at_distance(table.total_length())),
        Float64(table.ts[len(table.ts) - 1]),
        "sample_at_distance(total) == last t", 1e-5,
    )

    # --- closest_point: a point already on the curve maps back near its
    # own parameter ---
    var t_src: Real = 2.3
    var on_curve = path.eval(t_src)
    var t_hit = closest_point[3](path, on_curve)
    _near3(s, path.eval(t_hit), on_curve, "closest_point recovers a point already on the curve", 1e-2)

    # ============================================================ extreme
    # --- 2 control points: valid, single segment, no raise ---
    var pts2c = List[Vec3]()
    pts2c.append(Vec3(0, 0, 0, 0))
    pts2c.append(Vec3(1, 0, 0, 0))
    var cr_min = CatmullRom[3, 0.5](pts2c^)
    s.eqi(cr_min.segment_count(), 1, "2 control points -> 1 segment")
    _near3(s, cr_min.eval(0.0), Vec3(0, 0, 0, 0), "2 points: eval(0) == p0")
    _near3(s, cr_min.eval(1.0), Vec3(1, 0, 0, 0), "2 points: eval(1) == p1")
    s.check(_finite3(cr_min.deriv(0.5)), "2 points: tangent is finite")

    # --- < 2 control points: the public constructor raises ---
    var raised_empty = False
    try:
        var pts0 = List[Vec3]()
        _ = CatmullRom[3, 0.5](pts0^)
    except:
        raised_empty = True
    s.check(raised_empty, "0 control points: constructor raises")

    var raised_one = False
    try:
        var pts1 = List[Vec3]()
        pts1.append(Vec3(0, 0, 0, 0))
        _ = CatmullRom[3, 0.5](pts1^)
    except:
        raised_one = True
    s.check(raised_one, "1 control point: constructor raises")

    # --- coincident points: a zero-length segment must not produce NaN ---
    var pts_coin = List[Vec3]()
    pts_coin.append(Vec3(0, 0, 0, 0))
    pts_coin.append(Vec3(1, 1, 0, 0))
    pts_coin.append(Vec3(1, 1, 0, 0))  # coincides with the previous point
    pts_coin.append(Vec3(2, 0, 0, 0))
    var cr_coin_u = CatmullRom[3, 0.0](pts_coin.copy())
    var cr_coin_c = CatmullRom[3, 0.5](pts_coin.copy())
    var cr_coin_ch = CatmullRom[3, 1.0](pts_coin^)
    for i in range(11):
        var u = Real(i) / 10.0
        var t = 1.0 + u  # the degenerate segment 1->2
        s.check(_finite3(cr_coin_u.eval(t)), "coincident points (uniform): eval finite")
        s.check(_finite3(cr_coin_u.deriv(t)), "coincident points (uniform): tangent finite (no NaN)")
        s.check(_finite3(cr_coin_c.eval(t)), "coincident points (centripetal): eval finite")
        s.check(_finite3(cr_coin_c.deriv(t)), "coincident points (centripetal): tangent finite (no NaN)")
        s.check(_finite3(cr_coin_ch.eval(t)), "coincident points (chordal): eval finite")
        s.check(_finite3(cr_coin_ch.deriv(t)), "coincident points (chordal): tangent finite (no NaN)")
    # the degenerate segment should stay very close to the coincident point
    _near3(s, cr_coin_c.eval(1.5), Vec3(1, 1, 0, 0), "coincident points: mid-segment stays near the collapsed point", 1e-2)

    # --- closed loop: wraps, eval(0) == eval(segment_count) ---
    var pts_loop = List[Vec3]()
    pts_loop.append(Vec3(1, 0, 0, 0))
    pts_loop.append(Vec3(0, 1, 0, 0))
    pts_loop.append(Vec3(-1, 0, 0, 0))
    pts_loop.append(Vec3(0, -1, 0, 0))
    var cr_loop = CatmullRom[3, 0.5](pts_loop^, closed=True)
    s.eqi(cr_loop.segment_count(), 4, "closed loop: 4 points -> 4 segments")
    _near3(s, cr_loop.eval(0.0), cr_loop.eval(4.0), "closed loop: end == start", 1e-3)
    var loop_path = cr_loop.to_bezier_path()
    _near3(
        s, loop_path.eval(3.9999), loop_path.eval(0.0001),
        "closed loop: wraps smoothly across the seam", 5e-2,
    )

    # --- query exactly on the curve ---
    var q_on = path.eval(1.7)
    var t_on = closest_point[3](path, q_on)
    _near3(s, path.eval(t_on), q_on, "closest_point: query exactly on the curve", 1e-2)

    # --- query at infinity: closest_point must return a finite, in-domain t ---
    var inf_q = Vec3(Real(1e30) * Real(1e30), 0, 0, 0)  # actually +inf
    s.check(not _finite3(inf_q), "sanity: the query point itself is +inf")
    var t_inf = closest_point[3](path, inf_q)
    s.check(Bool(isfinite(t_inf).reduce_and()), "closest_point(query at infinity): result parameter is finite")
    s.check(t_inf >= 0.0 and t_inf <= path.domain_max(), "closest_point(query at infinity): result stays in-domain")

    s.finish()
