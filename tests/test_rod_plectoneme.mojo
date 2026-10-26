# tier: component
"""Twist-driven buckling of a `CosseratRod` (ROADMAP 17.86,
`physics.cosserat_rod`).

Setup: 21 points on a 1 m straight rod (20 joints), no gravity, no ends
clamped in position. Both end segments have their orientation held: the
first is fixed, the last is turned about the rod axis by the total twist
phi. The rod is seeded with a 1e-3 m lateral kink at its middle.

Measured quantity: max distance of interior points from the chord through
the two end points after 25 s (1500 steps of 1/60 s, 40 solver iterations).
Above the onset the rod writhes (deviation of order 0.1 m); below it the seed
decays (deviation of order 1e-8).

Onset is bisected in phi on [0.2, 3] rad (6 evaluations). The rod cannot
carry a total twist beyond +-pi: each joint keeps its shortest-path twist,
so the search window stays below pi.

Two claims, and what each is worth:

  * Scaling (checked): the zero-tension Kirchhoff threshold is linear in the
    ratio C / B = (twist compliance) / (bend compliance) in the discrete model
    (energy per joint ~ 1 / compliance, same factor for bend and twist). With
    the bend compliance fixed at 1, doubling the twist compliance from 0.1 to
    0.2 must double the onset; tolerance 15 %, written before the final run.
  * Constant (NOT checked): the Kirchhoff zero-tension threshold is usually
    quoted as C * omega_c = 2 * B. Here that gives omega_c = 0.2 rad/m for
    the 0.1 ratio, but the measured onset is ~0.66 rad/m (about 3.3 times
    larger). The end boundary condition of this test (positions free,
    orientations held) and the discrete calibration B = l / (4 * bend),
    C = l / (4 * twist) are both unverified against the literature. The
    onset value is printed, not asserted.

Cost: 12 bisection runs of 1500 steps each (40 iterations), about 12 s.
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


def deviation(phi: Real, bend: Real, twist: Real) raises -> Real:
    var n = 21
    var r = CosseratRod(straight(n, 1.0), 0.1, bend, twist)
    r.damping = 0.98
    r.iters = 40
    var ns = r.segments()
    r.fix_segment(0)
    r.fix_segment(ns - 1)
    var q0 = r.q[ns - 1]
    r.set_segment(ns - 1, Quat.from_axis_angle(Vec3(0, 0, 1, 0), phi) * q0)
    r.x[n // 2] = r.x[n // 2] + Vec3(1e-3, 0, 0, 0)
    var zero = Vec3(0, 0, 0, 0)
    for _ in range(1500):
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


def onset(bend: Real, twist: Real) raises -> Real:
    var lo = Real(0.2)
    var hi = Real(3.0)
    for _ in range(6):
        var mid = (lo + hi) / 2
        if deviation(mid, bend, twist) > 0.01:
            hi = mid
        else:
            lo = mid
    return (lo + hi) / 2


def main() raises:
    var s = Suite("rod_plectoneme")
    var w1 = onset(Real(1), Real(0.1))
    var w2 = onset(Real(1), Real(0.2))
    print("  onset omega_c (rad/m): twist compliance 0.1:", w1, "  0.2:", w2, "  ratio", w2 / w1)
    print("  Kirchhoff 2B/C for 0.1 ratio: 0.2 rad/m (not reproduced; see header)")
    s.check(abs(w2 / w1 - 2) < 0.3, "onset scales linearly with C/B (ratio 2 within 15 %)")
    s.check(deviation(Real(0.5) * w1, Real(1), Real(0.1)) < 0.01, "below onset the straight rod stays straight")
    s.check(deviation(Real(1.5) * w1, Real(1), Real(0.1)) > 0.05, "above onset the rod writhes (deviation > 5 cm)")
    s.finish()
