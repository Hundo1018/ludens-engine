"""Persistent (incremental) BVH broadphase: the frame-coherent path.

Every other `BroadPhase` implementation rebuilds from scratch each frame; this
one keeps a dynamic tree of FAT (margin-inflated) AABBs across frames, Box2D
dynamic-tree style:

  * `rebuild(items)` is INCREMENTAL: a proxy is touched only when its tight
    box escapes its stored fat box — the leaf is removed, re-inserted (best
    sibling by a surface heuristic) with a fresh fat box, and the PAIR CACHE
    is repaired locally (drop pairs involving movers, re-query movers).
  * The cache invariant: it holds every FAT-overlap pair. Two un-moved
    proxies' tight boxes can only overlap if their fat boxes do, so emitting
    with a tight-overlap filter reproduces the BruteForce pair set exactly
    (`test_dbvh` parity), while frames where nothing escapes its margin cost
    near zero tree work (`bench_dbvh` vs the rebuild path).

No balancing rotations (coherent scenes keep the tree adequate); a shrinking
proxy set resets the tree.
"""

from geometry.aabb import AABB
from geometry.vec import WorldType, Real
from .broadphase import BroadPhase, Pair, BoxProxy

comptime _MARGIN: Real = 0.1


def _fatten[D: Int](b: AABB[D]) -> AABB[D]:
    return AABB[D](b.min - _MARGIN, b.max + _MARGIN)


def _union[D: Int](a: AABB[D], b: AABB[D]) -> AABB[D]:
    return AABB[D](min(a.min, b.min), max(a.max, b.max))


def _cost[D: Int](b: AABB[D]) -> Real:
    """Surface heuristic: total extent (dimension-generic 'perimeter')."""
    var e = b.max - b.min
    var c = Real(0)
    comptime for k in range(D):
        c += e[k]
    return c


def _contains[D: Int](outer: AABB[D], inner: AABB[D]) -> Bool:
    comptime for k in range(D):
        if inner.min[k] < outer.min[k] or inner.max[k] > outer.max[k]:
            return False
    return True


@fieldwise_init
struct _Node[dim: Int](Copyable, ImplicitlyCopyable, Movable):
    var fat: AABB[Self.dim]
    var parent: Int
    var left: Int  # -1 => leaf
    var right: Int
    var proxy: Int  # payload for leaves, -1 for internal


