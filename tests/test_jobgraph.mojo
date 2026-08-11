"""Automatic dependency scheduling (architecture law v3).

The claim is that a schedule derived from declared read/write sets produces the
same world as running the systems in registration order — bit for bit, not
approximately — while allowing independent systems to run at the same time.

ORDINARY    the conflict rule itself: read-after-write, write-after-write and
            write-after-read force an order; read-read does not. And the levels
            that fall out of it are the ones a person would draw by hand.
INTEGRATION the derived schedule produces the identical world as
            `SequentialScheduler`, on more than one storage backend, running
            serially AND fanned out across threads — so neither the derivation
            nor the parallelism changes the answer.
EXTREME     no systems at all, one system, every system conflicting with every
            other (a fully serial chain), no system conflicting with any other
            (one level), a system that declares nothing, and a system that
            declares everything.
"""

from harness.runner import Suite
from ecs.world import World
from ecs.storage import StorageBackend
from ecs.sparse_backend import SparseSetBackend
from ecs.archetype import ArchetypeBackend
from ecs.component import ComponentType
from ecs.entity import Entity
from scheduler.sequential import SequentialScheduler
from scheduler.jobgraph import JobGraphScheduler, DeclaredSystem, conflicts

comptime N = 32
comptime FRAMES = 4

# The backends are themselves parameterized by their component pack, and the
# schedules below that never touch a World give inference nothing to work from,
# so both are bound explicitly once here.
comptime M_NONE: UInt64 = 0
comptime M_ALL: UInt64 = 0xFFFFFFFFFFFFFFFF
comptime M_POS: UInt64 = 1 << 0
comptime M_VEL: UInt64 = 1 << 1
comptime M_HP: UInt64 = 1 << 2
comptime M_SCORE: UInt64 = 1 << 3


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


@fieldwise_init
struct Health(ComponentType):
    comptime ID: Int = 2
    var hp: Int


@fieldwise_init
struct Score(ComponentType):
    comptime ID: Int = 3
    var pts: Int


struct Integrate(DeclaredSystem):
    """pos += vel. Writes Position, reads Velocity."""

    @staticmethod
    def reads() -> UInt64:
        return M_VEL

    @staticmethod
    def writes() -> UInt64:
        return M_POS

    @staticmethod
    def apply[B: StorageBackend](mut world: World[B]):
        for i in range(N):
            var e = Entity(i, 0)
            var p = world.get[Position](e)
            var v = world.get[Velocity](e)
            world.set(e, Position(p.x + v.dx, p.y + v.dy))


struct Drag(DeclaredSystem):
    """vel -= 1 while positive. Writes Velocity — so it MUST NOT share a level
    with Integrate, which reads it."""

    @staticmethod
    def reads() -> UInt64:
        return M_NONE

    @staticmethod
    def writes() -> UInt64:
        return M_VEL

    @staticmethod
    def apply[B: StorageBackend](mut world: World[B]):
        for i in range(N):
            var e = Entity(i, 0)
            var v = world.get[Velocity](e)
            world.set(e, Velocity(v.dx - 1 if v.dx > 0 else v.dx, v.dy))


struct Decay(DeclaredSystem):
    """hp -= 1. Touches nothing else, so it may run beside anything."""

    @staticmethod
    def reads() -> UInt64:
        return M_NONE

    @staticmethod
    def writes() -> UInt64:
        return M_HP

    @staticmethod
    def apply[B: StorageBackend](mut world: World[B]):
        for i in range(N):
            var e = Entity(i, 0)
            world.set(e, Health(world.get[Health](e).hp - 1))


struct Award(DeclaredSystem):
    """score += hp, reading Health. Read-read with Decay would be fine; this is
    read-after-WRITE, so it is ordered behind Decay."""

    @staticmethod
    def reads() -> UInt64:
        return M_HP

    @staticmethod
    def writes() -> UInt64:
        return M_SCORE

    @staticmethod
    def apply[B: StorageBackend](mut world: World[B]):
        for i in range(N):
            var e = Entity(i, 0)
            var s = world.get[Score](e)
            world.set(e, Score(s.pts + world.get[Health](e).hp))


struct ReadOnlyA(DeclaredSystem):
    @staticmethod
    def reads() -> UInt64:
        return M_POS

    @staticmethod
    def writes() -> UInt64:
        return M_NONE

    @staticmethod
    def apply[B: StorageBackend](mut world: World[B]):
        pass


struct ReadOnlyB(DeclaredSystem):
    @staticmethod
    def reads() -> UInt64:
        return M_POS

    @staticmethod
    def writes() -> UInt64:
        return M_NONE

    @staticmethod
    def apply[B: StorageBackend](mut world: World[B]):
        pass


struct TouchesNothing(DeclaredSystem):
    @staticmethod
    def reads() -> UInt64:
        return M_NONE

    @staticmethod
    def writes() -> UInt64:
        return M_NONE

    @staticmethod
    def apply[B: StorageBackend](mut world: World[B]):
        pass


struct TouchesEverything(DeclaredSystem):
    @staticmethod
    def reads() -> UInt64:
        return M_ALL

    @staticmethod
    def writes() -> UInt64:
        return M_ALL

    @staticmethod
    def apply[B: StorageBackend](mut world: World[B]):
        pass


comptime SPARSE = SparseSetBackend[Position, Velocity, Health, Score]
comptime ARCH = ArchetypeBackend[Position, Velocity, Health, Score]


def _seed[B: StorageBackend](mut world: World[B]):
    for i in range(N):
        var e = world.spawn()
        world.set(e, Position(i, 0))
        world.set(e, Velocity(3, 1))
        world.set(e, Health(100))
        world.set(e, Score(0))


