"""Fixed-timestep driver: step counting, accumulation, and the spiral-of-death cap.

Drives a `SequentialScheduler` whose only system increments a counter component,
so the number of fixed ticks is directly observable as the counter value.
"""

from harness.runner import Suite
from ecs.world import World
from ecs.storage import StorageBackend
from ecs.sparse_backend import SparseSetBackend
from ecs.component import ComponentType
from scheduler.scheduler import System
from scheduler.sequential import SequentialScheduler
from scheduler.gameloop import FixedLoop


@fieldwise_init
struct Tick(ComponentType):
    comptime ID: Int = 0
    var n: Int


struct CountSystem(System):
    @staticmethod
    def apply[B: StorageBackend](mut w: World[B]):
        var es = w.query1[Tick]()
        for i in range(len(es)):
            var t = w.get[Tick](es[i])
            w.set(es[i], Tick(t.n + 1))


comptime Bk = SparseSetBackend[Tick]
comptime Sched = SequentialScheduler[SparseSetBackend[Tick], CountSystem]


def fresh() -> World[Bk]:
    var w = World[Bk]()
    var e = w.spawn()
    w.set(e, Tick(0))
    return w^


def main() raises:
    var s = Suite("gameloop")
    comptime DT = 1.0 / 60.0

    # 0.05s of frame time -> exactly 3 fixed steps at 1/60
    var w1 = fresh()
    var sc1 = Sched()
    var loop1 = FixedLoop.new(DT, 8)
    var n1 = loop1.advance(sc1, w1, 0.05)
    s.eqi(n1, 3, "0.05s -> 3 steps")
    s.eqi(w1.query1[Tick]()[0].id, 0, "single entity id 0")  # sanity on the entity
    s.eqi(w1.get[Tick](w1.query1[Tick]()[0]).n, 3, "3 ticks applied")
    s.check(loop1.alpha >= 0.0 and loop1.alpha < 1.0, "alpha in [0,1)")

    # spiral-of-death: a huge frame is clamped to max_steps
    var w2 = fresh()
    var sc2 = Sched()
    var loop2 = FixedLoop.new(DT, 8)
    var n2 = loop2.advance(sc2, w2, 10.0)
    s.eqi(n2, 8, "huge frame clamped to max_steps")
    s.eqi(w2.get[Tick](w2.query1[Tick]()[0]).n, 8, "8 ticks applied")

    # accumulation across many calls of exactly DT -> one step each
    var w3 = fresh()
    var sc3 = Sched()
    var loop3 = FixedLoop.new(DT, 8)
    var total = 0
    for _ in range(600):
        total += loop3.advance(sc3, w3, DT)
    s.eqi(total, 600, "600 * DT -> 600 steps")
    s.eqi(w3.get[Tick](w3.query1[Tick]()[0]).n, 600, "600 ticks applied")

    # sub-step frames accumulate but don't tick until a whole DT is reached
    var w4 = fresh()
    var sc4 = Sched()
    var loop4 = FixedLoop.new(DT, 8)
    var half = DT * 0.5
    var n4a = loop4.advance(sc4, w4, half)
    s.eqi(n4a, 0, "half-step -> 0 ticks")
    var n4b = loop4.advance(sc4, w4, half)
    s.eqi(n4b, 1, "two half-steps -> 1 tick")

    s.finish()
