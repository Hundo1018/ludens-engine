"""Operations boundary (ROADMAP 17.73): what telemetry costs.

`Outbox.push` per record (plain, with 1-in-4 sampling, into a full outbox);
and a 40-box scene stepped 300 times with and without one telemetry record
per body per tick - the overhead the ROADMAP item says should stay in the
noise next to the step.

Run with: `mojo run -I build benchmarks/bench_ops.mojo`.
"""

from std.benchmark import keep
from geometry.vec import Real, Vec3
from diag.outbox import Outbox
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from harness.bench import BenchTable, now


def pile() -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    for k in range(40):
        _ = sc.add(QuatBody6.at_rest(Vec3(Real(k % 5) * 0.6 - 1.2, 0.3 + Real(k // 5) * 0.55, Real(k % 3) * 0.1, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    return sc^


def main():
    var t = BenchTable("Outbox push (17.73)")
    var n = 200000
    var o = Outbox(n)
    var t0 = now()
    for i in range(n):
        _ = o.push(1, i, i % 13, i)
    var t1 = now()
    var s = Outbox(n)
    s.sample_every = 4
    for i in range(n):
        _ = s.push(1, i, i % 13, i)
    var t2 = now()
    var full = Outbox(0)
    for i in range(n):
        _ = full.push(1, i, 0)
    var t3 = now()
    keep(len(o.records) + len(s.records) + full.dropped)
    t.add("push", n, "record", t1 - t0, n)
    t.add("push, sample 1 in 4", n, "record", t2 - t1, n)
    t.add("push into a full outbox (dropped)", n, "record", t3 - t2, n)
    t.print_report()

    var u = BenchTable("Telemetry overhead on a 40-box scene, 300 steps (17.73)")
    var a = pile()
    var t4 = now()
    for _ in range(300):
        a.step_soft(1.0 / 60.0, Vec3(0, -9.8, 0, 0))
    var t5 = now()
    var b = pile()
    var tele = Outbox(1 << 20)
    var t6 = now()
    for tk in range(300):
        b.step_soft(1.0 / 60.0, Vec3(0, -9.8, 0, 0))
        for i in range(len(b.bset.bodies)):
            _ = tele.push(9, tk, i, Int(b.bset.bodies[i].pos[0] * 1000), Int(b.bset.bodies[i].pos[1] * 1000))
        _ = tele.drain()
    var t7 = now()
    keep(a.bset.bodies[3].pos[1] + b.bset.bodies[3].pos[1])
    u.add("telemetry off", 41, "step", t5 - t4, 300)
    u.add("telemetry on (41 records + drain per step)", 41, "step", t7 - t6, 300)
    u.print_report()
