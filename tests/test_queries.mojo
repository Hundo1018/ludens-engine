"""Scene queries: known-scene raycast/overlap checked across all four backends.

Four boxes on the axis-0 line at coord 1,3,5,7. A ray from the negative side hits
the nearest (proxy 0) at t=5.5 with normal pointing back along axis 0; a parallel
ray offset off the line misses; an overlap box selects the middle two. Every
backend (brute force, BVH, grid, loose tree) is asserted against the same ground
truth — which is the cross-backend parity check. Written generic over `Q.dim`
(the line scene is valid in any dimension) so it type-checks with the associated
constant, like the scheduler-parity driver uses `S.B`.
"""

from harness.runner import Suite
from geometry.vec import WorldType, Real
from geometry.aabb import AABB
from geometry.ray import Ray
from collision.broadphase import BoxProxy
from collision.queries import (
    SceneQuery,
    BruteForceQuery,
    BvhQuery,
    GridQuery,
    TreeQuery,
)


def make_scene[D: Int]() -> List[BoxProxy[D]]:
    var items = List[BoxProxy[D]]()
    for i in range(4):
        var c = SIMD[WorldType, D](0)
        c[0] = Real(2 * i + 1)  # axis-0 coord = 1, 3, 5, 7
        var half = SIMD[WorldType, D](0.5)
        items.append(BoxProxy[D](i, AABB[D].from_center(c, half)))
    return items^


def _has(xs: List[Int], v: Int) -> Bool:
    for i in range(len(xs)):
        if xs[i] == v:
            return True
    return False


def run_backend[Q: SceneQuery](mut s: Suite, tag: String) raises:
    var items = make_scene[Q.dim]()
    var q = Q()
    q.rebuild(items)

    # ray along +axis0 from coord -5 -> hits box 0 at t = (1-0.5) - (-5) = 5.5
    var o = SIMD[WorldType, Q.dim](0)
    o[0] = -5
    var d = SIMD[WorldType, Q.dim](0)
    d[0] = 1
    var hit = q.raycast(Ray[Q.dim](o, d, 100.0))
    s.check(hit.hit, tag + " ray hits")
    s.eqi(hit.proxy, 0, tag + " nearest proxy")
    s.almost(Float64(hit.t), 5.5, tag + " ray t", 1e-3)
    s.almost(Float64(hit.normal[0]), -1.0, tag + " normal -axis0", 1e-3)

    # same ray offset off the line on axis 1 -> misses everything
    var o2 = SIMD[WorldType, Q.dim](0)
    o2[0] = -5
    o2[1] = 10
    var miss = q.raycast(Ray[Q.dim](o2, d, 100.0))
    s.check(not miss.hit, tag + " ray miss off the line")

    # overlap box centered at axis0=4, half 1.5 -> axis0 in [2.5,5.5] -> boxes 1,2
    var center = SIMD[WorldType, Q.dim](0)
    center[0] = 4
    var half = SIMD[WorldType, Q.dim](1.5)
    var out = List[Int]()
    q.overlap(AABB[Q.dim].from_center(center, half), out)
    s.eqi(len(out), 2, tag + " overlap count")
    s.check(_has(out, 1) and _has(out, 2), tag + " overlap members {1,2}")


def main() raises:
    var s = Suite("queries")
    run_backend[BruteForceQuery[2]](s, "brute")
    run_backend[BvhQuery[2]](s, "bvh")
    run_backend[GridQuery[2]](s, "grid")
    run_backend[TreeQuery[2]](s, "tree")
    s.finish()
