# tier: component
"""Strand twist against the Cosserat rod (ROADMAP 17.86 item (1), parity).

The two models do not share a twist quantity. `CosseratRod.twist_angle` is a
Darboux component; `StrandSet.twist` is a rest-target rotation. The comparison
is therefore on equilibrium tip positions for one twisted boundary condition.

Predictions, written before the run:

  1. One kink, rod: 3 points, segment 1 along +x, segment 2 at a = 0.5 rad
     (l = 0.02 m). Segment 0 is clamped (fix_point 0, 1; fix_segment 0) and
     turned by phi = 0.7 about its own d3 (right-multiplied by R_z(phi)). The
     joint's twist-free rest darboux then gives q1 = R_x(phi) q1_rest, so the
     free tip is x1 + l (cos a, sin a cos phi, sin a sin phi). Prediction: the
     settled tip is within 1e-5 m of that analytic tip, and within 1e-5 m of
     the StrandSet one-kink tip (same analytic formula).
  2. Twisted 12-point curl, rod: segment 0 turned by phi about its d3, the
     rest shape otherwise unchanged. Every joint's twist-free rest darboux
     carries the rest shape rigidly, so the settled tip is the rest tip
     rotated by R_{d0}(phi) about the root. Prediction: within 2e-3 m.
  3. Same curl in StrandSet with stiff torsion and root twist phi: each joint
     gets its own bend-plane rotation (cumulative), so the tip is NOT the
     rigid rotation. Prediction: its distance from the rigid tip exceeds 1 cm.
     This is a predicted non-equivalence for chains, not a failure.

Measured: recorded in the roadmap progress note after the run.
"""

from std.math import cos, sin
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.rigid6 import Pose6
from physics.strand import StrandSet
from physics.cosserat_rod import CosseratRod

comptime DT: Real = 1.0 / 120.0
comptime ZERO = Vec3(0, 0, 0, 0)
comptime L: Real = 0.02
comptime A: Real = 0.5
comptime PHI: Real = 0.7
comptime CURL: Real = 0.4
comptime EZ_Z = Vec3(0, 0, 1, 0)


def curl_points(n: Int) -> List[Vec3]:
    """Rest points of the planar curl: segment k (k >= 1, 0-based) turned by
    k * CURL about +z from +x, the same rest shape as `StrandSet.add_curl`."""
    var pts = List[Vec3]()
    pts.append(ZERO)
    var p = ZERO
    var ang = Real(0)
    for _ in range(n - 1):
        var d = Vec3(cos(ang), sin(ang), 0, 0)
        p = p + d * L
        pts.append(p)
        ang = ang + CURL
    return pts^


def rod_of(points: List[Vec3]) raises -> CosseratRod:
    var r = CosseratRod(points, Real(1), 0, 0)
    r.damping = 0.9
    return r^


def settle(mut r: CosseratRod, seconds: Real):
    for _ in range(Int(seconds / DT)):
        r.step(DT, ZERO)


def main() raises:
    var st = Suite("rod_strand_twist")

    # 1. one kink: rod vs analytic vs StrandSet
    var pts = List[Vec3]()
    pts.append(ZERO)
    pts.append(Vec3(L, 0, 0, 0))
    pts.append(Vec3(L + L * cos(A), L * sin(A), 0, 0))
    var r1 = rod_of(pts)
    var q0 = r1.q[0]
    r1.set_segment(0, q0 * Quat.from_axis_angle(EZ_Z, PHI))
    r1.fix_point(0)
    r1.fix_point(1)
    r1.fix_segment(0)
    settle(r1, 2.0)
    var analytic = Vec3(L + L * cos(A), L * sin(A) * cos(PHI), L * sin(A) * sin(PHI), 0)
    var d_rod = length(r1.x[2] - analytic)

    var ss = StrandSet(1.0, 0.0, 0.9, 0.0, 0.0)
    var bone = List[Pose6]()
    bone.append(Pose6(ZERO, Quat.identity()))
    _ = ss.add_curl(0, bone[0], ZERO, Vec3(1, 0, 0, 0), EZ_Z, A, 3, L)
    ss.twist[2] = PHI
    ss.step(DT, ZERO, bone)
    var d_ss = length(ss.x[2] - analytic)
    print("  one kink: rod tip - analytic", d_rod, "  StrandSet tip - analytic", d_ss)
    st.check(d_rod < 1e-5, "rod one kink, segment 0 turned by phi: tip within 1e-5 m of the analytic tip")

    # 2. twisted 12-point curl: rod tip = rigid rotation of the rest tip
    var n = 12
    var rest = curl_points(n)
    var rod = rod_of(rest)
    var q0c = rod.q[0]
    rod.set_segment(0, q0c * Quat.from_axis_angle(EZ_Z, PHI))
    rod.fix_point(0)
    rod.fix_point(1)
    rod.fix_segment(0)
    settle(rod, 2.0)
    var d0 = q0c.rotate(EZ_Z)
    var rigid = Quat.from_axis_angle(d0, PHI).rotate(rest[n - 1])
    var d_rigid = length(rod.x[n - 1] - rigid)
    print("  curl: rod tip - rigid rotation", d_rigid)
    st.check(d_rigid < 2e-3, "rod 12-point curl, segment 0 turned by phi: tip = rigid rotation of rest tip (< 2 mm)")

    # 3. StrandSet curl with the same twist on every joint: not rigid
    var sc = StrandSet(1.0, 0.0, 0.9, 0.002, 20.0, 1e6)
    _ = sc.add_curl(0, bone[0], ZERO, Vec3(1, 0, 0, 0), EZ_Z, CURL, n, L)
    sc.set_root_twist(0, PHI)
    for _ in range(240):
        sc.step(DT, ZERO, bone)
    var d_ss_rigid = length(sc.x[n - 1] - rigid)
    print("  curl: StrandSet tip - rigid rotation", d_ss_rigid)
    st.check(d_ss_rigid > 1e-2, "StrandSet curl with twist on every joint differs from the rigid rotation (> 1 cm)")
    st.finish()
