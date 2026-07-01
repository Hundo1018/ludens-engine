"""Linear-algebra benchmark: scalar lane-loop vs width-4 SIMD.

The same workload — transform N points by a 3D affine `Mat4` — run through the
scalar `transform_point4` (per-lane `comptime for`) and the `transform_point4_simd`
fast path (each row·point is a width-4 SIMD dot, which is *safe* unlike width-3).
Shows what the SIMD seam buys on the hottest matrix op. Run with:
`mojo run -I build benchmarks/bench_linalg.mojo`.
"""

from std.benchmark import keep
from harness.bench import BenchTable, now
from geometry.mat import Mat4, transform_point4, transform_point4_simd
from geometry.quat import Quat, compose_trs4
from geometry.vec import Vec3


def main() raises:
    var table = BenchTable("Linear algebra — scalar vs SIMD transform")
    var N = 400000

    var q = Quat.from_axis_angle(Vec3(0, 0, 1), 0.7)
    var m = compose_trs4(Vec3(1, 2, 3), q, Vec3(2, 1, 0.5))
    var p = Vec3(1, 1, 1)

    var acc = Vec3(0)
    var t0 = now()
    for _i in range(N):
        acc = acc + transform_point4(m, p)
        keep(acc[0])
    var t1 = now()
    table.add("scalar", N, "transform_point", t1 - t0, N)

    var acc2 = Vec3(0)
    var t2 = now()
    for _i in range(N):
        acc2 = acc2 + transform_point4_simd(m, p)
        keep(acc2[0])
    var t3 = now()
    table.add("simd-w4", N, "transform_point", t3 - t2, N)

    table.print_report()
