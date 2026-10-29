"""ROADMAP 17.52: cost of the new shape kinds.

1. N bodies dropped on a floor, 60 steps measured after 60 warm-up steps
   (contacts settled): ns per body-step for a sphere (analytic pair), an
   equal-axis and a (1, 0.5, 0.7) ellipsoid (GJK distance + EPA on the
   support mapping), a 16-segment cylinder (hull path + capsule side), and
   a box on a box floor vs on a 25^3 SDF plane (26 samples per box).
2. Point-to-cylinder distance by `support_distance`: the analytic
   `SupportCylinder` vs the 16-gon `ConvexPoly` hull -- ns per query and
   the distance error at 11.25 deg (between two hull vertices).
"""

from std.time import perf_counter_ns
from std.math import cos, sin, pi
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from geometry.gjk import ConvexPoly
from geometry.gjk_distance import support_distance
from geometry.support import SupportCylinder, SupportCapsule
from geometry.sdf_grid import SdfGrid
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _plane(res: Int) -> SdfGrid:
    var g = SdfGrid(res, Vec3(-40, -40, -40, 0), Real(80) / Real(res - 1))
    for k in range(res):
        for j in range(res):
            for i in range(res):
                g.values[(k * res + j) * res + i] = g.node(i, j, k)[1]
    return g^


def _scene(kind: Int, n: Int) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    if kind == 5:
        _ = sc.add_sdf(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), _plane(25))
    else:
        _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 40, 0.5, 40)), Vec3(40, 0.5, 40, 0), True)
    var side = 1
    while side * side < n:
        side += 1
    for k in range(n):
        var p = Vec3(Real(k % side) * 1.6 - Real(side) * 0.8, 0.8, Real(k // side) * 1.6 - Real(side) * 0.8, 0)
        var id: Int
        match kind:
            case 0:
                id = sc.add_sphere(QuatBody6.at_rest(p, Inertia3.sphere(1, 0.5)), 0.5, False).index()
            case 1:
                id = sc.add_ellipsoid(QuatBody6.at_rest(p, Inertia3.sphere(1, 0.5)), Vec3(0.5, 0.5, 0.5, 0), False).index()
            case 2:
                id = sc.add_ellipsoid(QuatBody6.at_rest(p, Inertia3.ellipsoid(1, 0.6, 0.5, 0.4)), Vec3(0.6, 0.5, 0.4, 0), False).index()
            case 3:
                id = sc.add_cylinder(QuatBody6.at_rest(p, Inertia3.cylinder(1, 0.4, 0.5)), 0.4, 0.5, False).index()
            case _:
                id = sc.add(QuatBody6.at_rest(p, Inertia3.box(1, 0.4, 0.4, 0.4)), Vec3(0.4, 0.4, 0.4, 0), False).index()
        _ = id
    for i in range(len(sc.bset.bodies)):
        sc.set_can_sleep(sc.bset.id_of(i), False)
    return sc^


def main() raises:
    var names: List[String] = [
        "sphere (analytic)", "ellipsoid 0.5 x 3 (GJK/EPA)", "ellipsoid (0.6, 0.5, 0.4)",
        "cylinder 16 segments", "box on box floor", "box on SDF plane (25^3)",
    ]
    var t = BenchTable("Shape kinds (17.52): resting bodies, ns per body-step")
    for n in [64, 256]:
        for kind in range(6):
            var sc = _scene(kind, n)
            for _ in range(60):
                sc.step_soft(DT, G)
            var t0 = Int(perf_counter_ns())
            for _ in range(60):
                sc.step_soft(DT, G)
            var t1 = Int(perf_counter_ns())
            t.add(names[kind], n, "body-step", t1 - t0, n * 60)
    t.print_report()

    var cy = SupportCylinder(Vec3(0, 0, 0, 0), Vec3(0, 1, 0, 0), 1, 0.5)
    var hull = ConvexPoly[3]()
    for k in range(16):
        var a = Real(2) * pi * Real(k) / 16
        hull.add(Vec3(cos(a), -0.5, sin(a), 0))
        hull.add(Vec3(cos(a), 0.5, sin(a), 0))
    var reps = 20000
    var acc = Real(0)
    var t2 = Int(perf_counter_ns())
    for k in range(reps):
        var a = Real(k) * 0.001
        acc += support_distance(SupportCapsule(Vec3(3 * cos(a), 0.2, 3 * sin(a), 0), Vec3(0, 1, 0, 0), 0, 0), 0, cy, 0).dist
    var t3 = Int(perf_counter_ns())
    for k in range(reps):
        var a = Real(k) * 0.001
        acc += support_distance(SupportCapsule(Vec3(3 * cos(a), 0.2, 3 * sin(a), 0), Vec3(0, 1, 0, 0), 0, 0), 0, hull, 0).dist
    var t4 = Int(perf_counter_ns())
    var mid = Real(pi / 16)
    var q = SupportCapsule(Vec3(3 * cos(mid), 0, 3 * sin(mid), 0), Vec3(0, 1, 0, 0), 0, 0)
    var e_exact = support_distance(q, 0, cy, 0).dist - 2
    var e_hull = support_distance(q, 0, hull, 0).dist - 2
    print("### Point-to-cylinder distance (17.52): analytic support vs 16-gon hull\n")
    print("| shape | ns / query | error at 11.25 deg |")
    print("|---|---:|---:|")
    print("| SupportCylinder |", (t3 - t2) // reps, "|", e_exact, "|")
    print("| 16-gon ConvexPoly |", (t4 - t3) // reps, "|", e_hull, "|")
    print("")
    if acc != acc:
        print("NaN")
