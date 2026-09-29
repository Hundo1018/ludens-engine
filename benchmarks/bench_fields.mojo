"""Force fields and buoyancy: cost per frame (ROADMAP 17.27 / 17.28).

Fields: N bodies under 1 and 8 fields (region tests + force); constant wind
vs wind sampled from a grid (the seam's extra cost is the trilinear
lookup). Buoyancy: the submerged-volume estimate per body -- the closed
form for a sphere vs midpoint integration over a box at 8^3 and 16^3
samples, the accuracy knob.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.fields import (
    ForceField, WindGrid, WaterVolume, apply_fields, apply_buoyancy,
    sphere_submerged, box_submerged_sampled,
)

comptime DT: Real = 1.0 / 60.0
comptime REPS = 50
comptime G = Vec3(0, -9.8, 0, 0)


def _scene(n: Int, spheres: Bool) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    for i in range(n):
        var p = Vec3(Real(i % 32) - 16, 1.9, Real(i // 32) - 16, 0)
        if spheres:
            _ = sc.add_sphere(QuatBody6.at_rest(p, Inertia3.sphere(1, 0.2)), 0.2, False)
        else:
            _ = sc.add(QuatBody6.at_rest(p, Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
    return sc^


def main() raises:
    var t = BenchTable("Force fields and buoyancy per frame")
    var big_lo = Vec3(-100, -100, -100, 0)
    var big_hi = Vec3(100, 100, 100, 0)
    var grids = List[WindGrid]()
    grids.append(WindGrid(16, 16, 16, Vec3(-20, -20, -20, 0), 2.5, Vec3(3, 0, 1, 0)))
    for n in [64, 1024]:
        var one = List[ForceField]()
        one.append(ForceField.wind(big_lo, big_hi, Vec3(3, 0, 1, 0), 1))
        var eight = List[ForceField]()
        for k in range(8):
            eight.append(ForceField.radial(Vec3(Real(k), 0, 0, 0), 50, 10))
        var gridw = List[ForceField]()
        gridw.append(ForceField.wind(big_lo, big_hi, Vec3(0, 0, 0, 0), 1, 0))
        var sc = _scene(n, False)
        var t0 = Int(perf_counter_ns())
        for _ in range(REPS):
            apply_fields(sc, one, grids, G, DT)
        t.add("1 field (constant wind)", n, "frame", Int(perf_counter_ns()) - t0, REPS)
        var t1 = Int(perf_counter_ns())
        for _ in range(REPS):
            apply_fields(sc, gridw, grids, G, DT)
        t.add("1 field (wind from a grid)", n, "frame", Int(perf_counter_ns()) - t1, REPS)
        var t2 = Int(perf_counter_ns())
        for _ in range(REPS):
            apply_fields(sc, eight, grids, G, DT)
        t.add("8 radial fields", n, "frame", Int(perf_counter_ns()) - t2, REPS)
        keep(sc.bset.bodies[0].position()[0])

    var waters = List[WaterVolume]()
    waters.append(WaterVolume(Vec3(-50, -5, -50, 0), Vec3(50, 2, 50, 0), 1000, 1, 1))
    for n in [64, 1024]:
        var ss = _scene(n, True)
        var t0 = Int(perf_counter_ns())
        for _ in range(REPS):
            apply_buoyancy(ss, waters, G, DT)
        t.add("buoyancy, spheres (closed form)", n, "frame", Int(perf_counter_ns()) - t0, REPS)
        var bs = _scene(n, False)
        var t1 = Int(perf_counter_ns())
        for _ in range(REPS):
            apply_buoyancy(bs, waters, G, DT, 8)
        t.add("buoyancy, boxes (8^3 samples)", n, "frame", Int(perf_counter_ns()) - t1, REPS)
        var t2 = Int(perf_counter_ns())
        for _ in range(REPS):
            apply_buoyancy(bs, waters, G, DT, 16)
        t.add("buoyancy, boxes (16^3 samples)", n, "frame", Int(perf_counter_ns()) - t2, REPS)
        keep(bs.bset.bodies[0].position()[1])
    t.print_report()
