# tier: unit
"""Seam parity for `geometry.spline` (docs/CATEGORY.md §2 architecture law
v2): two independently-computed representations of the "same" curve must
agree.

1. Uniform Catmull-Rom (alpha=0) segment P0..P3 IS the cubic Bezier with
   control points `P1, P1 + (P2-P0)/6, P2 - (P3-P1)/6, P2` (the textbook
   closed form). `CatmullRom.segment_bezier` derives its Bezier control
   points from the general (any-alpha) Barry-Goldman construction, NOT from
   this formula -- so comparing the two at many t is a genuine parity check
   between two different code paths, not a self-consistency tautology.
2. Arc-length table (built at a modest sample count) vs. a much denser
   independent polyline sampling of the same curve: the table's total
   length must converge to the dense polyline's length."""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.spline import CubicBezier, CatmullRom, build_arc_length_table


def _near3(mut s: Suite, a: Vec3, b: Vec3, label: String, tol: Float64 = 1e-6):
    s.almost(Float64(a[0]), Float64(b[0]), label + " .x", tol)
    s.almost(Float64(a[1]), Float64(b[1]), label + " .y", tol)
    s.almost(Float64(a[2]), Float64(b[2]), label + " .z", tol)


def main() raises:
    var s = Suite("spline_parity")

    # ---------------------------------------------- CR(uniform) == Bezier
    var trials = List[List[Vec3]]()
    var t0 = List[Vec3]()
    t0.append(Vec3(0, 0, 0, 0))
    t0.append(Vec3(1, 2, 0, 0))
    t0.append(Vec3(3, 2, 0, 0))
    t0.append(Vec3(4, -1, 0, 0))
    trials.append(t0^)
    var t1 = List[Vec3]()
    t1.append(Vec3(-2, 1, 3, 0))
    t1.append(Vec3(0, 0, 0, 0))
    t1.append(Vec3(2, -1, -1, 0))
    t1.append(Vec3(5, 3, 2, 0))
    trials.append(t1^)

    for trial in range(len(trials)):
        var pts = trials[trial].copy()
        var p0 = pts[0]
        var p1 = pts[1]
        var p2 = pts[2]
        var p3 = pts[3]
        # textbook closed-form uniform-CR-as-Bezier control points, computed
        # independently of geometry.spline's general Barry-Goldman path.
        var manual = CubicBezier[3](
            p1, p1 + (p2 - p0) / 6.0, p2 - (p3 - p1) / 6.0, p2
        )
        var cr = CatmullRom[3, 0.0](pts^)
        var seam = cr.segment_bezier(1)  # the P0..P3 segment is segment index 1
        for i in range(21):
            var u = Real(i) / 20.0
            _near3(
                s, seam.eval(u), manual.eval(u),
                "trial " + String(trial) + " CR(uniform)==Bezier eval @u=" + String(Float64(u)),
                1e-6,
            )
            _near3(
                s, seam.deriv(u), manual.deriv(u),
                "trial " + String(trial) + " CR(uniform)==Bezier deriv @u=" + String(Float64(u)),
                1e-5,
            )

    # ---------------------------------------------- arc-length table parity
    var wpts = List[Vec3]()
    wpts.append(Vec3(0, 0, 0, 0))
    wpts.append(Vec3(2, 3, 0, 0))
    wpts.append(Vec3(5, -1, 1, 0))
    wpts.append(Vec3(7, 2, -1, 0))
    wpts.append(Vec3(10, 0, 0, 0))
    var cr_w = CatmullRom[3, 0.5](wpts^)
    var path = cr_w.to_bezier_path()

    var coarse = build_arc_length_table[3](path, 32)
    var dense = build_arc_length_table[3](path, 4000)

    var rel_err = Float64(
        (coarse.total_length() - dense.total_length()) / dense.total_length()
    )
    if rel_err < 0:
        rel_err = -rel_err
    s.check(
        rel_err < 0.01,
        "arc-length table (N=32) vs dense polyline (N=4000): relative error < 1% (got "
        + String(rel_err) + ")",
    )

    s.finish()
