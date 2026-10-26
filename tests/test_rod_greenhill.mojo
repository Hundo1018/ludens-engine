# tier: component
"""Length scaling of the twist-buckling onset of a `CosseratRod`
(ROADMAP 17.86, `physics.cosserat_rod`). Companion to `test_rod_plectoneme`.

That test measured the onset in omega_c (rad/m) on a 1 m rod. The classical
torsional buckling result is dimensionally a total-twist threshold: with
pinned ends (Greenhill), M_c = 2 pi B / L, so the total twist phi_c = omega_c L
= 2 pi B / C does not depend on L. The Kirchhoff form quoted in that test's
header, C omega_c = 2 B, is missing this 1/L factor.

Setup is the same as `test_rod_plectoneme`: straight rod, orientations of both
end segments held, total twist phi on the last segment, 1e-3 m kink at the
middle, 40 iterations. The segment length is fixed at 0.05 m, so the
2 m rod has 41 points and the 1 m rod has 21. Bend compliance 1, twist
compliance 0.1 (B / C = 0.1 in the discrete model).

Prediction, written before the run:

  * 1 m rod: phi_c = 2 pi * 0.1 = 0.628. Measured earlier in the same
    setup (omega_c, same as phi_c at L = 1): 0.659, +4.9 %. Tolerance 10 %.
  * 2 m rod: phi_c equals the 1 m value within 10 %. If it instead doubles,
    the 1/L factor is absent and the 2 pi constant is not the answer.

The end boundary condition here (positions free, orientations held) is not
Greenhill's pinned condition, so the coefficient 2 pi is a prediction, not a
derived value. Checked: the length scaling, and the 1 m coefficient within
10 %.

Duration: the first version ran 1500 steps (25 s). It failed the length check:
2 m onset 0.791, 1 m 0.659, ratio 1.20. A probe with the same bisection then
showed the 2 m onset is not converged at 1500 steps (3000 steps: 0.703; 6000
steps: 0.703), while the 1 m onset is already converged at 1500 steps (0.659 at
both). A longer rod grows its instability more slowly, so the shorter window
biased the 2 m onset upward. The window was lengthened to 3000 steps (50 s).
The prediction and tolerances above were not changed. The converged ratio is
0.703 / 0.659 = 1.07, within 10 %.

Bisection: 6 evaluations on [0.2, 3] rad, so the onset resolution is about
0.044 rad. The tolerance above is wider than that.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.cosserat_rod import CosseratRod


def straight(n: Int, L: Real) -> List[Vec3]:
    var pts = List[Vec3]()
    for i in range(n):
        pts.append(Vec3(0, 0, Real(i) * L / Real(n - 1), 0))
    return pts^


def deviation(n: Int, L: Real, phi: Real, bend: Real, twist: Real) raises -> Real:
    """Max distance of interior points from the end chord after 50 s."""
    var r = CosseratRod(straight(n, L), 0.1, bend, twist)
    r.damping = 0.98
    r.iters = 40
    var ns = r.segments()
    r.fix_segment(0)
    r.fix_segment(ns - 1)
    var q0 = r.q[ns - 1]
    r.set_segment(ns - 1, Quat.from_axis_angle(Vec3(0, 0, 1, 0), phi) * q0)
    r.x[n // 2] = r.x[n // 2] + Vec3(1e-3, 0, 0, 0)
    var zero = Vec3(0, 0, 0, 0)
    for _ in range(3000):
        r.step(1.0 / 60.0, zero)
    var a = r.x[0]
    var d = r.x[n - 1] - a
    var l2 = d[0] * d[0] + d[1] * d[1] + d[2] * d[2]
    var dev = Real(0)
    for i in range(1, n - 1):
        var p = r.x[i] - a
        var t = (p[0] * d[0] + p[1] * d[1] + p[2] * d[2]) / l2
        var q = p - d * t
        dev = max(dev, (q[0] * q[0] + q[1] * q[1] + q[2] * q[2]) ** 0.5)
    return dev


def onset(n: Int, L: Real, bend: Real, twist: Real) raises -> Real:
    """Total twist at which the rod starts to writhe (bisection, 6 steps)."""
    var lo = Real(0.2)
    var hi = Real(3.0)
    for _ in range(6):
        var mid = (lo + hi) / 2
        if deviation(n, L, mid, bend, twist) > 0.01:
            hi = mid
        else:
            lo = mid
    return (lo + hi) / 2


def main() raises:
    var s = Suite("rod_greenhill")
    var pred = Real(2) * Real(3.14159265358979) * Real(0.1)
    var p1 = onset(21, Real(1), Real(1), Real(0.1))
    var p2 = onset(41, Real(2), Real(1), Real(0.1))
    print("  total twist onset: 1 m", p1, "  2 m", p2, "  ratio 2 m / 1 m", p2 / p1, "  2 pi B/C", pred)
    s.check(abs(p1 / pred - 1) < 0.10, "1 m onset within 10 % of 2 pi B / C")
    s.check(abs(p2 / p1 - 1) < 0.10, "total-twist onset does not depend on rod length (within 10 %)")
    s.finish()
