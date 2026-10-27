# tier: component
"""Twisted curled strand against a sphere collider (ROADMAP 17.86 item (3),
the contact part; the air part is `StrandAir` (17.61), which acts on particle
positions and velocities and so already sees a twisted shape).

A 12-particle curl (0.4 rad per segment about z, 2 cm segments) lies in the
xy-plane from the origin. A sphere (radius 3 cm, centre (0.05, 0.02, 0)) sits
across its path. Root twist 0.7 with stiff torsion (the twisted run), or no
twist (the reference run). Zero gravity, 240 steps (2 s).

Predictions, written before the run:

  1. Contact holds for both runs: every particle ends at least
     (sphere radius + strand radius) from the centre, up to 1e-6 m. The push
     is applied to every predicted position, so this holds by construction.
  2. The twist changes where the strand goes: the twisted tip differs from the
     untwisted tip by more than 1 cm.
  3. The twisted strand leaves the xy-plane (|z_tip| > 1 mm) while the
     untwisted one stays in it (|z_tip| < 1e-6 m), even with the sphere.

Run history: the first run put the sphere at (0.12, 0.05, 0). The curl never
reached it (clearance 0.0375 m against 0.032 m), so the contact check passed
without the push ever acting. The sphere was moved to (0.05, 0.02, 0) and a
check that contact engages (a particle on the surface in one run) was added.
Measured on the moved sphere: clearance 0.0 in both runs (contact active),
tip gap 0.20 m, |z_tip| 0.137 m twisted, 0 untwisted.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.rigid6 import Pose6
from physics.strand import StrandSet, StrandSphere

comptime DT: Real = 1.0 / 120.0
comptime ZERO = Vec3(0, 0, 0, 0)
comptime EZ = Vec3(0, 0, 1, 0)
comptime SPHERE_C = Vec3(0.05, 0.02, 0, 0)
comptime SPHERE_R: Real = 0.03
comptime STRAND_R: Real = 0.002


def curl(twist: Real) raises -> StrandSet:
    var bone = List[Pose6]()
    bone.append(Pose6(ZERO, Quat.identity()))
    var s = StrandSet(1.0, 0.0, 0.9, STRAND_R, 20.0, Real(1e6) if twist != 0 else Real(0))
    _ = s.add_curl(0, bone[0], ZERO, Vec3(1, 0, 0, 0), EZ, 0.4, 12, 0.02)
    s.spheres.append(StrandSphere(SPHERE_C, SPHERE_R))
    if twist != 0:
        s.set_root_twist(0, twist)
    return s^


def run(twist: Real) raises -> StrandSet:
    var bone = List[Pose6]()
    bone.append(Pose6(ZERO, Quat.identity()))
    var s = curl(twist)
    for _ in range(240):
        s.step(DT, ZERO, bone)
    return s^


def main() raises:
    var st = Suite("strand_contact_twist")
    var tw = run(0.7)
    var un = run(0)

    var worst = Real(1e9)
    for i in range(12):
        var d = length(tw.x[i] - SPHERE_C)
        worst = min(worst, d - (SPHERE_R + STRAND_R))
    var worst_un = Real(1e9)
    for i in range(12):
        var d = length(un.x[i] - SPHERE_C)
        worst_un = min(worst_un, d - (SPHERE_R + STRAND_R))
    var gap = length(tw.tip(0) - un.tip(0))
    var zt = abs(tw.tip(0)[2])
    var zu = abs(un.tip(0)[2])
    print("  worst clearance twisted", worst, " untwisted", worst_un, "  tip gap", gap, "  |z| twisted", zt, " untwisted", zu)
    st.check(worst > -1e-6 and worst_un > -1e-6, "contact holds: every particle outside the sphere (both runs)")
    st.check(min(worst, worst_un) < 1e-3, "contact engages: a particle sits on the sphere surface in at least one run")
    st.check(gap > 1e-2, "twist moves the tip more than 1 cm past the sphere")
    st.check(zt > 1e-3 and zu < 1e-6, "twisted strand leaves the xy-plane, untwisted stays in it, with the sphere present")
    st.finish()
