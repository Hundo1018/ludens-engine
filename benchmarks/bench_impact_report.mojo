"""ROADMAP 17.49: cost of the step-impulse report.

N boxes resting on one floor (N contacts, 120 warm-up steps, then 30 timed).
The accumulation runs every step: the substep-sum estimator adds each
pair's impulses after every substep's relax sweep, the last-substep one only
after the last. Events on adds the payload fill (one dict lookup per event).
"""

from std.math import sqrt
from std.time import perf_counter_ns
from harness.bench import BenchTable, measure_ab
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig, IMPULSE_SUBSTEP_SUM, IMPULSE_LAST_SUBSTEP

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime STEPS = 30


def _scene(n: Int, events: Bool) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var side = Int(sqrt(Float64(n))) + 1
    var hw = Real(side) * 0.4 + 2
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, hw, 0.5, hw)), Vec3(hw, 0.5, hw, 0), True)
    for i in range(n):
        var x = Real(i % side) * 0.6 - Real(side) * 0.3
        var z = Real(i // side) * 0.6 - Real(side) * 0.3
        var id = sc.add(QuatBody6.at_rest(Vec3(x, 0.2, z, 0), Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
        sc.set_can_sleep(id, False)
    sc.events_on = events
    return sc^


def _run(n: Int, events: Bool, est: Int) raises -> Int:
    var sc = _scene(n, events)
    var cfg = SolverConfig()
    cfg.impulse_estimator = est
    cfg.broadphase = True
    for _ in range(120):
        sc.step(DT, G, cfg)
    var t0 = Int(perf_counter_ns())
    for _ in range(STEPS):
        sc.step(DT, G, cfg)
    return Int(perf_counter_ns()) - t0


def main() raises:
    var t = BenchTable("Step-impulse report (17.49): resting boxes, N contacts")
    for n in [256, 1024]:
        t.add("substep sum, events off", n, "step", _run(n, False, IMPULSE_SUBSTEP_SUM), STEPS)
        t.add("last substep, events off", n, "step", _run(n, False, IMPULSE_LAST_SUBSTEP), STEPS)
        t.add("substep sum, events on", n, "step", _run(n, True, IMPULSE_SUBSTEP_SUM), STEPS)
    t.print_report()

    # Interleaved A/B in one process (17.83 `measure_ab`): the sum estimator
    # does three more accumulation passes per step than the last-substep one,
    # so the ratio bounds what the always-on report costs.
    var sa = _scene(1024, False)
    var sb = _scene(1024, False)
    var ca = SolverConfig()
    ca.broadphase = True
    ca.impulse_estimator = IMPULSE_LAST_SUBSTEP
    var cb = SolverConfig()
    cb.broadphase = True
    cb.impulse_estimator = IMPULSE_SUBSTEP_SUM
    for _ in range(120):
        sa.step(DT, G, ca)
        sb.step(DT, G, cb)

    def a() {mut sa, imm ca}:
        sa.step(DT, G, ca)

    def b() {mut sb, imm cb}:
        sb.step(DT, G, cb)

    var r = measure_ab(a, b, rounds=21)
    print("### Substep sum vs last substep, N = 1024, interleaved (21 rounds)\n")
    print("| A (last substep) ns/step | B (substep sum) ns/step | B / A | per-round range | resolved |")
    print("|---:|---:|---:|---|---|")
    print("|", r.a_ns, "|", r.b_ns, "|", r.ratio(), "|", r.ratio_lo, "-", r.ratio_hi, "|", r.resolved(), "|")
