# tier: component
"""Strand twist (ROADMAP 17.86 item 1, `StrandSet.twist` / `torsion` /
`set_root_twist`). Twist acts only through the curled rest target (a straight
strand has no positional effect), so the tests use a curled strand.

Predictions, written before the run:

  1. Exact, one kink: 3 particles, segment 1 along +x, segment 2 at angle a
     about z (a = 0.5 rad, l = 0.02 m), bend 1, no gravity or drag, twist
     phi = 0.7 on the joint at particle 2. Segment 2's target turns about the
     x-axis (segment 1's direction) by phi, so after one step the tip is
     x1 + l (cos a, sin a cos phi, sin a sin phi). Tolerance first written as 1e-9 m; the first run failed with max error 3.7e-9 m (f32 Real), so the tolerance was changed to 1e-7 m after that run (see Measured).
  2. Without twist the same strand gives the planar tip (exact, same tol.).
  3. Relaxation, stiff torsion (torsion * dt >= 1): one step sets every joint's
     twist to the root twist exactly (the relaxation is then a copy).
  4. Relaxation off (torsion 0): joints keep twist 0 after 1 s.
  5. Integration: 12-particle curl (0.4 rad per segment about z, bend 0.5,
     zero gravity). With root twist 0.7 and stiff torsion the curl's plane
     tilts out of xy: |z_tip| > 1 mm after 3 s. With torsion off it stays in
     plane: |z_tip| < 1e-6 m.

Measured: first run: 5 of 6 pass; check 1 max error 3.7e-9 m against the 1e-9 bound (f32 rounding at 0.04 m). Tolerance changed to 1e-7 m; rerun in the roadmap note.
"""

from std.math import cos, sin
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.rigid6 import Pose6
from physics.strand import StrandSet

comptime DT: Real = 1.0 / 120.0
comptime ZERO = Vec3(0, 0, 0, 0)
comptime G0 = Vec3(0, 0, 0, 0)
comptime G = Vec3(0, -9.8, 0, 0)
comptime L: Real = 0.02
comptime A: Real = 0.5
comptime PHI: Real = 0.7


def bone() -> List[Pose6]:
    return [Pose6(ZERO, Quat.identity())]


def kink() raises -> StrandSet:
    var s = StrandSet(1.0, 0.0, 0.9, 0.0, 0.0)
    _ = s.add_curl(0, bone()[0], ZERO, Vec3(1, 0, 0, 0), Vec3(0, 0, 1, 0), A, 3, L)
    return s^


def curl(torsion: Real) raises -> StrandSet:
    var s = StrandSet(0.5, 0.5, 0.9, 0.002, 20.0, torsion)
    _ = s.add_curl(0, bone()[0], ZERO, Vec3(0, -1, 0, 0), Vec3(0, 0, 1, 0), 0.4, 12, 0.02)
    return s^


def close(a: Vec3, b: Vec3, tol: Real) -> Bool:
    return length(a - b) < tol


def main() raises:
    var st = Suite("strand_torsion")

    # 1. one kink, twist on joint 2
    var a = kink()
    a.twist[2] = PHI
    a.step(DT, G0, bone())
    var want = Vec3(L + L * cos(A), L * sin(A) * cos(PHI), L * sin(A) * sin(PHI), 0)
    st.check(close(a.x[2], want, 1e-7), "one kink, twist 0.7: tip = x1 + l R_x(phi)(cos a, sin a, 0)")

    # 2. no twist: planar
    var b = kink()
    b.step(DT, G0, bone())
    var planar = Vec3(L + L * cos(A), L * sin(A), 0, 0)
    st.check(close(b.x[2], planar, 1e-7), "one kink, twist 0: tip stays in the xy-plane")

    # 3. stiff torsion copies the root twist to every joint in one step
    var c = curl(1e6)
    c.set_root_twist(0, PHI)
    c.step(DT, G0, bone())
    var all_set = True
    for k in range(1, 12):
        all_set = all_set and c.twist[k] == PHI
    st.check(all_set, "torsion stiff: one step sets every joint's twist to the root twist")

    # 4. torsion off: joints keep 0 for 1 s
    var d = curl(0)
    d.set_root_twist(0, PHI)
    for _ in range(120):
        d.step(DT, G0, bone())
    var kept = True
    for k in range(1, 12):
        kept = kept and d.twist[k] == 0
    st.check(kept, "torsion off: joints keep twist 0 after 1 s")

    # 5. integration: the curl's plane tilts only with twist
    var e = curl(1e6)
    e.set_root_twist(0, PHI)
    var f = curl(0)
    for _ in range(360):
        e.step(DT, G0, bone())
        f.step(DT, G0, bone())
    var ze = abs(e.tip(0)[2])
    var zf = abs(f.tip(0)[2])
    print("  curl tip |z| with twist", ze, "  without", zf)
    st.check(ze > 1e-3, "curl with root twist 0.7 and stiff torsion leaves the xy-plane (|z| > 1 mm)")
    st.check(zf < 1e-6, "curl without twist stays in the xy-plane (|z| < 1e-6)")
    st.finish()
