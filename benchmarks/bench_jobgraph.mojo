"""Automatic dependency scheduling: what deriving the schedule costs, and what
it wins back.

Three rows over the same six systems and the same world:

  sequential      registration order, the baseline every scheduler is checked
                  against.
  job graph       the schedule derived from declared read/write sets, run one
                  system at a time. Any difference from the row above is pure
                  overhead — the derived order is the same work in a different
                  sequence, and `test_jobgraph` gates the resulting world to be
                  bit-identical.
  job graph par   the same schedule with each level fanned out across threads.

The workload is shaped so the answer is not foregone: four systems write four
different components and can all run together, and two more read what those
wrote. The two readers write the SAME output component, so they conflict with
each other as well and the derived schedule is three levels of width 4, 1, 1 —
printed above the table rather than asserted here.

That shape is the point. Only four of the six systems can overlap, so Amdahl
caps the win at 2x however many cores are present, and the measured figure is
below that because a fan-out of four short systems does not reach four times
the throughput. This is the real ceiling on SYSTEM-level parallelism, and the
reason an engine that cares about throughput also parallelises WITHIN a system
(`bench_solver_scale` and `bench_workstealing` are where that is measured).

Deriving the schedule is timed separately. It is O(n^2) over the system count
and happens once at construction, not per tick, so quoting it per tick would
flatter it by a factor of however many ticks the game runs.

Run with: `mojo run -I build benchmarks/bench_jobgraph.mojo`.
"""

from std.benchmark import keep
from ecs.world import World
from ecs.storage import StorageBackend
from ecs.sparse_backend import SparseSetBackend
from ecs.component import ComponentType
from ecs.entity import Entity
from scheduler.sequential import SequentialScheduler
from scheduler.jobgraph import JobGraphScheduler, DeclaredSystem
from harness.bench import BenchTable, now

comptime N = 4000
comptime TICKS = 200

comptime M_A: UInt64 = 1 << 0
comptime M_B: UInt64 = 1 << 1
comptime M_C: UInt64 = 1 << 2
comptime M_D: UInt64 = 1 << 3
comptime M_OUT: UInt64 = 1 << 4
comptime M_NONE: UInt64 = 0


@fieldwise_init
struct CA(ComponentType):
    comptime ID: Int = 0
    var v: Int


@fieldwise_init
struct CB(ComponentType):
    comptime ID: Int = 1
    var v: Int


@fieldwise_init
struct CC(ComponentType):
    comptime ID: Int = 2
    var v: Int


@fieldwise_init
struct CD(ComponentType):
    comptime ID: Int = 3
    var v: Int


@fieldwise_init
struct COut(ComponentType):
    comptime ID: Int = 4
    var v: Int


def _churn(x: Int) -> Int:
    """Enough arithmetic per entity that the systems are not pure memory
    traffic — otherwise every row measures the allocator."""
    var h = x
    for _ in range(24):
        h = (h * 1103515245 + 12345) & 0x7FFFFFFF
    return h


struct WriteA(DeclaredSystem):
    @staticmethod
    def reads() -> UInt64:
        return M_NONE

    @staticmethod
    def writes() -> UInt64:
        return M_A

    @staticmethod
    def apply[B: StorageBackend](mut world: World[B]):
        for i in range(N):
            var e = Entity(i, 0)
            world.set(e, CA(_churn(world.get[CA](e).v)))


struct WriteB(DeclaredSystem):
    @staticmethod
    def reads() -> UInt64:
        return M_NONE

    @staticmethod
    def writes() -> UInt64:
        return M_B

    @staticmethod
    def apply[B: StorageBackend](mut world: World[B]):
        for i in range(N):
            var e = Entity(i, 0)
            world.set(e, CB(_churn(world.get[CB](e).v)))


struct WriteC(DeclaredSystem):
    @staticmethod
    def reads() -> UInt64:
        return M_NONE

    @staticmethod
    def writes() -> UInt64:
        return M_C

    @staticmethod
    def apply[B: StorageBackend](mut world: World[B]):
        for i in range(N):
            var e = Entity(i, 0)
            world.set(e, CC(_churn(world.get[CC](e).v)))


