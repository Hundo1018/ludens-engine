"""ROADMAP 17.50: per-step cost of the contact model variants.

N cubes (half 0.25) sliding on a 30 degree slope (a flat floor under tilted
gravity, mu 0.3, downhill along the floor diagonal) and N balls (radius
0.25) rolling at 2 m/s, 60 steps timed after 20 settling steps. Variants:
the default pyramid cone, the elliptic cone, and the elliptic cone with
static friction 0.5 and rolling / spin resistance 0.01 m on every body
(which also turns on the contact-model branch of the solve). "slide" is the
mean distance a cube moved, which shows the pyramid's larger diagonal cap.

Second table: the normal solve seam (`SolverConfig.contact_solver`), GS
per point vs BLOCK (a manifold's points together), on S stacks of 10 cubes
(4-point manifolds), 120 steps timed after 60 settling steps; "creep" is
the largest sideways offset of any cube after the run. Third table: the
same stacks with one step of 16 iterations (PGS style) against the
default 4 substeps of 4 iterations (the soft step is substepped, TGS
style); "drop" is how far the top cube sank from its stacked height.
"""

from std.time import perf_counter_ns
from std.math import sqrt, sin, cos
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig, FRICTION_PYRAMID, FRICTION_ELLIPTIC, CONTACT_GS, CONTACT_BLOCK

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


def _stacks(stacks: Int, kind: Int, iters: Int, substeps: Int = 4) raises -> Tuple[Int, Real, Real]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 200, 0.5, 200)), Vec3(200, 0.5, 200, 0), True)
    var ids = List[Int]()
    var base = List[Vec3]()
    for k in range(stacks):
        var x = Real(k % 8) * 3 - 12
        var z = Real(k // 8) * 3 - 12
        for j in range(10):
            var p = Vec3(x, 0.5 + Real(j), z, 0)
            var b = sc.add(QuatBody6.at_rest(p, Inertia3.box(1, 0.5, 0.5, 0.5)), Vec3(0.5, 0.5, 0.5, 0), False)
            sc.set_can_sleep(b, False)
            ids.append(b.index())
            base.append(p)
    var cfg = SolverConfig()
    cfg.contact_solver = kind
    cfg.iters = iters
    cfg.substeps = substeps
    var g = Vec3(0, -9.8, 0, 0)
    for _ in range(60):
        sc.step(DT, g, cfg)
    var t0 = Int(perf_counter_ns())
    for _ in range(120):
        sc.step(DT, g, cfg)
    var us = (Int(perf_counter_ns()) - t0) // 120000
    var creep = Real(0)
    for k in range(len(ids)):
        var v = sc.bset.bodies[ids[k]].pos - base[k]
        creep = max(creep, sqrt(v[0] * v[0] + v[2] * v[2]))
    var drop = Real(0)
    for k in range(stacks):
        drop = max(drop, base[10 * k + 9][1] - sc.bset.bodies[ids[10 * k + 9]].pos[1])
    return (us, creep, drop)


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
    print("### Normal solve: per point (GS) vs per manifold (BLOCK) (17.50)\n")
    print("| stacks of 10 | iters | GS us | BLOCK us | creep GS (m) | creep BLOCK (m) |")
    print("|---:|---:|---:|---:|---:|---:|")
    for st in [1, 16]:
        for it in [1, 4]:
            var a = _stacks(st, CONTACT_GS, it)
            var b = _stacks(st, CONTACT_BLOCK, it)
            print("|", st, "|", it, "|", a[0], "|", b[0], "|", a[1], "|", b[1], "|")
    print("")
    print("### One step of 16 iterations (PGS style) vs 4 substeps of 4 (the default soft step, TGS style) (17.50)\n")
    print("| stacks of 10 | substeps x iters | us | top-cube drop (m) | creep (m) |")
    print("|---:|---|---:|---:|---:|")
    for st in [1, 16]:
        var p = _stacks(st, CONTACT_GS, 16, 1)
        var t = _stacks(st, CONTACT_GS, 4, 4)
        print("|", st, "| 1 x 16 |", p[0], "|", p[2], "|", p[1], "|")
        print("|", st, "| 4 x 4 |", t[0], "|", t[2], "|", t[1], "|")
    print("")
