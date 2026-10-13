"""ROADMAP 17.44: one compound body vs N welded bodies.

A straight bar made of N cubes (half 0.1, so the bar is 0.2 N long) rests
on a floor, built two ways: one `add_compound` body with N box children,
and N box bodies joined by N - 1 `JOINT_WELD`s (the 17.5 route). 120 steps
are timed after 60 settling steps; "drift" is how far the bar's two end
cubes move apart over those steps (0 for a compound by construction, the
weld residual otherwise), and "speed" the largest body speed at the end.
"""

from std.time import perf_counter_ns
from std.math import sqrt
from geometry.vec import Real, Vec3, dot
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.joints6 import Joint6
from physics.solver6 import ContactScene6
from collision.collider_set import CompoundSpec

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _floor(mut sc: ContactScene6[QuatBody6]):
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 40, 0.5, 40)), Vec3(40, 0.5, 40, 0), True)


def _x(k: Int, n: Int) -> Real:
    return Real(k) * 0.2 - Real(n - 1) * 0.1


def main() raises:
    print("### Compound vs welded bodies (17.44): a bar of N cubes on a floor\n")
    print("| N | build | step us | end-to-end drift (m) | max speed (m/s) |")
    print("|---:|---|---:|---:|---:|")
    for n in [2, 4, 16, 64]:
        var cs = ContactScene6[QuatBody6]()
        _floor(cs)
        var spec = CompoundSpec()
        for k in range(n):
            spec.box(Vec3(0.1, 0.1, 0.1, 0), Vec3(_x(k, n), 0, 0, 0))
        var ci = cs.add_compound(QuatBody6.at_rest(Vec3(0, 0.1, 0, 0), Inertia3.box(1, 1, 1, 1)), spec, 1000, False)
        cs.set_can_sleep(ci, False)
        for _ in range(60):
            cs.step_soft(DT, G)
        var t0 = Int(perf_counter_ns())
        for _ in range(120):
            cs.step_soft(DT, G)
        var t1 = Int(perf_counter_ns())
        var cv = cs.velocity(ci)
        print("|", n, "| compound |", (t1 - t0) // 120000, "|", 0.0, "|", sqrt(dot(cv, cv)), "|")

        var ws = ContactScene6[QuatBody6]()
        _floor(ws)
        var m = Real(1000 * 0.008)
        for k in range(n):
            var id = ws.add(QuatBody6.at_rest(Vec3(_x(k, n), 0.1, 0, 0), Inertia3.box(m, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
            ws.set_can_sleep(id, False)
        for k in range(n - 1):
            _ = ws.add_joint(Joint6.weld(1 + k, 2 + k, Vec3(0.1, 0, 0, 0), Vec3(-0.1, 0, 0, 0), Quat.identity()))
        for _ in range(60):
            ws.step_soft(DT, G)
        var e0 = ws.bset.bodies[n].pos - ws.bset.bodies[1].pos
        var t2 = Int(perf_counter_ns())
        for _ in range(120):
            ws.step_soft(DT, G)
        var t3 = Int(perf_counter_ns())
        var e1 = ws.bset.bodies[n].pos - ws.bset.bodies[1].pos
        var dd = e1 - e0
        var vmax = Real(0)
        for k in range(1, n + 1):
            var v = ws.bset.bodies[k].vel
            vmax = max(vmax, sqrt(dot(v, v)))
        print("|", n, "| welded |", (t3 - t2) // 120000, "|", sqrt(dot(dd, dd)), "|", vmax, "|")
    print("")
