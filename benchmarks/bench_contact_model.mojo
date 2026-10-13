"""ROADMAP 17.50: per-step cost of the contact model variants.

N cubes (half 0.25) sliding on a 30 degree slope (a flat floor under tilted
gravity, mu 0.3, downhill along the floor diagonal) and N balls (radius
0.25) rolling at 2 m/s, 60 steps timed after 20 settling steps. Variants:
the default pyramid cone, the elliptic cone, and the elliptic cone with
static friction 0.5 and rolling / spin resistance 0.01 m on every body
(which also turns on the contact-model branch of the solve). "slide" is the
mean distance a cube moved, which shows the pyramid's larger diagonal cap.
"""

from std.time import perf_counter_ns
from std.math import sqrt, sin, cos
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig, FRICTION_PYRAMID, FRICTION_ELLIPTIC

comptime DT: Real = 1.0 / 60.0


def _run(n: Int, balls: Bool, variant: Int) raises -> Tuple[Int, Real]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 200, 0.5, 200)), Vec3(200, 0.5, 200, 0), True)
    var ids = List[Int]()
    for k in range(n):
        var p = Vec3(Real(k % 16) * 1.5 - 12, 0.25, Real(k // 16) * 1.5 - 12, 0)
        if balls:
            var b = sc.add_sphere(QuatBody6.at_rest(p, Inertia3.sphere(1, 0.25)), 0.25, False)
            sc.set_can_sleep(b, False)
            ids.append(b.index())
        else:
            var b = sc.add(QuatBody6.at_rest(p, Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
            sc.set_can_sleep(b, False)
            ids.append(b.index())
    var cfg = SolverConfig()
    cfg.default_friction = 0.3
    if variant >= 1:
        cfg.friction_cone = FRICTION_ELLIPTIC
    if variant == 2:
        for i in range(len(sc.bset.bodies)):
            sc.set_static_friction(i, 0.5)
            sc.set_rolling_resistance(i, 0.01)
            sc.set_spinning_resistance(i, 0.01)
    var th = Real(30) * 0.017453292519943295
    var s = Real(9.8) * sin(th) / sqrt(Real(2))
    var g = Vec3(s, -9.8 * cos(th), s, 0) if not balls else Vec3(0, -9.8, 0, 0)
    for _ in range(20):
        sc.step(DT, Vec3(0, -9.8, 0, 0), cfg)
    if balls:
        for i in ids:
            sc.set_velocity(sc.bset.id_of(i), Vec3(2, 0, 0, 0), Vec3(0, 0, -8, 0))
    var x0 = List[Vec3]()
    for i in ids:
        x0.append(sc.bset.bodies[i].pos)
    var t0 = Int(perf_counter_ns())
    for _ in range(60):
        sc.step(DT, g, cfg)
    var us = (Int(perf_counter_ns()) - t0) // 60000
    var d = Real(0)
    for k in range(len(ids)):
        var v = sc.bset.bodies[ids[k]].pos - x0[k]
        d += sqrt(v[0] * v[0] + v[2] * v[2])
    return (us, d / Real(n))


def main() raises:
    print("### Contact model variants (17.50): cost per step\n")
    print("| N | scene | pyramid us | elliptic us | elliptic + static + rolling/spin us | slide / roll (m): pyramid, elliptic, full |")
    print("|---:|---|---:|---:|---:|---|")
    var names: List[String] = ["cubes on a 30 deg slope (diagonal)", "balls rolling at 2 m/s"]
    for n in [16, 256]:
        for sc in range(2):
            var a = _run(n, sc == 1, 0)
            var b = _run(n, sc == 1, 1)
            var c = _run(n, sc == 1, 2)
            print("|", n, "|", names[sc], "|", a[0], "|", b[0], "|", c[0], "|", a[1], ",", b[1], ",", c[1], "|")
    print("")
