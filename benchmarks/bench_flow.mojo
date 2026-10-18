"""Objective dispatch (ROADMAP 17.72): linear scan vs event-type index.

N objectives over 64 event types (no prerequisites, large targets so all
stay active), 2000 events; cost per event. The linear scan touches every
objective per event; the index touches the listeners of that type
(N / 64 on average); both then snapshot only the listeners' activeness.

Checkpoint (`gameplay.checkpoint`): a `GameFlow` with F integer flags
(names "f<i>"), F / 10 objectives and one 64-slot inventory, taken to
bytes and restored; cost per flag (scene excluded: its cost is the 6.10
snapshot, `bench_replay`).

Run with: `mojo run -I build benchmarks/bench_flow.mojo`.
"""

from std.benchmark import keep
from scheduler.rng import Pcg32
from gameplay.objectives import ObjectiveLog, DISPATCH_LINEAR, DISPATCH_INDEXED
from gameplay.flow import FLAG_INT
from gameplay.inventory import Inventory
from gameplay.checkpoint import GameFlow
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


def ckp(nf: Int) raises -> Tuple[Int, Int, Int]:
    var g = GameFlow(1)
    for i in range(nf):
        _ = g.flags.declare("f" + String(i), FLAG_INT, i)
    for i in range(nf // 10):
        _ = g.objectives.add(i % 64, 10, List[Int]())
    g.inventories.append(Inventory(64, [99, 99, 99]))
    var t0 = now()
    var b = g.to_bytes()
    var t1 = now()
    var back = GameFlow.from_bytes(b)
    var t2 = now()
    keep(back.flags.get(nf - 1))
    return (t1 - t0, t2 - t1, len(b))


def main() raises:
    var t = BenchTable("Objective dispatch, 64 event types, 2000 events (17.72)")
    var ns: List[Int] = [100, 1000, 10000]
    for n in ns:
        t.add("linear N=" + String(n), n, "event", run(DISPATCH_LINEAR, n), 2000)
        t.add("indexed N=" + String(n), n, "event", run(DISPATCH_INDEXED, n), 2000)
    t.print_report()
    var c = BenchTable("Flow checkpoint to / from bytes (17.72)")
    var fs: List[Int] = [100, 1000, 10000, 100000]
    for nf in fs:
        var r = ckp(nf)
        c.add("take F=" + String(nf) + " (" + String(r[2] // 1024) + " KiB)", nf, "flag", r[0], nf)
        c.add("restore F=" + String(nf), nf, "flag", r[1], nf)
    c.print_report()