struct DbvhBroadPhase[D: Int](BroadPhase):
    comptime dim: Int = Self.D
    var nodes: List[_Node[Self.D]]
    var free: List[Int]
    var root: Int
    var leaf_of: List[Int]  # proxy -> node index (-1 = absent)
    var tight: List[BoxProxy[Self.D]]  # proxy -> current tight box
    var cache: List[Pair]  # all FAT-overlap pairs
    var count: Int

    def __init__(out self):
        self.nodes = List[_Node[Self.D]]()
        self.free = List[Int]()
        self.root = -1
        self.leaf_of = List[Int]()
        self.tight = List[BoxProxy[Self.D]]()
        self.cache = List[Pair]()
        self.count = 0

    def _alloc(mut self, node: _Node[Self.D]) -> Int:
        if len(self.free) > 0:
            var i = self.free[len(self.free) - 1]
            _ = self.free.pop()
            self.nodes[i] = node
            return i
        self.nodes.append(node)
        return len(self.nodes) - 1

    def _refit_up(mut self, start: Int):
        var i = start
        while i != -1:
            var l = self.nodes[i].left
            var r = self.nodes[i].right
            if l != -1:
                var u = _union[Self.D](self.nodes[l].fat, self.nodes[r].fat)
                var n = self.nodes[i]
                n.fat = u
                self.nodes[i] = n
            i = self.nodes[i].parent

    def _insert_leaf(mut self, leaf: Int):
        if self.root == -1:
            self.root = leaf
            var n = self.nodes[leaf]
            n.parent = -1
            self.nodes[leaf] = n
            return
        # descend to the best sibling by the combined-surface heuristic
        var box = self.nodes[leaf].fat
        var i = self.root
        while self.nodes[i].left != -1:
            var l = self.nodes[i].left
            var r = self.nodes[i].right
            var cl = _cost[Self.D](_union[Self.D](self.nodes[l].fat, box))
            var cr = _cost[Self.D](_union[Self.D](self.nodes[r].fat, box))
            i = l if cl < cr else r
        # make a new internal parent for (sibling i, leaf)
        var old_parent = self.nodes[i].parent
        var np = self._alloc(
            _Node[Self.D](
                _union[Self.D](self.nodes[i].fat, box), old_parent, i, leaf, -1
            )
        )
        var ni = self.nodes[i]
        ni.parent = np
        self.nodes[i] = ni
        var nl = self.nodes[leaf]
        nl.parent = np
        self.nodes[leaf] = nl
        if old_parent == -1:
            self.root = np
        else:
            var op = self.nodes[old_parent]
            if op.left == i:
                op.left = np
            else:
                op.right = np
            self.nodes[old_parent] = op
        self._refit_up(np)

    def _remove_leaf(mut self, leaf: Int):
        if self.root == leaf:
            self.root = -1
            return
        var parent = self.nodes[leaf].parent
        var sib = self.nodes[parent].left
        if sib == leaf:
            sib = self.nodes[parent].right
        var grand = self.nodes[parent].parent
        var ns = self.nodes[sib]
        ns.parent = grand
        self.nodes[sib] = ns
        if grand == -1:
            self.root = sib
        else:
            var g = self.nodes[grand]
            if g.left == parent:
                g.left = sib
            else:
                g.right = sib
            self.nodes[grand] = g
            self._refit_up(grand)
        self.free.append(parent)

    def _query_fat(self, box: AABB[Self.D], mut out: List[Int]):
        if self.root == -1:
            return
        var stack = List[Int]()
        stack.append(self.root)
        while len(stack) > 0:
            var i = stack[len(stack) - 1]
            _ = stack.pop()
            if not self.nodes[i].fat.overlaps(box):
                continue
            if self.nodes[i].left == -1:
                out.append(self.nodes[i].proxy)
            else:
                stack.append(self.nodes[i].left)
                stack.append(self.nodes[i].right)

    def _reset(mut self):
        self.nodes = List[_Node[Self.D]]()
        self.free = List[Int]()
        self.root = -1
        self.leaf_of = List[Int]()
        self.tight = List[BoxProxy[Self.D]]()
        self.cache = List[Pair]()
        self.count = 0

    def rebuild(mut self, items: List[BoxProxy[Self.D]]) raises:
        if len(items) < self.count:
            self._reset()  # shrinking proxy set: start over
        self.count = len(items)
        # ensure proxy-indexed slots
        var maxp = 0
        for i in range(len(items)):
            if items[i].proxy > maxp:
                maxp = items[i].proxy
        while len(self.leaf_of) <= maxp:
            self.leaf_of.append(-1)
            self.tight.append(
                BoxProxy[Self.D](-1, AABB[Self.D](0, 0))
            )
        var moved = List[Int]()
        for i in range(len(items)):
            var p = items[i].proxy
            self.tight[p] = items[i]
            var leaf = self.leaf_of[p]
            if leaf == -1:
                var idx = self._alloc(
                    _Node[Self.D](_fatten[Self.D](items[i].box), -1, -1, -1, p)
                )
                self.leaf_of[p] = idx
                self._insert_leaf(idx)
                moved.append(p)
            elif not _contains[Self.D](self.nodes[leaf].fat, items[i].box):
                self._remove_leaf(leaf)
                var n = self.nodes[leaf]
                n.fat = _fatten[Self.D](items[i].box)
                n.parent = -1
                self.nodes[leaf] = n
                self._insert_leaf(leaf)
                moved.append(p)
        if len(moved) == 0:
            return
        # repair the pair cache locally: drop movers' pairs, re-query movers
        var is_moved = List[Bool]()
        for _ in range(len(self.leaf_of)):
            is_moved.append(False)
        for i in range(len(moved)):
            is_moved[moved[i]] = True
        var kept = List[Pair]()
        for c in range(len(self.cache)):
            if not is_moved[self.cache[c].a] and not is_moved[self.cache[c].b]:
                kept.append(self.cache[c])
        for i in range(len(moved)):
            var p = moved[i]
            var leaf = self.leaf_of[p]
            var cands = List[Int]()
            self._query_fat(self.nodes[leaf].fat, cands)
            for k in range(len(cands)):
                var q = cands[k]
                if q == p:
                    continue
                # both moved: let the smaller endpoint own the pair
                if is_moved[q] and q < p:
                    continue
                kept.append(Pair(min(p, q), max(p, q)))
        self.cache = kept^

    def pairs(self, mut out: List[Pair]) raises:
        # cache holds fat-overlap pairs; emit with the exact tight filter
        for c in range(len(self.cache)):
            var a = self.cache[c].a
            var b = self.cache[c].b
            if self.tight[a].box.overlaps(self.tight[b].box):
                out.append(Pair(a, b))

    def query_region(self, box: AABB[Self.D], mut out: List[Int]) raises:
        var cands = List[Int]()
        self._query_fat(box, cands)
        for k in range(len(cands)):
            if self.tight[cands[k]].box.overlaps(box):
                out.append(cands[k])
