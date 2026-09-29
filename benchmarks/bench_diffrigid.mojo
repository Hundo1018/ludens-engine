"""Rigid vs soft contact as a differentiation seam.

Cost first, and it is mostly the boring half: an impulsive contact is a
compare and two multiplies, a penalty contact is a compare and four, and
forward-mode AD adds about 10 percent to either. There is no performance
reason to prefer one — except at the longest rollout, where the differentiated
SOFT model falls off a cliff. The likely cause is denormals: its gradient
decays toward zero (the test measures 3e-45, which is denormal in f32) and
denormal arithmetic costs an order of magnitude on x86. A vanishing gradient
is not only uninformative here, it is expensive.

The second block is the reason to care. Finite differencing a rigid rollout
requires a probe small enough that both sides fire their contacts on the SAME
steps — matching bounce counts is not sufficient, and a probe that satisfies
the count check while violating the schedule check returns a number that is
not a derivative. The sweep reports the largest usable probe as the timestep
changes. It shrinks with dt, because the boundaries are spaced by how far the
body moves in one step: finer integration makes the gradient more accurate and
finite differences LESS able to see it. Forward-mode AD has no probe and no
window; it differentiates the discrete map it is handed.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from std.math import sqrt
from harness.bench import BenchTable
from geometry.vec import Real
from geometry.field import RealF, DualReal
from physics.diffrigid import rollout_rigid, rollout_soft

comptime REPS = 3
comptime ITERS = 200
comptime E: Real = 0.6


def _rows(mut t: BenchTable, steps: Int) raises:
    var dt = Real(1.0 / 480.0)
    var best = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        for _ in range(ITERS):
            var r = rollout_rigid[RealF](
                RealF(2.5), RealF(1.0), RealF(1.0), steps, dt, E
            )
            keep(r.y.v)
        var d = Int(perf_counter_ns()) - t0
        if d < best:
            best = d
    t.add("rigid rollout (value only)", steps, "rollout", best, ITERS)

    var b2 = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        for _ in range(ITERS):
            var r = rollout_rigid[DualReal](
                DualReal.const(2.5), DualReal.const(1.0), DualReal.seed(1.0),
                steps, dt, E,
            )
            keep(r.y.b)
        var d = Int(perf_counter_ns()) - t0
        if d < b2:
            b2 = d
    t.add("rigid rollout + forward AD", steps, "rollout", b2, ITERS)

    var b3 = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        for _ in range(ITERS):
            var r = rollout_soft[RealF](
                RealF(2.5), RealF(1.0), RealF(1.0), steps, dt, 4000.0, 120.0
            )
            keep(r.y.v)
        var d = Int(perf_counter_ns()) - t0
        if d < b3:
            b3 = d
    t.add("soft rollout (value only)", steps, "rollout", b3, ITERS)

    var b4 = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        for _ in range(ITERS):
            var r = rollout_soft[DualReal](
                DualReal.const(2.5), DualReal.const(1.0), DualReal.seed(1.0),
                steps, dt, 4000.0, 120.0,
            )
            keep(r.y.b)
        var d = Int(perf_counter_ns()) - t0
        if d < b4:
            b4 = d
    t.add("soft rollout + forward AD", steps, "rollout", b4, ITERS)


def _window() raises:
    """The largest probe that still lands on one smooth piece."""
    print("  dt          largest usable eps      FD error there")
    for k in range(5):
        var dt = Real(1.0 / 120.0) / Real(1 << k)
        var steps = Int(Float64(1.5) / Float64(dt))
        var d = rollout_rigid[DualReal](
            DualReal.const(2.5), DualReal.const(1.0), DualReal.seed(1.0),
            steps, dt, E,
        )
        var eps = Real(1e-2)
        var err = Real(-1)
        for _ in range(40):
            var hp = rollout_rigid[RealF](
                RealF(2.5), RealF(1.0), RealF(1.0 + eps), steps, dt, E
            )
            var hm = rollout_rigid[RealF](
                RealF(2.5), RealF(1.0), RealF(1.0 - eps), steps, dt, E
            )
            if hp.schedule == d.schedule and hm.schedule == d.schedule:
                var fd = (hp.y.v - hm.y.v) / (2 * eps)
                err = Real(abs(Float64(fd - d.y.b)))
                break
            eps = eps * 0.5
        print("  ", dt, "      ", eps, "      ", err)


def main() raises:
    var t = BenchTable("Rigid vs soft contact, with and without forward AD")
    comptime for li in range(3):
        comptime NS = 180 if li == 0 else (720 if li == 1 else 2880)
        _rows(t, NS)
    t.print_report()

    print("")
    print("Finite differencing a rigid rollout: the usable probe window")
    _window()
