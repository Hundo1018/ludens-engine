"""Objective dispatch (ROADMAP 17.72): linear scan vs event-type index.

N objectives over 64 event types (no prerequisites, large targets so all
stay active), 2000 events; cost per event. The linear scan touches every
objective per event; the index touches the listeners of that type
(N / 64 on average); both then snapshot only the listeners' activeness.

Run with: `mojo run -I build benchmarks/bench_flow.mojo`.
"""

from std.benchmark import keep
from scheduler.rng import Pcg32
from gameplay.objectives import ObjectiveLog, DISPATCH_LINEAR, DISPATCH_INDEXED
from harness.bench import BenchTable, now


def run(mode: Int, n: Int) raises -> Int:
    var log = ObjectiveLog(mode)
    var rng = Pcg32.seeded(5)
    for _ in range(n):
        _ = log.add(Int(rng.next_u32() % 64), 1000000, List[Int]())
    var t0 = now()
    for _ in range(2000):
        log.on_event(Int(rng.next_u32() % 64))
    var t1 = now()
    keep(log.objs[0].progress)
    return t1 - t0


def main() raises:
    var t = BenchTable("Objective dispatch, 64 event types, 2000 events (17.72)")
    var ns: List[Int] = [100, 1000, 10000]
    for n in ns:
        t.add("linear N=" + String(n), n, "event", run(DISPATCH_LINEAR, n), 2000)
        t.add("indexed N=" + String(n), n, "event", run(DISPATCH_INDEXED, n), 2000)
    t.print_report()
