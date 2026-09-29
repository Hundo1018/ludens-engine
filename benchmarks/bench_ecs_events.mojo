"""ECS eventing costs: push observers vs manual polling, and the deferred
set buffer vs direct writes.

Table 1 — the same membership-change detection job on the reactive backend
(semantics parity in `test_observers`): the push path pays a filter check at
every mutation and an O(inbox) drain; the poll path pays an O(world) snapshot
diff per frame. ns/event is the total frame cost divided by events detected.

Table 2 — the deferred `SetBuffer` (recording + sync-point replay, parity in
`test_deferred_set`) vs writing components directly: what the iteration-safety
of a command buffer costs per write.
Run with: `mojo run -I build benchmarks/bench_ecs_events.mojo`.
"""

from std.benchmark import keep
from harness.bench import BenchTable, now
from ecs.world import World
from ecs.component import ComponentType
from ecs.commands import SetBuffer
from ecs.sparse_backend import SparseSetBackend
from ecs.reactive_backend import ReactiveBackend, EV_ADD, EV_REMOVE


@fieldwise_init
struct Position(ComponentType):
    comptime ID: Int = 0
    var x: Int
    var y: Int


@fieldwise_init
struct Velocity(ComponentType):
    comptime ID: Int = 1
    var dx: Int
    var dy: Int


comptime RB = ReactiveBackend[Position, Velocity]
comptime SB = SparseSetBackend[Position, Velocity]

comptime N = 2048  # entities
comptime FRAMES = 50
comptime MUTS = 400  # velocity toggles per frame (each one is ADD or REMOVE)


def bench_observers(mut table: BenchTable):
    # --- push path: observers deliver at the mutation site, drain per frame
    var wp = World[RB]()
    var ids = List[type_of(wp.spawn())]()
    for i in range(N):
        ids.append(wp.spawn1(Position(i, i)))
    _ = wp.query2[Position, Velocity]()  # group exists in both paths
    var h = wp.backend.observe1[Velocity]((1 << EV_ADD) | (1 << EV_REMOVE))
    var have = List[Bool]()
    for _ in range(N):
        have.append(False)
    var events_push = 0
    var t0 = now()
    for f in range(FRAMES):
        for m in range(MUTS):
            var id = (f * 131 + m * 17) % N
            if have[id]:
                wp.remove[Velocity](ids[id])
            else:
                wp.set(ids[id], Velocity(id, -id))
            have[id] = not have[id]
        var ev = wp.backend.drain(h)
        events_push += len(ev)
    keep(events_push)
    var t1 = now()
    table.add(
        "push observers ev=" + String(events_push),
        N, "event", t1 - t0, events_push,
    )

    # --- poll path: identical mutations, membership diffed by scanning
    var wq = World[RB]()
    var idsq = List[type_of(wq.spawn())]()
    for i in range(N):
        idsq.append(wq.spawn1(Position(i, i)))
    _ = wq.query2[Position, Velocity]()
    var haveq = List[Bool]()
    var prev = List[Bool]()
    for _ in range(N):
        haveq.append(False)
        prev.append(False)
    var events_poll = 0
    var t2 = now()
    for f in range(FRAMES):
        for m in range(MUTS):
            var id = (f * 131 + m * 17) % N
            if haveq[id]:
                wq.remove[Velocity](idsq[id])
            else:
                wq.set(idsq[id], Velocity(id, -id))
            haveq[id] = not haveq[id]
        # manual polling: snapshot the query, diff against last frame
        var cur = List[Bool]()
        for _ in range(N):
            cur.append(False)
        var hits = wq.query2[Position, Velocity]()
        for i in range(len(hits)):
            cur[hits[i].id] = True
        for i in range(N):
            if cur[i] != prev[i]:
                events_poll += 1
        prev = cur^
    keep(events_poll)
    var t3 = now()
    table.add(
        "manual polling ev=" + String(events_poll),
        N, "event", t3 - t2, events_poll,
    )


def bench_setbuffer(mut table: BenchTable):
    comptime WRITES = 65536

    var wd = World[SB]()
    var ids = List[type_of(wd.spawn())]()
    for i in range(N):
        ids.append(wd.spawn1(Position(i, i)))
    var t0 = now()
    for k in range(WRITES):
        wd.set(ids[k % N], Position(k, -k))
    var t1 = now()
    keep(wd.get[Position](ids[0]).x)
    table.add("direct set", WRITES, "write", t1 - t0, WRITES)

    var wb = World[SB]()
    var idsb = List[type_of(wb.spawn())]()
    for i in range(N):
        idsb.append(wb.spawn1(Position(i, i)))
    var buf = SetBuffer[Position, Velocity]()
    var t2 = now()
    for k in range(WRITES):
        buf.set(idsb[k % N], Position(k, -k))
    buf.apply(wb)
    var t3 = now()
    keep(wb.get[Position](idsb[0]).x)
    table.add("setbuffer record+apply", WRITES, "write", t3 - t2, WRITES)


def main() raises:
    var t = BenchTable("ECS events: push observers vs polling; deferred vs direct set")
    bench_observers(t)
    bench_setbuffer(t)
    t.print_report()
