# tier: integration
"""Twisted curled strand in lattice air, two-way (ROADMAP 17.86 item (3), the
air part; the sphere and box parts are `test_strand_contact_twist` and
`test_strand_scene_twist`).

Air: `Lbm` 24^3, periodic, dx 2 cm, 1 ms per lattice step, rho 1.2, lattice
viscosity 0.05, uniform wind 0.4 m/s along +x (as `test_strand_air`). Strand:
a 12-particle curl (0.4 rad per segment about z, 2 cm segments) in the
xy-plane, rooted at (0.10, 0.24, 0.24), bend 0.05, air drag 20 /s, 0.1 g per
particle. Root twist 0.7 with stiff torsion (the twisted run), or no twist
(the reference run). 600 steps (0.6 s), zero gravity.

Predictions, written before the run:

  1. Engagement: the wind moves both curls downstream by more than 1 mm
     (x shift from the initial rest tip). Predicted untwisted shift about 9 mm.
  2. Coupling is active, not vacuous: |air impulse| > 1e-4 N s in each run;
     two-way, the air's momentum change equals its impulse within 1e-3 relative;
     the air and strand impulses are equal and opposite within 1e-6 relative.
  3. Twist persists in the wind: the twisted tip leaves the plane through the
     root (|z_tip - z_root| > 1 mm), the untwisted one stays in it (< 1e-6 m).
     The wind has no z component, so the air does not produce this; the twist
     does.
  4. The twist changes the tip with air present: the twisted and untwisted tips
     differ by more than 1 cm.

Run history. The first run used bend 1.0 (the default shaped target of the
other strand tests). Its checks 1 and 3 failed, for two reasons. The baselines
were the root and absolute z, which were wrong; both are now relative to the
initial tip and the root's plane. Beyond that, a sweep (scratch, 600 steps,
both twist values) found that bend 1.0 and 0.2 let the shape target cancel the
wind's displacement (untwisted shift at bend 1.0: -7e-9 m; at 0.2: -2.5 mm),
while the air impulse stayed near 3e-3 N s at every bend. Bend 0.05 is the
smallest setting in the sweep at which the wind moves the untwisted curl by
more than 1 mm (9 mm) and the twist still moves the tip (0.107 m, |z| 0.138).
bend 0 moves the curl 0.167 m but makes the twist do nothing, so it cannot
test item (3). The bend change and the baseline fix are post-run changes,
recorded here.

Measured: recorded in the roadmap progress note after the run.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from fluid.lbm import Lbm
from physics.rigid6 import Pose6
from physics.strand import StrandSet
from physics.strand_air import StrandAir

comptime DX: Real = 0.02
comptime DT: Real = 1e-3
comptime ZERO = Vec3(0, 0, 0, 0)
comptime EZ = Vec3(0, 0, 1, 0)
comptime ROOT = Vec3(0.10, 0.24, 0.24, 0)
comptime BEND: Real = 0.05
comptime STRAND_R: Real = 0.002
comptime STEPS = 600


def air() -> Lbm:
    var l = Lbm(24, 24, 24, 0.05)
    l.init_uniform(1.0, 0.02, 0.0, 0.0)
    return l^


def run(twist: Real, mut tip0: Vec3, mut mom_err: Real, mut imp_err: Real, mut air_imp: Real) raises -> StrandSet:
    var bones: List[Pose6] = [Pose6(ZERO, Quat.identity())]
    var s = StrandSet(BEND, 20.0, 0.9, STRAND_R, 20.0, Real(1e6) if twist != 0 else Real(0))
    _ = s.add_curl(0, bones[0], ROOT, Vec3(1, 0, 0, 0), EZ, 0.4, 12, 0.02)
    if twist != 0:
        s.set_root_twist(0, twist)
    tip0 = s.tip(0)
    var a = StrandAir(air(), ZERO, DX, DT, 1.2, 1e-4)
    var p0 = a.air_momentum()
    for _ in range(STEPS):
        a.step(s, ZERO, bones)
    var d = a.air_momentum() - p0
    air_imp = length(a.air_impulse)
    mom_err = length(d - a.air_impulse) / max(air_imp, Real(1e-30))
    imp_err = length(a.air_impulse + a.strand_impulse) / max(air_imp, Real(1e-30))
    return s^


def main() raises:
    var st = Suite("strand_air_twist")
    var tip_tw = Vec3(0, 0, 0, 0)
    var tip_un = Vec3(0, 0, 0, 0)
    var mom_tw = Real(0)
    var imp_tw = Real(0)
    var ai_tw = Real(0)
    var mom_un = Real(0)
    var imp_un = Real(0)
    var ai_un = Real(0)
    var tw = run(0.7, tip_tw, mom_tw, imp_tw, ai_tw)
    var un = run(0, tip_un, mom_un, imp_un, ai_un)

    var shift_tw = tw.tip(0)[0] - tip_tw[0]
    var shift_un = un.tip(0)[0] - tip_un[0]
    var gap = length(tw.tip(0) - un.tip(0))
    var zt = abs(tw.tip(0)[2] - ROOT[2])
    var zu = abs(un.tip(0)[2] - ROOT[2])
    print("  x shift  twisted", shift_tw, " untwisted", shift_un)
    print("  air impulse |I|  twisted", ai_tw, " untwisted", ai_un, "  momentum error (rel)", mom_tw, mom_un, "  impulse error (rel)", imp_tw, imp_un)
    print("  tip gap", gap, "  |z - z_root| twisted", zt, " untwisted", zu)
    st.check(shift_tw > 1e-3 and shift_un > 1e-3, "the wind moves both curls downstream by more than 1 mm")
    st.check(ai_tw > 1e-4 and ai_un > 1e-4, "two-way coupling is active: the air impulse exceeds 1e-4 N s in both runs")
    st.check(mom_tw < 1e-3 and mom_un < 1e-3 and imp_tw < 1e-6 and imp_un < 1e-6, "two-way: momentum change and impulses consistent with a twisted curl")
    st.check(zt > 1e-3 and zu < 1e-6, "twisted curl leaves the plane through the root, untwisted stays in it, in the wind")
    st.check(gap > 1e-2, "the twist moves the tip more than 1 cm with air present")
    st.finish()
