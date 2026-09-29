"""ROADMAP 17.23: combine-mode dispatch cost.

`_solve_pair` computes each pair's combined friction via `physics.material
.combine` ONCE per pair per substep (not once per contact point) -- a cheap
small-int `if`/`elif` over comptime constants, not a virtual call or a
table lookup. This bench runs a solver step over N=1024 simultaneous
box-on-floor contacts with all four combine modes set uniformly, to check
that the CHOSEN mode doesn't change the solver's cost -- only which branch
it takes.
"""

from std.math import sqrt
from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.material import COMBINE_AVERAGE, COMBINE_MIN, COMBINE_MULTIPLY, COMBINE_MAX

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime N = 1024
comptime STEPS = 60


def _scene(mode: Int) raises -> ContactScene6[QuatBody6]:
    """N dynamic boxes on one wide floor, spaced so no two boxes touch each
    other -- every contact this scene generates is exactly one box-floor
    pair, so N boxes == N contacts."""
    var sc = ContactScene6[QuatBody6]()
    var side = Int(sqrt(Float64(N))) + 1
    var half_w = Real(side) * 0.4 + 2
    var floor = sc.add(
        QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, half_w, 0.5, half_w)),
        Vec3(half_w, 0.5, half_w, 0),
        True,
    )
    sc.set_friction_combine(floor.index(), mode)
    var bi = Inertia3.box(1, 0.2, 0.2, 0.2)
    for i in range(N):
        var row = i // side
        var col = i % side
        var x = Real(col) * 0.6 - Real(side) * 0.3
        var z = Real(row) * 0.6 - Real(side) * 0.3
        var b = sc.add(
            QuatBody6.at_rest(Vec3(x, 0.2, z, 0), bi), Vec3(0.2, 0.2, 0.2, 0), False,
        )
        sc.set_friction_combine(b.index(), mode)
    return sc^


def _run(mut sc: ContactScene6[QuatBody6]) raises -> Int:
    var t0 = Int(perf_counter_ns())
    for _ in range(STEPS):
        sc.step_soft(DT, G, broadphase=True)
    return Int(perf_counter_ns()) - t0


def main() raises:
    var t = BenchTable("Materials: combine-mode dispatch cost, N=1024 contacts")
    var s_avg = _scene(COMBINE_AVERAGE)
    t.add("AVERAGE", N, "step", _run(s_avg), STEPS)
    var s_min = _scene(COMBINE_MIN)
    t.add("MIN", N, "step", _run(s_min), STEPS)
    var s_mul = _scene(COMBINE_MULTIPLY)
    t.add("MULTIPLY", N, "step", _run(s_mul), STEPS)
    var s_max = _scene(COMBINE_MAX)
    t.add("MAX", N, "step", _run(s_max), STEPS)
    t.print_report()
