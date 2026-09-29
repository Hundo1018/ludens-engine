"""BVH broadphase (dimension-generic): rebuilds a `BVH[dim]` from the frame's
boxes and produces candidate pairs by region-querying each item's box."""

from geometry.aabb import AABB
from spatial.bvh import BVH
from .broadphase import BroadPhase, Pair, BoxProxy


struct BVHBroadPhase[D: Int](BroadPhase):
    comptime dim: Int = Self.D
    var bvh: BVH[Self.D]
    var items: List[BoxProxy[Self.D]]

    def __init__(out self):
        self.bvh = BVH[Self.D]()
        self.items = List[BoxProxy[Self.D]]()

    def rebuild(mut self, items: List[BoxProxy[Self.D]]) raises:
        self.items = items.copy()
        var boxes = List[AABB[Self.D]]()
        var proxies = List[Int]()
        for i in range(len(items)):
            boxes.append(items[i].box)
            proxies.append(items[i].proxy)
        self.bvh.build_boxes(boxes, proxies)

    def pairs(self, mut out: List[Pair]) raises:
        for i in range(len(self.items)):
            var cands = List[Int]()
            self.bvh.query_region(self.items[i].box, cands)
            for k in range(len(cands)):
                if cands[k] > self.items[i].proxy:
                    out.append(Pair(self.items[i].proxy, cands[k]))

    def query_region(self, box: AABB[Self.D], mut out: List[Int]) raises:
        self.bvh.query_region(box, out)
