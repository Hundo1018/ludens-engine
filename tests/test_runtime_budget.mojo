# tier: system
# run: alone
"""`Runtime` under a step-time budget (ROADMAP 17.79,
`Runtime.advance_budgeted` with `physics.lod.SimBudget`).

  1. Ordinary: 200 boxes in piles; a budget of 1 ns (unreachable) walks the
     solver down to its minimum (1 iteration, 1 substep) and the runtime's
     config follows; a budget of 10 s keeps the maximum (4 x 4).
  2. Integration: with the huge budget `advance_budgeted` moves the bodies
     exactly as `advance` does (same config every tick); with the tiny one
     the mean step time over the last 30 ticks is below the first 5 ticks'
     (printed: the cost the budget bought back).
  3. Extreme: `advance_budgeted` during an in-flight step raises.
"""

from std.time import perf_counter_ns
from harness.runner import Suite
from geometry.vec import Real, Vec3
from ecs.sparse_backend import SparseSetBackend
from ecs.transform import Transform
from physics.rigid6 import Inertia3, QuatBody6
from physics.lod import SimBudget
from gameplay.runtime import Runtime, RigidBodyRef

comptime DT: Real = 1.0 / 60.0
comptime Rt = Runtime[SparseSetBackend[Transform, RigidBodyRef], QuatBody6]


def _setup(mut rt: Rt):
    _ = rt.spawn_body(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 30, 0.5, 30)), Vec3(30, 0.5, 30, 0), True)
    for k in range(200):
        var x = Real(k % 20) * 0.6 - 6
        var z = Real((k // 20) % 5) * 0.6 - 1.5
        var y = 0.25 + 0.52 * Real(k // 100)
        _ = rt.spawn_body(QuatBody6.at_rest(Vec3(x, y, z, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)


def main() raises:
    var s = Suite("runtime_budget")
    var tight = Rt(DT, Vec3(0, -9.8, 0, 0))
    _setup(tight)
    var tb = SimBudget(1)
    var first = 0
    var last = 0
    for f in range(60):
        var t0 = Int(perf_counter_ns())
        _ = tight.advance_budgeted(Float64(DT), tb)
        var dt_ns = Int(perf_counter_ns()) - t0
        if f < 5:
            first += dt_ns
        elif f >= 30:
            last += dt_ns
    print("  1 ns budget: iters", tb.iters, "substeps", tb.substeps, " runtime cfg", tight.cfg.iters, "x", tight.cfg.substeps, " mean frame us first 5", first // 5000, " last 30", last // 30000)
    s.check(tb.iters == 1 and tb.substeps == 1 and tight.cfg.iters == 1 and tight.cfg.substeps == 1, "an unreachable budget walks down to 1 iteration x 1 substep")
    s.check(last // 30 < first // 5, "the reduced solver steps faster than the first ticks")

    var loose = Rt(DT, Vec3(0, -9.8, 0, 0))
    _setup(loose)
    var plain = Rt(DT, Vec3(0, -9.8, 0, 0))
    _setup(plain)
    var lb = SimBudget(10_000_000_000)
    for _ in range(60):
        _ = loose.advance_budgeted(Float64(DT), lb)
        _ = plain.advance(Float64(DT))
    var same = True
    for b in range(len(loose.scene.bset.bodies)):
        var p = loose.scene.bset.bodies[b].pos
        var q = plain.scene.bset.bodies[b].pos
        if p[0] != q[0] or p[1] != q[1] or p[2] != q[2]:
            same = False
    s.check(lb.iters == 4 and lb.substeps == 4 and same, "a generous budget keeps 4 x 4 and matches advance bit for bit")

    var h = plain.begin_advance(Float64(DT))
    var raised = False
    try:
        _ = plain.advance_budgeted(Float64(DT), lb)
    except:
        raised = True
    plain.execute(h)
    _ = plain.finish(h)
    s.check(raised, "advance_budgeted during an in-flight step raises")
    s.finish()
