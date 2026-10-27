# tier: integration
"""Twisted curled strand against a rigid scene box, through `strands_collide`
(ROADMAP 17.86 item (3), the rigid-scene part; the sphere part is
`test_strand_contact_twist`).

The same 12-particle curl as `test_strand_contact_twist` (0.4 rad per segment
about z, 2 cm segments, in the xy-plane from the origin). A static box with
half extents (0.03, 0.03, 0.1) sits at (0.05, 0.02, 0), so the curl runs into
its side. Root twist 0.7 with stiff torsion (the twisted run), or no twist (the
reference run). Zero gravity, 240 steps (2 s). Each step is `StrandSet.step`
followed by `strands_collide(..., mu = 0.3)`.

Predictions, written before the run:

  1. Engagement: `strands_collide` reports at least one contact in both runs.
     Checked first, because a run with no contact passes the containment check
     vacuously (the sphere run's first attempt showed this).
  2. Containment: after the last push, no particle centre lies inside the box
     (signed box distance > -1e-6 m in the worst axis).
  3. The twist changes where the strand goes: the twisted tip differs from the
     untwisted tip by more than 1 cm.
  4. The twisted strand leaves the xy-plane (|z_tip| > 1 mm); the untwisted one
     stays in it (|z_tip| < 1e-6 m).

Measured: recorded in the roadmap progress note after the run.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.rigid6 import Pose6, QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.strand import StrandSet
from physics.strand_ext import strands_collide

comptime DT: Real = 1.0 / 120.0
comptime ZERO = Vec3(0, 0, 0, 0)
comptime EZ = Vec3(0, 0, 1, 0)
comptime BOX_C = Vec3(0.05, 0.02, 0, 0)
comptime BOX_H = Vec3(0.03, 0.03, 0.1, 0)
comptime STRAND_R: Real = 0.002


def inside_box(x: Vec3) -> Bool:
    # signed distance, worst axis: negative inside, positive outside
    var worst = Real(-1e9)
    for a in range(3):
        var d = abs(x[a] - BOX_C[a]) - BOX_H[a]
        worst = max(worst, d)
    return worst < -1e-6


def run(twist: Real, mut hits: Int, mut inside: Int) raises -> StrandSet:
    var bone = List[Pose6]()
    bone.append(Pose6(ZERO, Quat.identity()))
    var s = StrandSet(1.0, 0.0, 0.9, STRAND_R, 20.0, Real(1e6) if twist != 0 else Real(0))
    _ = s.add_curl(0, bone[0], ZERO, Vec3(1, 0, 0, 0), EZ, 0.4, 12, 0.02)
    if twist != 0:
        s.set_root_twist(0, twist)
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(BOX_C, Inertia3.box(1, BOX_H[0], BOX_H[1], BOX_H[2])), BOX_H, True)
    for _ in range(240):
        s.step(DT, ZERO, bone)
        hits += strands_collide(s, sc, DT, 0.3)
    for i in range(12):
        if inside_box(s.x[i]):
            inside += 1
    return s^


def main() raises:
    var st = Suite("strand_scene_twist")
    var hits_tw = 0
    var hits_un = 0
    var inside = 0
    var tw = run(0.7, hits_tw, inside)
    var un = run(0, hits_un, inside)
    var gap = length(tw.tip(0) - un.tip(0))
    var zt = abs(tw.tip(0)[2])
    var zu = abs(un.tip(0)[2])
    print("  contacts twisted", hits_tw, " untwisted", hits_un, "  particles inside box", inside)
    print("  tip gap", gap, "  |z| twisted", zt, " untwisted", zu)
    st.check(hits_tw > 0 and hits_un > 0, "contact engages in both runs (strands_collide reports hits)")
    st.check(inside == 0, "no particle centre inside the box in either run")
    st.check(gap > 1e-2, "twist moves the tip more than 1 cm past the box")
    st.check(zt > 1e-3 and zu < 1e-6, "twisted strand leaves the xy-plane, untwisted stays in it, with the box present")
    st.finish()
