"""Scene queries — the swap seam: raycast / overlap over interchangeable indexes.

`SceneQuery` is the contract; four backends answer the *same* queries by reusing
the engine's existing acceleration structures:

  * `BruteForceQuery` — test every box (the O(n) reference).
  * `BvhQuery`        — true BVH ray traversal (descends only nodes the ray hits)
                        and BVH region query.
  * `GridQuery`       — spatial hash grid: gather candidates in the ray's / query's
                        cells, then exact-test.
  * `TreeQuery`       — loose quad/octree: same candidate-gather pattern.

Every backend re-filters candidates with the exact AABB/ray test, so they all
return identical results — that is the parity invariant the tests assert; the
benchmark shows what each *costs*. Proxy ids are expected dense (0..n-1), as the
collision/physics layers produce them.
"""

from geometry.vec import WorldType, Real, lane_min, lane_max
from geometry.aabb import AABB
from geometry.ray import Ray, RayHit, ray_aabb
from geometry.bvh import BVH
from spatial.hash_grid import SpatialHashGrid
from spatial.tree_core import LooseTree
from .broadphase import BoxProxy


trait SceneQuery(Defaultable, Movable, ImplicitlyDeletable):
    comptime dim: Int
    def rebuild(mut self, items: List[BoxProxy[Self.dim]]) raises: ...
    def raycast(self, ray: Ray[Self.dim]) raises -> RayHit[Self.dim]: ...
    def overlap(self, box: AABB[Self.dim], mut out: List[Int]) raises: ...


# --- shared helpers ---------------------------------------------------------

def _index_boxes[D: Int](items: List[BoxProxy[D]]) -> List[AABB[D]]:
    """Proxy id -> box lookup (proxies assumed dense from 0)."""
    var maxp = -1
    for i in range(len(items)):
        if items[i].proxy > maxp:
            maxp = items[i].proxy
    var boxes = List[AABB[D]]()
    var zero = AABB[D](SIMD[WorldType, D](0), SIMD[WorldType, D](0))
    for _ in range(maxp + 1):
        boxes.append(zero)
    for i in range(len(items)):
        boxes[items[i].proxy] = items[i].box
    return boxes^


def _ray_box[D: Int](ray: Ray[D]) -> AABB[D]:
    """AABB enclosing the ray segment [origin, origin + dir*max_t]."""
    var endp = ray.origin + ray.dir * ray.max_t
    return AABB[D](lane_min(ray.origin, endp), lane_max(ray.origin, endp))


def _ray_nearest[D: Int](
    boxes: List[AABB[D]], cand: List[Int], ray: Ray[D]
) -> RayHit[D]:
    var best = RayHit[D].miss()
    var best_t = ray.max_t
    for i in range(len(cand)):
        var p = cand[i]
        var bh = ray_aabb(ray, boxes[p])
        if bh.hit and bh.t <= best_t:
            best_t = bh.t
            best = RayHit[D](True, bh.t, p, bh.normal)
    return best


def _overlap_filter[D: Int](
    boxes: List[AABB[D]], cand: List[Int], box: AABB[D], mut out: List[Int]
):
    for i in range(len(cand)):
        var p = cand[i]
        if boxes[p].overlaps(box):
            out.append(p)


def _bounds_of[D: Int](items: List[BoxProxy[D]]) -> AABB[D]:
    if len(items) == 0:
        return AABB[D](SIMD[WorldType, D](-1), SIMD[WorldType, D](1))
    var b = items[0].box
    for i in range(1, len(items)):
        b = b.merge(items[i].box)
    return b


# --- backends ---------------------------------------------------------------

