"""Cloth self-collision: what it costs and what it prevents.

Both cloth solvers appear twice on the same scene -- a sheet long enough to pile
on the floor, which is the only configuration where self-collision has anything
to do. `gap=` is the distance between the closest pair of particles that are NOT
spring-connected, and it is the column that says whether the feature worked:
without it the sheet passes through itself and that number collapses to
essentially zero.

The two solvers are both here because XPBD and VBD are two variants of one seam.
A capability added to only one of them stops them being comparable, which is
worth more than the cost of running both.

The last pair of rows is a bigger sheet run for FEWER steps, so it has not piled
yet -- its `gap=` is identical with the feature on and off, because nothing is
touching. That row is not padding: it isolates the cost of LOOKING from the cost
of RESOLVING, which is the number a scene full of cloth that rarely folds
actually pays.

Broad phase is a uniform hash rebuilt every constraint iteration. Cloth
particles are all the same size and roughly the same spacing -- the case a
uniform grid handles best and a tree handles worst -- so the engine's BVH
variants stay in the rigid-body broadphase where they earn their keep.

Run with: `mojo run -I build benchmarks/bench_self_collide.mojo`.
"""

from std.math import sqrt
from std.benchmark import keep
from geometry.vec import Real
from physics.gpu_cloth import cpu_cloth_run, ClothState
from physics.vbd_cloth import cpu_vbd_run
from physics.self_collide import SKIP
from harness.bench import BenchTable, now

comptime DT = Float32(1.0) / 120.0
comptime REST = Float32(0.1)


def closest_far_pair(s: ClothState, width: Int) -> Real:
    var worst = Real(1e30)
    var n = len(s.x)
    for i in range(n):
        for j in range(i + 1, n):
            var dr = (i // width) - (j // width)
            var dc = (i % width) - (j % width)
            if dr < 0:
                dr = -dr
            if dc < 0:
                dc = -dc
            if dr <= SKIP and dc <= SKIP:
                continue
            var ex = Real(s.x[i] - s.x[j])
            var ey = Real(s.y[i] - s.y[j])
            var ez = Real(s.z[i] - s.z[j])
            var d = Real(sqrt(Float64(ex * ex + ey * ey + ez * ez)))
            if d < worst:
                worst = d
    return worst


def run[W: Int, H: Int](
    mut table: BenchTable, vbd: Bool, th: Real, steps: Int
):
    var t0 = now()
    var s = (
        cpu_vbd_run[W, H](steps, 8, DT, REST, th)
        if vbd
        else cpu_cloth_run[W, H](steps, 8, DT, REST, th)
    )
    var t1 = now()
    keep(s.x[0])
    var gap = closest_far_pair(s, W)
    table.add(
        ("vbd" if vbd else "xpbd")
        + (" self-collide" if th > 0 else " none")
        + " gap=" + String(gap),
        W * H, "step", t1 - t0, steps,
    )


def main() raises:
    var table = BenchTable("Cloth self-collision (sheet piling on the floor)")
    var th = Real(0.06)
    run[10, 40](table, False, 0, 400)
    run[10, 40](table, False, th, 400)
    run[10, 40](table, True, 0, 400)
    run[10, 40](table, True, th, 400)
    run[20, 60](table, False, 0, 200)
    run[20, 60](table, False, th, 200)
    table.print_report()