def _digest[B: StorageBackend](world: World[B]) -> Int:
    """One number covering every component of every entity, so a parity check
    cannot pass by looking at the field that happens to agree."""
    var h = 0
    for i in range(N):
        var e = Entity(i, 0)
        h = h * 31 + world.get[Position](e).x
        h = h * 31 + world.get[Position](e).y
        h = h * 31 + world.get[Velocity](e).dx
        h = h * 31 + world.get[Health](e).hp
        h = h * 31 + world.get[Score](e).pts
    return h


def run_seq[B: StorageBackend]() -> Int:
    var w = World[B]()
    _seed(w)
    var s = SequentialScheduler[B, Integrate, Drag, Decay, Award]()
    for _ in range(FRAMES):
        s.tick(w)
    return _digest(w)


def run_graph[B: StorageBackend](parallel: Bool, workers: Int) -> Int:
    var w = World[B]()
    _seed(w)
    var s = JobGraphScheduler[B, Integrate, Drag, Decay, Award]()
    s.parallel = parallel
    s.workers = workers
    for _ in range(FRAMES):
        s.tick(w)
    return _digest(w)


def main() raises:
    var s = Suite("jobgraph")

    # ---- ORDINARY: the conflict rule ----
    s.check(
        not conflicts((M_POS, M_NONE), (M_POS, M_NONE)),
        "read-read is not a conflict: any number of readers may share a level",
    )
    s.check(conflicts((M_NONE, M_POS), (M_POS, M_NONE)), "write-then-read conflicts")
    s.check(conflicts((M_POS, M_NONE), (M_NONE, M_POS)), "read-then-write conflicts")
    s.check(conflicts((M_NONE, M_POS), (M_NONE, M_POS)), "write-write conflicts")
    s.check(not conflicts((M_POS, M_VEL), (M_HP, M_SCORE)), "disjoint sets do not")
    s.check(not conflicts((M_NONE, M_NONE), (M_ALL, M_ALL)),
            "a system that touches nothing conflicts with nothing")

    # ---- ORDINARY: the levels that fall out ----
    var g = JobGraphScheduler[SPARSE, Integrate, Drag, Decay, Award]()
    print(
        "  levels — Integrate", g.level_of(0), " Drag", g.level_of(1),
        " Decay", g.level_of(2), " Award", g.level_of(3),
        " depth", g.depth(),
    )
    s.eqi(g.level_of(0), 0, "Integrate has nothing before it")
    s.eqi(g.level_of(1), 1, "Drag writes Velocity that Integrate read: ordered after")
    s.eqi(g.level_of(2), 0, "Decay touches only Health: it runs beside Integrate")
    s.eqi(g.level_of(3), 1, "Award reads Health that Decay wrote: ordered after")
    s.eqi(g.depth(), 2, "the longest chain is two systems long")
    s.eqi(g.width(0), 2, "two systems run together on the first level")
    s.eqi(g.width(1), 2, "and two on the second")

    # ---- INTEGRATION: same world as the sequential baseline ----
    var seq_sparse = run_seq[SPARSE]()
    var gph_sparse = run_graph[SPARSE](False, 0)
    var par_sparse = run_graph[SPARSE](True, 4)
    var par1_sparse = run_graph[SPARSE](True, 1)
    print("  sparse digests — seq", seq_sparse, " graph", gph_sparse,
          " parallel", par_sparse)
    s.eqi(gph_sparse, seq_sparse, "the derived schedule == registration order")
    s.eqi(par_sparse, seq_sparse, "and it is unchanged when the levels fan out")
    s.eqi(par1_sparse, seq_sparse, "and unchanged at one worker")

    var seq_arch = run_seq[ARCH]()
    var gph_arch = run_graph[ARCH](False, 0)
    var par_arch = run_graph[ARCH](True, 4)
    s.eqi(gph_arch, seq_arch, "same on the archetype backend")
    s.eqi(par_arch, seq_arch, "same on the archetype backend, fanned out")
    s.eqi(seq_arch, seq_sparse, "and the two backends agree with each other")

    # ---- EXTREME ----
    var empty = JobGraphScheduler[SPARSE]()
    s.eqi(empty.depth(), 0, "no systems: no levels")
    var w0 = World[SPARSE]()
    empty.tick(w0)  # must not crash
    s.check(True, "ticking an empty schedule is a no-op")

    var one = JobGraphScheduler[SPARSE, Decay]()
    s.eqi(one.depth(), 1, "one system: one level")
    s.eqi(one.width(0), 1, "of width one")

    # everything conflicts with everything: a fully serial chain
    var chain = JobGraphScheduler[
        SPARSE, TouchesEverything, TouchesEverything,
        TouchesEverything,
    ]()
    s.eqi(chain.depth(), 3, "all-conflicting systems serialise completely")
    for k in range(3):
        s.eqi(chain.width(k), 1, "each on its own level")

    # nothing conflicts: one wide level
    var wide = JobGraphScheduler[
        SPARSE, ReadOnlyA, ReadOnlyB, TouchesNothing
    ]()
    s.eqi(wide.depth(), 1, "readers and a no-op share one level")
    s.eqi(wide.width(0), 3, "all three of them")

    # a system that touches nothing must not be pushed behind one that touches
    # everything, even when registered after it
    var mixed = JobGraphScheduler[
        SPARSE, TouchesEverything, TouchesNothing
    ]()
    s.eqi(mixed.depth(), 1, "a no-op system never inherits a dependency")

    s.finish()
