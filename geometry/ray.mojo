"""Ray primitive + ray/AABB slab test — the basis of scene raycasts.

`ray_aabb` is the standard slab intersection: it clips the ray against each axis'
[min,max] slab, tracking the entry distance `t` and which face was entered (for
the surface normal). Dimension-generic via a scalar `comptime for` over the axes
(no width-3 SIMD). `RayHit` carries the proxy id so callers can report *what* was
hit; `ray_aabb` leaves it -1 for the caller to fill.
"""

from .vec import WorldType, Real
from .aabb import AABB


@fieldwise_init
struct Ray[dim: Int](Copyable, ImplicitlyCopyable, Movable):
    var origin: SIMD[WorldType, Self.dim]
    var dir: SIMD[WorldType, Self.dim]
    var max_t: Real


@fieldwise_init
struct RayHit[dim: Int](Copyable, ImplicitlyCopyable, Movable):
    var hit: Bool
    var t: Real
    var proxy: Int
    var normal: SIMD[WorldType, Self.dim]

    @staticmethod
    def miss() -> Self:
        return Self(False, 0, -1, SIMD[WorldType, Self.dim](0))


def ray_aabb[dim: Int](ray: Ray[dim], box: AABB[dim]) -> RayHit[dim]:
    var tmin = Real(0)
    var tmax = ray.max_t
    var axis = 0
    var nsign = Real(0)
    comptime for k in range(dim):
        var d = ray.dir[k]
        var o = ray.origin[k]
        var ad = d
        if ad < 0:
            ad = -ad
        if ad < 1e-9:
            # ray parallel to this slab: must already be within it
            if o < box.min[k] or o > box.max[k]:
                return RayHit[dim].miss()
        else:
            var inv = Real(1) / d
            var t1 = (box.min[k] - o) * inv
            var t2 = (box.max[k] - o) * inv
            var sgn = Real(-1)  # entering the min face
            if t1 > t2:
                var tmp = t1
                t1 = t2
                t2 = tmp
                sgn = Real(1)  # entering the max face
            if t1 > tmin:
                tmin = t1
                axis = k
                nsign = sgn
            if t2 < tmax:
                tmax = t2
            if tmin > tmax:
                return RayHit[dim].miss()
    var normal = SIMD[WorldType, dim](0)
    normal[axis] = nsign
    return RayHit[dim](True, tmin, -1, normal)
