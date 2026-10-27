"""Experiment — load-dependent contact stiffness (ROADMAP 17.19, opt-in).

A 1 kg box carries a box of M kg on a static floor, both with a per-body soft
contact (`set_contact_softness`, 60 Hz, zeta 1), for 5 s. Overlap is the worst
of the light box's depth below its ideal height and the heavy box's sink onto
it. With `set_load_stiffness(True)` each pair's softness frequency is scaled
by sqrt(M / 1); the soft-contact sag M g / (m_eff w^2) then no longer grows
with the load. Both settings are printed; the flag-off run is the control.
"""

from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 240.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime HZ: Real = 60.0
comptime ZETA: Real = 1.0


def _overlap(ratio: Real, load: Bool) raises -> Real:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 10, 1, 10)), Vec3(10, 1, 10, 0), True)
    var light = sc.add(QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var heavy = sc.add(QuatBody6.at_rest(Vec3(0, 0.75, 0, 0), Inertia3.box(ratio, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    sc.set_contact_softness(light.index(), HZ, ZETA)
    sc.set_contact_softness(heavy.index(), HZ, ZETA)
    sc.set_load_stiffness(load)
    var worst = Real(0)
    for _ in range(1200):
        sc.step_soft(DT, G)
        var yl = sc.bset.bodies[light.index()].position()[1]
        var yh = sc.bset.bodies[heavy.index()].position()[1]
        worst = max(worst, abs(Real(0.25) - yl), abs((yh - yl) - Real(0.5)))
    return worst


def main() raises:
    for ratio in [Real(100), Real(1000), Real(10000)]:
        var off = _overlap(ratio, False)
        var on = _overlap(ratio, True)
        print("  ratio", ratio, "overlap off", off, "on", on)


