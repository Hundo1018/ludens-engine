"""Automatic dependency scheduling: systems declare what they touch, the
scheduler works out what may run at the same time.

`SequentialScheduler` runs systems in registration order; `EntityActorScheduler`
runs them in parallel because the programmer said so. Both put the burden of
correctness on the person writing the registration list: get the order wrong and
a system reads a component before its producer has written it, and nothing
reports the mistake — the world is merely wrong, quietly, on some frames.

Here a system declares its component READ and WRITE sets as bitmasks over
`ComponentType.ID`, and the schedule is derived from them. Two systems conflict
when one writes something the other reads or writes:

    W_i & (R_j | W_j)   read-after-write and write-after-write
    W_j & R_i           write-after-read

Systems that conflict are put on different levels, in registration order.
Systems that do not conflict share a level and may run simultaneously, in any
order, because by construction no two of them touch the same component with a
write. That is what makes the result BIT-IDENTICAL to the sequential scheduler
rather than merely equivalent: within a level the outcome cannot depend on
order, so there is no reordering to observe.

The declaration is the honest weak point and it is worth stating: nothing here
verifies that a system's `reads`/`writes` match what its `apply` actually does.
A wrong declaration produces a wrong schedule, and this is the same trade every
DOTS-style scheduler makes. What it buys is that the dependency is written down
once, next to the system, instead of being implied by a list order somewhere
else.
"""

from std.algorithm import parallelize
from ecs.world import World
from ecs.storage import StorageBackend
from .scheduler import Scheduler, System


trait DeclaredSystem(System):
    """A `System` that also declares the components it touches.

    Masks are `1 << ComponentType.ID`, so a world may carry 64 component types
    before this needs widening — well past the point where a hand-written
    ordering would still be maintainable, which is the situation it is for."""

    @staticmethod
    def reads() -> UInt64: ...

    @staticmethod
    def writes() -> UInt64: ...


def conflicts(rw_a: Tuple[UInt64, UInt64], rw_b: Tuple[UInt64, UInt64]) -> Bool:
    """Do two (reads, writes) declarations force an ordering?

    Note that read-read is NOT a conflict, which is the whole point: any number
    of systems may read the same component in parallel."""
    var ra = rw_a[0]
    var wa = rw_a[1]
    var rb = rw_b[0]
    var wb = rw_b[1]
    return (wa & (rb | wb)) != 0 or (wb & ra) != 0


struct JobGraphScheduler[Bk: StorageBackend, *Systems: DeclaredSystem](
    Scheduler
):
    comptime B = Self.Bk

    var level: List[Int]  # per system
    var order: List[Int]  # system indices, grouped by level
    var lo: List[Int]  # per level, start index into `order`
    var hi: List[Int]
    var parallel: Bool
    var workers: Int

    def __init__(out self):
        self.parallel = False
        self.workers = 0
        self.level = List[Int]()
        self.order = List[Int]()
        self.lo = List[Int]()
        self.hi = List[Int]()
        self._build()

    def _build(mut self):
        """Longest-path levelling. A system sits one level below the latest
        system it conflicts with, so the level count is the length of the
        longest dependency chain — the best a correct schedule can do."""
        comptime N = len(Self.Systems)
        var n = N
        var reads = List[UInt64](capacity=N)
        var writes = List[UInt64](capacity=N)
        comptime for i in range(N):
            comptime Sys = Self.Systems[i]
            reads.append(Sys.reads())
            writes.append(Sys.writes())

        self.level = List[Int](capacity=n)
        var depth = 0
        for j in range(n):
            var lv = 0
            for i in range(j):
                if conflicts(
                    (reads[i], writes[i]), (reads[j], writes[j])
                ) and self.level[i] >= lv:
                    lv = self.level[i] + 1
            self.level.append(lv)
            if lv + 1 > depth:
                depth = lv + 1

        self.order = List[Int](capacity=n)
        self.lo = List[Int](capacity=depth)
        self.hi = List[Int](capacity=depth)
        for lv in range(depth):
            self.lo.append(len(self.order))
            for j in range(n):
                if self.level[j] == lv:
                    self.order.append(j)
            self.hi.append(len(self.order))

    def depth(self) -> Int:
        """Number of levels: the length of the longest dependency chain, and
        the lower bound on how many sequential phases a tick must have."""
        return len(self.lo)

    def width(self, lv: Int) -> Int:
        """How many systems may run at once on level `lv`."""
        return self.hi[lv] - self.lo[lv]

    def level_of(self, i: Int) -> Int:
        return self.level[i]

    def tick(mut self, mut world: World[Self.B]):
        for lv in range(len(self.lo)):
            if self.parallel and self.width(lv) > 1:
                _run_level[Self.B, *Self.Systems](
                    world, self.order, self.lo[lv], self.hi[lv], self.workers
                )
            else:
                for k in range(self.lo[lv], self.hi[lv]):
                    _run_one[Self.B, *Self.Systems](world, self.order[k])


def _run_one[
    B: StorageBackend, *Systems: DeclaredSystem
](mut world: World[B], idx: Int):
    """Dispatch a RUNTIME system index into a COMPTIME system pack.

    The pack cannot be indexed with a runtime value, so the comparison chain is
    unrolled at compile time and collapses to a switch. This is the price of
    deciding the order at run time while keeping the systems statically
    dispatched — no boxing, no virtual call."""
    comptime for i in range(len(Systems)):
        if i == idx:
            comptime Sys = Systems[i]
            Sys.apply[B](world)


def _run_level[
    B: StorageBackend, *Systems: DeclaredSystem
](
    mut world: World[B], order: List[Int], lo: Int, hi: Int, workers: Int
):
    """Fan out one level. A free function so the closure captures `world` as an
    ordinary argument, following the precedent in `_solve_islands_parallel`.

    Safety here is structural, not incidental: everything in a level was placed
    there because it conflicts with nothing else in it, so no two of these
    systems write the same component."""

    @parameter
    def level_work(k: Int):
        _run_one[B, *Systems](world, order[lo + k])

    if workers > 0:
        parallelize[level_work](hi - lo, workers)
    else:
        parallelize[level_work](hi - lo)
