"""One interface for 3D signed distance fields (ROADMAP 17.52).

`geometry.sdf3.Sdf3` is analytic (primitives and CSG); `geometry.sdf_grid.
SdfGrid` is sampled (a lattice with trilinear interpolation, baked from a
mesh or from any field). Both implement `DistanceField3`, so a query written
once runs on either: `sphere_trace` here, `SdfGrid.from_field` to sample an
analytic field into the grid the solver's `SHAPE_SDF` stores.

Sphere tracing (Hart 1996) steps along the ray by the field value: a
1-Lipschitz field guarantees no surface lies closer than that. An exact SDF
is 1-Lipschitz; a CSG union / intersection is a bound and still safe; a
trilinear grid is not exactly 1-Lipschitz between nodes, so steps are taken
at `scale` (0.9 by default) of the value.
"""

from .vec import Real, Vec3, dot


trait DistanceField3:
    """Signed distance (negative inside) and its gradient at a world point."""

    def distance(self, p: Vec3) -> Real:
        ...

    def gradient(self, p: Vec3) -> Vec3:
        ...


@fieldwise_init
struct TraceHit(Copyable, ImplicitlyCopyable, Movable):
    var hit: Bool
    var t: Real
    var steps: Int
    var inside: Bool  # the ray started inside (t = 0)


def sphere_trace[F: DistanceField3](
    f: F, o: Vec3, d: Vec3, max_t: Real, skin: Real, scale: Real = 0.9, max_steps: Int = 256
) -> TraceHit:
    """First t in [0, max_t] where the field along o + d t (d unit) falls
    to `skin` or below."""
    var t = Real(0)
    for it in range(max_steps):
        var v = f.distance(o + d * t)
        if v <= skin:
            return TraceHit(True, t, it, it == 0 and v < 0)
        t += max(v * scale, skin)
        if t > max_t:
            break
    return TraceHit(False, max_t, max_steps, False)
