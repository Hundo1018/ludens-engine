"""World queries on real geometry (ROADMAP 17.13): cost per query vs scene size.

A grid of N mixed colliders (boxes, spheres, capsules) over a box floor; 256
queries per variant, straight down from above random grid points. Rows:
`ray_cast` (closed forms per kind), `sphere_cast` and `capsule_cast`
(conservative advancement; each step evaluates every candidate's distance, a
capsule's through a golden-section search), and `capsule_penetrations` (one
distance evaluation per candidate, no sweep). The candidate prefilter is a
linear scan over world AABBs, so every row grows with N; the ratio between
rows is the price of the sweep, and the N at which the scan starts to dominate
is where the persistent broadphase should take over as the prefilter.

Run: pixi run mojo run -I build benchmarks/bench_world_query.mojo
"""

from std.benchmark import keep
from harness.bench import BenchTable, now
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from collision.world_query import QueryFilter

comptime DOWN = Vec3(0, -1, 0, 0)
comptime Q = 256


def _scene(n: Int) -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(200, 1, 200, 0), True)
    var side = 1
    while side * side < n:
        side += 1
    for k in range(n):
        var x = Real(k % side) * 2.0 - Real(side)
        var z = Real(k // side) * 2.0 - Real(side)
        var b = QuatBody6.at_rest(Vec3(x, 0.5, z, 0), Inertia3.box(1, 0.4, 0.4, 0.4))
        if k % 3 == 0:
            _ = sc.add(b, Vec3(0.4, 0.4, 0.4, 0), True)
        elif k % 3 == 1:
            _ = sc.add_sphere(b, 0.4, True)
        else:
            _ = sc.add_capsule(b, 0.3, 0.2, True)
    return sc^


def main():
    var table = BenchTable("World queries on real geometry (17.13), 256 queries per row")
    var f = QueryFilter.all()
    for n in [16, 64, 256, 1024]:
        var sc = _scene(n)
        var span = Real(Int(sqrt_int(n)) + 1)
        var origins = List[Vec3]()
        for q in range(Q):
            var u = Real((q * 37) % 101) / 101.0
            var v = Real((q * 61) % 97) / 97.0
            origins.append(Vec3((u * 2 - 1) * span, 5, (v * 2 - 1) * span, 0))
        var acc = Real(0)
        var t0 = now()
        for q in range(Q):
            acc += sc.ray_cast(origins[q], DOWN, 10, f).t
        table.add("ray_cast", n, "query", now() - t0, Q)
        t0 = now()
        for q in range(Q):
            acc += sc.sphere_cast(origins[q], 0.3, DOWN, 10, f).t
        table.add("sphere_cast", n, "query", now() - t0, Q)
        t0 = now()
        for q in range(Q):
            acc += sc.capsule_cast(origins[q], origins[q] + Vec3(0, 0.8, 0, 0), 0.3, DOWN, 10, f).t
        table.add("capsule_cast", n, "query", now() - t0, Q)
        t0 = now()
        for q in range(Q):
            var p = origins[q] - Vec3(0, 4.3, 0, 0)
            acc += Real(len(sc.capsule_penetrations(p, p + Vec3(0, 0.8, 0, 0), 0.3, f)))
        table.add("capsule_penetrations", n, "query", now() - t0, Q)
        keep(acc)
    table.print_report()


def sqrt_int(n: Int) -> Int:
    var s = 1
    while s * s < n:
        s += 1
    return s
