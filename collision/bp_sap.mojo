"""Sweep and Prune: the sorted-endpoint broadphase (Box2D/Bullet lineage).

Boxes are projected onto one axis and their intervals kept in a SORTED order.
Pairs come from a single sweep: walk the order, keep the set of intervals still
open, and emit a candidate whenever a new interval opens inside them. That
turns the O(n²) all-pairs test into O(n log n + k) for the first frame and,
crucially, into something much cheaper afterwards.

The "afterwards" is the whole point and is why this exists next to the DBVH.
Physics scenes have TEMPORAL COHERENCE: between two frames a body barely moves,
so last frame's sorted order is almost the right answer. Re-sorting it with an
INSERTION SORT costs O(n + inversions) — effectively linear when nothing
teleports — instead of re-deriving a structure from scratch. `rebuild` therefore
keeps its previous order and repairs it, and the benchmark's fast/slow motion
rows are exactly the axis where that assumption is tested to destruction.

Axis choice matters: SAP degenerates when many intervals overlap along the
sweep axis (a wall of boxes stacked across it), so the axis with the greatest
centre spread is picked per rebuild — the standard cheap heuristic.

Result parity: the emitted pair SET equals brute force's (`test_sap`), the same
contract every other `BroadPhase` implementation satisfies. Order is not part
of that contract — callers that need determinism sort, as `solver6` does.
"""

from geometry.aabb import AABB
from geometry.vec import Real
from .broadphase import BroadPhase, Pair, BoxProxy


struct SapBroadPhase[D: Int](BroadPhase):
    comptime dim: Int = Self.D
    var items: List[BoxProxy[Self.D]]
    var order: List[Int]  # indices into `items`, sorted by interval min
    var axis: Int

    def __init__(out self):
        self.items = List[BoxProxy[Self.D]]()
        self.order = List[Int]()
        self.axis = 0

    def _spread_axis(self) -> Int:
        """Axis with the widest spread of box centres: the one that separates
        the intervals best, so the sweep's active set stays small."""
        var best_axis = 0
        var best = Real(-1)
        for d in range(Self.D):
            var lo = Real(1e30)
            var hi = Real(-1e30)
            for ref it in self.items:
                var c = (it.box.min[d] + it.box.max[d]) * 0.5
                if c < lo:
                    lo = c
                if c > hi:
                    hi = c
            var s = hi - lo
            if s > best:
                best = s
                best_axis = d
        return best_axis

    def rebuild(mut self, items: List[BoxProxy[Self.D]]) raises:
        var n = len(items)
        # Keep the previous permutation when the population is unchanged: that
        # is what makes the insertion sort below O(n) under coherence. Any
        # change in count resets to identity (a fresh sort).
        var reuse = len(self.order) == n
        self.items = items.copy()
        if not reuse:
            self.order = List[Int]()
            for i in range(n):
                self.order.append(i)
        self.axis = self._spread_axis()

        # Insertion sort on the (nearly sorted) order by interval minimum.
        var a = self.axis
        for i in range(1, n):
            var v = self.order[i]
            var key = self.items[v].box.min[a]
            var j = i - 1
            while j >= 0 and self.items[self.order[j]].box.min[a] > key:
                self.order[j + 1] = self.order[j]
                j -= 1
            self.order[j + 1] = v

    def pairs(self, mut out: List[Pair]) raises:
        var n = len(self.order)
        var a = self.axis
        # Sweep: `active` holds intervals whose max is still ahead of the
        # current interval's min. Anything else can never overlap again on this
        # axis, so it is dropped and never re-examined.
        var active = List[Int]()
        for oi in range(n):
            var i = self.order[oi]
            var lo = self.items[i].box.min[a]
            # retire finished intervals
            var k = 0
            while k < len(active):
                if self.items[active[k]].box.max[a] < lo:
                    active[k] = active[len(active) - 1]
                    _ = active.pop()
                else:
                    k += 1
            # everything still open overlaps on the sweep axis: test the rest
            for k2 in range(len(active)):
                var j = active[k2]
                if self.items[i].box.overlaps(self.items[j].box):
                    out.append(Pair(self.items[i].proxy, self.items[j].proxy))
            active.append(i)

    def query_region(self, box: AABB[Self.D], mut out: List[Int]) raises:
        # The sorted order gives an early exit: once an interval starts beyond
        # the query's max on the sweep axis, no later one can overlap.
        var a = self.axis
        var hi = box.max[a]
        for oi in range(len(self.order)):
            var i = self.order[oi]
            if self.items[i].box.min[a] > hi:
                break
            if self.items[i].box.overlaps(box):
                out.append(self.items[i].proxy)