struct BruteForceQuery[D: Int](SceneQuery):
    comptime dim = Self.D
    var boxes: List[AABB[Self.D]]

    def __init__(out self):
        self.boxes = List[AABB[Self.D]]()

    def rebuild(mut self, items: List[BoxProxy[Self.D]]) raises:
        self.boxes = _index_boxes(items)

    def raycast(self, ray: Ray[Self.D]) raises -> RayHit[Self.D]:
        var best = RayHit[Self.D].miss()
        var best_t = ray.max_t
        for p in range(len(self.boxes)):
            var bh = ray_aabb(ray, self.boxes[p])
            if bh.hit and bh.t <= best_t:
                best_t = bh.t
                best = RayHit[Self.D](True, bh.t, p, bh.normal)
        return best

    def overlap(self, box: AABB[Self.D], mut out: List[Int]) raises:
        for p in range(len(self.boxes)):
            if self.boxes[p].overlaps(box):
                out.append(p)


struct BvhQuery[D: Int](SceneQuery):
    comptime dim = Self.D
    var bvh: BVH[Self.D]
    var boxes: List[AABB[Self.D]]

    def __init__(out self):
        self.bvh = BVH[Self.D]()
        self.boxes = List[AABB[Self.D]]()

    def rebuild(mut self, items: List[BoxProxy[Self.D]]) raises:
        self.boxes = _index_boxes(items)
        var bx = List[AABB[Self.D]]()
        var px = List[Int]()
        for i in range(len(items)):
            bx.append(items[i].box)
            px.append(items[i].proxy)
        self.bvh = BVH[Self.D]()
        self.bvh.build_boxes(bx, px)

    def raycast(self, ray: Ray[Self.D]) raises -> RayHit[Self.D]:
        return self.bvh.raycast(ray)

    def overlap(self, box: AABB[Self.D], mut out: List[Int]) raises:
        var cand = List[Int]()
        self.bvh.query_region(box, cand)
        _overlap_filter(self.boxes, cand, box, out)


struct GridQuery[D: Int](SceneQuery):
    comptime dim = Self.D
    var grid: SpatialHashGrid[Self.D]
    var boxes: List[AABB[Self.D]]
    var cell_size: Real

    def __init__(out self):
        self.cell_size = 1.0
        self.grid = SpatialHashGrid[Self.D](1.0)
        self.boxes = List[AABB[Self.D]]()

    def rebuild(mut self, items: List[BoxProxy[Self.D]]) raises:
        self.boxes = _index_boxes(items)
        self.grid = SpatialHashGrid[Self.D](self.cell_size)
        for i in range(len(items)):
            self.grid.insert(items[i].proxy, items[i].box)

    def raycast(self, ray: Ray[Self.D]) raises -> RayHit[Self.D]:
        var cand = List[Int]()
        self.grid.query_region(_ray_box(ray), cand)
        return _ray_nearest(self.boxes, cand, ray)

    def overlap(self, box: AABB[Self.D], mut out: List[Int]) raises:
        var cand = List[Int]()
        self.grid.query_region(box, cand)
        _overlap_filter(self.boxes, cand, box, out)


struct TreeQuery[D: Int](SceneQuery):
    comptime dim = Self.D
    var tree: LooseTree[Self.D]
    var boxes: List[AABB[Self.D]]

    def __init__(out self):
        self.tree = LooseTree[Self.D](
            AABB[Self.D](SIMD[WorldType, Self.D](-1), SIMD[WorldType, Self.D](1))
        )
        self.boxes = List[AABB[Self.D]]()

    def rebuild(mut self, items: List[BoxProxy[Self.D]]) raises:
        self.boxes = _index_boxes(items)
        self.tree.clear(_bounds_of(items))
        for i in range(len(items)):
            self.tree.insert(items[i].proxy, items[i].box)

    def raycast(self, ray: Ray[Self.D]) raises -> RayHit[Self.D]:
        var cand = List[Int]()
        self.tree.query_region(_ray_box(ray), cand)
        return _ray_nearest(self.boxes, cand, ray)

    def overlap(self, box: AABB[Self.D], mut out: List[Int]) raises:
        var cand = List[Int]()
        self.tree.query_region(box, cand)
        _overlap_filter(self.boxes, cand, box, out)
