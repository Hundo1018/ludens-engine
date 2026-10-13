"""Force elements (ROADMAP 17.74): exact hull buoyancy against sampling,
and the per-call cost of a wing and a thruster.

Submerged volume of a box hull half under water: the polytope cut
(`HullBuoyancy.submerged`, exact) against midpoint sampling at 4^3, 8^3
and 16^3 (`physics.fields.box_submerged_sampled`), each with its volume
error against the closed form.

Run with: `mojo run -I build benchmarks/bench_force_elements.mojo`.
"""

from std.benchmark import keep
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.fields import box_submerged_sampled, box_submerged_exact
from physics.water import FlatWater
from gameplay.force_element import Thruster
from gameplay.watercraft import HullBuoyancy
from gameplay.aircraft import Wing
from harness.bench import BenchTable, now


def main() raises:
    var sc = ContactScene6[QuatBody6]()
    var b = QuatBody6.at_rest(Vec3(0, 0.07, 0, 0), Inertia3.box(1000, 1, 0.25, 1))
    var id = sc.add(b^, Vec3(1, 0.25, 1, 0), False)
    var pts = List[Float64]()
    for k in range(8):
        pts.append(Float64(1 if (k & 4) != 0 else -1))
        pts.append(Float64(0.25 if (k & 2) != 0 else -0.25))
        pts.append(Float64(1 if (k & 1) != 0 else -1))
    var hull = HullBuoyancy(pts, FlatWater(0))
    var exact = box_submerged_exact(Vec3(0, 0.07, 0, 0), Vec3(1, 0.25, 1, 0), 0)[0]
    var t = BenchTable("Submerged volume of a box hull: polytope cut vs sampling (17.74)")
    var reps = 2000
    var acc = Real(0)
    var t0 = now()
    for _ in range(reps):
        acc += hull.submerged(sc, id, 0)[0]
    var t1 = now()
    t.add("polytope cut, error " + String(Float32(abs(hull.submerged(sc, id, 0)[0] - exact))), 1, "query", t1 - t0, reps)
    var ns: List[Int] = [4, 8, 16]
    for n in ns:
        var t2 = now()
        for _ in range(reps // 4):
            acc += box_submerged_sampled(sc.bset.bodies[0], Vec3(1, 0.25, 1, 0), 0, n)[0]
        var t3 = now()
        var err = abs(box_submerged_sampled(sc.bset.bodies[0], Vec3(1, 0.25, 1, 0), 0, n)[0] - exact)
        t.add("sampled " + String(n) + "^3, error " + String(Float32(err)), 1, "query", t3 - t2, reps // 4)
    keep(acc)
    t.print_report()
    var u = BenchTable("Wing and thruster elements per apply (17.74)")
    var wing = Wing.simple(Vec3(0, 0, 0, 0), 2)
    sc.bset.bodies[0].vel = Vec3(20, -1, 0, 0)
    var t4 = now()
    for _ in range(reps):
        acc += wing.apply(sc, id, 0)[1]
    var t5 = now()
    var thr = Thruster(Vec3(-1, 0, 0, 0), Vec3(1, 0, 0, 0), 100, 0.5)
    for _ in range(reps):
        acc += thr.apply(sc, id, 0)[0]
    var t6 = now()
    keep(acc)
    u.add("Wing.apply", 1, "apply", t5 - t4, reps)
    u.add("Thruster.apply", 1, "apply", t6 - t5, reps)
    u.print_report()