struct WriteD(DeclaredSystem):
    @staticmethod
    def reads() -> UInt64:
        return M_NONE

    @staticmethod
    def writes() -> UInt64:
        return M_D

    @staticmethod
    def apply[B: StorageBackend](mut world: World[B]):
        for i in range(N):
            var e = Entity(i, 0)
            world.set(e, CD(_churn(world.get[CD](e).v)))


struct GatherA(DeclaredSystem):
    """Reads what WriteA wrote, so it lands behind it. Both gatherers write the
    SAME output component, so they conflict with each other as well and end up
    on levels of their own — which is why the schedule is 4, 1, 1 and not 4, 2."""

    @staticmethod
    def reads() -> UInt64:
        return M_A

    @staticmethod
    def writes() -> UInt64:
        return M_OUT

    @staticmethod
    def apply[B: StorageBackend](mut world: World[B]):
        for i in range(N):
            var e = Entity(i, 0)
            world.set(e, COut(world.get[COut](e).v ^ world.get[CA](e).v))


struct GatherB(DeclaredSystem):
    @staticmethod
    def reads() -> UInt64:
        return M_B

    @staticmethod
    def writes() -> UInt64:
        return M_OUT

    @staticmethod
    def apply[B: StorageBackend](mut world: World[B]):
        for i in range(N):
            var e = Entity(i, 0)
            world.set(e, COut(world.get[COut](e).v ^ world.get[CB](e).v))


comptime BK = SparseSetBackend[CA, CB, CC, CD, COut]


def seed(mut w: World[BK]):
    for i in range(N):
        var e = w.spawn()
        w.set(e, CA(i + 1))
        w.set(e, CB(i + 2))
        w.set(e, CC(i + 3))
        w.set(e, CD(i + 4))
        w.set(e, COut(0))


def digest(w: World[BK]) -> Int:
    var h = 0
    for i in range(N):
        h = h * 31 + w.get[COut](Entity(i, 0)).v
    return h


def main() raises:
    var table = BenchTable("Automatic dependency scheduling (6 systems, 4000 entities)")

    # Derivation cost, measured on its own: once per scheduler, not per tick.
    var t0 = now()
    var built = 0
    for _ in range(1000):
        var g = JobGraphScheduler[
            BK, WriteA, WriteB, WriteC, WriteD, GatherA, GatherB
        ]()
        built += g.depth()
    keep(built)
    var t1 = now()
    table.add("derive schedule (construction only)", 6, "build", t1 - t0, 1000)

    var probe = JobGraphScheduler[
        BK, WriteA, WriteB, WriteC, WriteD, GatherA, GatherB
    ]()
    print(
        "levels:", probe.depth(),
        " width0:", probe.width(0),
        " width1:", probe.width(1),
    )

    # warm-up: the first fan-out in a process pays for pool creation
    var ww = World[BK]()
    seed(ww)
    var wg = JobGraphScheduler[
        BK, WriteA, WriteB, WriteC, WriteD, GatherA, GatherB
    ]()
    wg.parallel = True
    for _ in range(4):
        wg.tick(ww)

    var w1 = World[BK]()
    seed(w1)
    var s1 = SequentialScheduler[
        BK, WriteA, WriteB, WriteC, WriteD, GatherA, GatherB
    ]()
    var a0 = now()
    for _ in range(TICKS):
        s1.tick(w1)
    var a1 = now()
    keep(digest(w1))
    table.add("sequential", N, "tick", a1 - a0, TICKS)

    var w2 = World[BK]()
    seed(w2)
    var s2 = JobGraphScheduler[
        BK, WriteA, WriteB, WriteC, WriteD, GatherA, GatherB
    ]()
    var b0 = now()
    for _ in range(TICKS):
        s2.tick(w2)
    var b1 = now()
    keep(digest(w2))
    table.add("job graph (serial within level)", N, "tick", b1 - b0, TICKS)

    var w3 = World[BK]()
    seed(w3)
    var s3 = JobGraphScheduler[
        BK, WriteA, WriteB, WriteC, WriteD, GatherA, GatherB
    ]()
    s3.parallel = True
    var c0 = now()
    for _ in range(TICKS):
        s3.tick(w3)
    var c1 = now()
    keep(digest(w3))
    table.add("job graph (levels fanned out)", N, "tick", c1 - c0, TICKS)

    print("digests equal:", digest(w1) == digest(w2) and digest(w2) == digest(w3))
    table.print_report()
