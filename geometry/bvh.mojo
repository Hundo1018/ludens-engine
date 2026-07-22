"""A static bounding-volume hierarchy over `AABB[dim]`, dimension-generic.

Built by recursively median-splitting leaves along the widest centroid axis.
Supports region queries (all proxies whose box overlaps a query box) and
self-pair queries (all overlapping proxy pairs) — the basis of the BVH
broadphase. Nodes live in a flat `List`; children are referenced by index.
"""

from .vec import WorldType, Real, lane_min, lane_max
from .aabb import AABB
from .ray import Ray, RayHit, ray_aabb

comptime SAH_BINS = 12  # binned-SAH candidate split planes per axis


@fieldwise_init
struct _Leaf[dim: Int](Copyable, ImplicitlyCopyable, Movable):
    var box: AABB[Self.dim]
    var proxy: Int


@fieldwise_init
struct _Node[dim: Int](Copyable, ImplicitlyCopyable, Movable):
    var box: AABB[Self.dim]
    var left: Int  # child node index, or -1 for a leaf
    var right: Int  # child node index, or -1 for a leaf
    var proxy: Int  # proxy id for a leaf, else -1

    def is_leaf(self) -> Bool:
        return self.left < 0


struct BVH[dim: Int](Copyable, Movable):
    var nodes: List[_Node[Self.dim]]
    var root: Int

    def __init__(out self):
        self.nodes = List[_Node[Self.dim]]()
        self.root = -1

    def clear(mut self):
        self.nodes.clear()
        self.root = -1

    def build(mut self, var leaves: List[_Leaf[Self.dim]], sah: Bool = False):
        """Median-split along the widest centroid axis (default), or `sah` =
        binned Surface-Area-Heuristic (choose the axis + split plane of least
        SA(L)·|L| + SA(R)·|R| over SAH_BINS candidates). Both produce the same
        set of leaves and identical query answers (`test_bvh` parity); SAH
        yields a tighter tree, cheaper to traverse at the cost of a pricier
        build."""
        self.clear()
        if len(leaves) == 0:
            return
        self.root = self._build(leaves, 0, len(leaves), sah)

    def _bounds(self, leaves: List[_Leaf[Self.dim]], lo: Int, hi: Int) -> AABB[Self.dim]:
        var b = leaves[lo].box
        for i in range(lo + 1, hi):
            b = b.merge(leaves[i].box)
        return b

    def _widest_axis(self, leaves: List[_Leaf[Self.dim]], lo: Int, hi: Int) -> Int:
        var cmin = leaves[lo].box.center()
        var cmax = cmin
        for i in range(lo + 1, hi):
            var c = leaves[i].box.center()
            comptime for k in range(Self.dim):
                if c[k] < cmin[k]:
                    cmin[k] = c[k]
                if c[k] > cmax[k]:
                    cmax[k] = c[k]
        var axis = 0
        var best = cmax[0] - cmin[0]
        comptime for k in range(1, Self.dim):
            var ext = cmax[k] - cmin[k]
            if ext > best:
                best = ext
                axis = k
        return axis

    def _sort_range(mut self, mut leaves: List[_Leaf[Self.dim]], lo: Int, hi: Int, axis: Int):
        # Insertion sort the [lo, hi) range by centroid along `axis`. Fine for the
        # modest leaf counts a teaching engine handles; keeps the build simple.
        for i in range(lo + 1, hi):
            var key = leaves[i]
            var kc = key.box.center()[axis]
            var j = i - 1
            while j >= lo and leaves[j].box.center()[axis] > kc:
                leaves[j + 1] = leaves[j]
                j -= 1
            leaves[j + 1] = key

    def _sah_split(
        self, mut leaves: List[_Leaf[Self.dim]], lo: Int, hi: Int
    ) -> Int:
        """Binned SAH: pick the axis + plane minimising SA(L)·|L| + SA(R)·|R|,
        partition [lo, hi) in place, return the split index (or -1 when every
        centroid coincides / one side is empty -> caller falls back to median)."""
        var cmin = leaves[lo].box.center()
        var cmax = cmin
        for i in range(lo + 1, hi):
            var c = leaves[i].box.center()
            cmin = lane_min(cmin, c)
            cmax = lane_max(cmax, c)

        var best_cost = Real(1e30)
        var best_axis = -1
        var best_split = Real(0)
        comptime BIG = SIMD[WorldType, Self.dim](1e30)
        comptime SMALL = SIMD[WorldType, Self.dim](-1e30)
        for a in range(Self.dim):
            var extent = cmax[a] - cmin[a]
            if extent <= 0:
                continue
            var bcount = InlineArray[Int, SAH_BINS](fill=0)
            var bmin = InlineArray[SIMD[WorldType, Self.dim], SAH_BINS](fill=BIG)
            var bmax = InlineArray[SIMD[WorldType, Self.dim], SAH_BINS](
                fill=SMALL
            )
            for i in range(lo, hi):
                var c = leaves[i].box.center()[a]
                var k = Int(Real(SAH_BINS) * (c - cmin[a]) / extent)
                if k < 0:
                    k = 0
                if k >= SAH_BINS:
                    k = SAH_BINS - 1
                bcount[k] += 1
                bmin[k] = lane_min(bmin[k], leaves[i].box.min)
                bmax[k] = lane_max(bmax[k], leaves[i].box.max)
            # left prefix (bins [0..k])
            var lcount = InlineArray[Int, SAH_BINS](fill=0)
            var lmin = InlineArray[SIMD[WorldType, Self.dim], SAH_BINS](fill=BIG)
            var lmax = InlineArray[SIMD[WorldType, Self.dim], SAH_BINS](
                fill=SMALL
            )
            var acc_c = 0
            var acc_min = BIG
            var acc_max = SMALL
            for k in range(SAH_BINS):
                acc_c += bcount[k]
                acc_min = lane_min(acc_min, bmin[k])
                acc_max = lane_max(acc_max, bmax[k])
                lcount[k] = acc_c
                lmin[k] = acc_min
                lmax[k] = acc_max
            # right suffix; split between bin k-1 and k
            var r_c = 0
            var r_min = BIG
            var r_max = SMALL
            for k in range(SAH_BINS - 1, 0, -1):
                r_c += bcount[k]
                r_min = lane_min(r_min, bmin[k])
                r_max = lane_max(r_max, bmax[k])
                var lc = lcount[k - 1]
                if lc == 0 or r_c == 0:
                    continue
                var sa_l = AABB[Self.dim](lmin[k - 1], lmax[k - 1]).surface_area()
                var sa_r = AABB[Self.dim](r_min, r_max).surface_area()
                var cost = sa_l * Real(lc) + sa_r * Real(r_c)
                if cost < best_cost:
                    best_cost = cost
                    best_axis = a
                    best_split = cmin[a] + extent * Real(k) / Real(SAH_BINS)

        if best_axis < 0:
            return -1
        # partition in place: centroid on the chosen axis left of the plane
        var mid = lo
        for i in range(lo, hi):
            if leaves[i].box.center()[best_axis] < best_split:
                var tmp = leaves[i]
                leaves[i] = leaves[mid]
                leaves[mid] = tmp
                mid += 1
        if mid == lo or mid == hi:
            return -1
        return mid

    def _build(
        mut self, mut leaves: List[_Leaf[Self.dim]], lo: Int, hi: Int, sah: Bool
    ) -> Int:
        var box = self._bounds(leaves, lo, hi)
        if hi - lo == 1:
            self.nodes.append(_Node[Self.dim](box, -1, -1, leaves[lo].proxy))
            return len(self.nodes) - 1

        var mid = -1
        if sah:
            mid = self._sah_split(leaves, lo, hi)
        if mid < 0:  # median (default, or SAH degenerate fallback)
            var axis = self._widest_axis(leaves, lo, hi)
            self._sort_range(leaves, lo, hi, axis)
            mid = (lo + hi) // 2
        var left = self._build(leaves, lo, mid, sah)
        var right = self._build(leaves, mid, hi, sah)
        self.nodes.append(_Node[Self.dim](box, left, right, -1))
        return len(self.nodes) - 1

    def build_boxes(
        mut self, boxes: List[AABB[Self.dim]], proxies: List[Int],
        sah: Bool = False,
    ):
        """Build from parallel (box, proxy) lists — keeps `_Leaf` private to this module."""
        var leaves = List[_Leaf[Self.dim]]()
        for i in range(len(boxes)):
            leaves.append(_Leaf[Self.dim](boxes[i], proxies[i]))
        self.build(leaves^, sah)

    def raycast(self, ray: Ray[Self.dim]) -> RayHit[Self.dim]:
        """Nearest proxy the ray hits, found by descending only nodes the ray enters."""
        var best = RayHit[Self.dim].miss()
        var best_t = ray.max_t
        if self.root >= 0:
            self._raycast(self.root, ray, best, best_t)
        return best

    def _raycast(
        self,
        node: Int,
        ray: Ray[Self.dim],
        mut best: RayHit[Self.dim],
        mut best_t: Real,
    ):
        var n = self.nodes[node]
        var bh = ray_aabb(ray, n.box)
        if not bh.hit or bh.t > best_t:
            return
        if n.is_leaf():
            if bh.t <= best_t:
                best_t = bh.t
                best = RayHit[Self.dim](True, bh.t, n.proxy, bh.normal)
            return
        self._raycast(n.left, ray, best, best_t)
        self._raycast(n.right, ray, best, best_t)

    def query_region(self, box: AABB[Self.dim], mut out: List[Int]):
        if self.root < 0:
            return
        self._query(self.root, box, out)

    def _query(self, node: Int, box: AABB[Self.dim], mut out: List[Int]):
        var n = self.nodes[node]
        if not n.box.overlaps(box):
            return
        if n.is_leaf():
            out.append(n.proxy)
            return
        self._query(n.left, box, out)
        self._query(n.right, box, out)

    def cost(self) -> Real:
        """Σ node AABB surface area — the tree-tightness metric the SAH build
        minimises (leaf areas are identical across builds, so a lower total
        means tighter internal nodes and cheaper traversal)."""
        var s = Real(0)
        for i in range(len(self.nodes)):
            s += self.nodes[i].box.surface_area()
        return s

    def _depth_sum(self, node: Int, d: Int) -> Int:
        var n = self.nodes[node]
        if n.is_leaf():
            return d
        return self._depth_sum(n.left, d + 1) + self._depth_sum(n.right, d + 1)

    def avg_leaf_depth(self) -> Real:
        """Mean root-to-leaf depth (lower/flatter = fewer nodes per query)."""
        if self.root < 0:
            return 0
        var nleaf = 0
        for i in range(len(self.nodes)):
            if self.nodes[i].is_leaf():
                nleaf += 1
        if nleaf == 0:
            return 0
        return Real(self._depth_sum(self.root, 0)) / Real(nleaf)
