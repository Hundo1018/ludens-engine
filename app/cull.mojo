"""Frustum culling of a frame's draw items (ArenaRendererOf.cull).

An item is dropped when its bounding sphere lies wholly outside one of the view's six planes. Dropping it must not
change a pixel, so an item that could still throw a shadow into the view is kept:

  - with the sun's shadow on, the sphere is swept `reach` metres away from the sun and dropped only if that whole
    capsule is outside a plane;
  - an item within the range of a spot or point light that casts a shadow is kept.

Bounds: a box primitive's is the length of its half extents, a sphere's its radius; a mesh's is the largest distance of
a vertex from the mesh's origin (kept per mesh, recomputed when a dynamic mesh's version changes) times the largest
scale. Skinned items are never dropped: their pose moves them and no bound of it is kept.
"""
from std.math import sqrt
from game.draw_item import DrawItem
from game.camera_view import View
from geometry.vec import Real, Vec3
from app.mesh_data import MeshRegistry


struct MeshBounds(Movable):
    var radius: List[Float64]
    var version: List[Int]

    def __init__(out self):
        self.radius = List[Float64]()
        self.version = List[Int]()

    def of(mut self, registry: MeshRegistry, mesh: Int) -> Float64:
        """The largest distance of mesh `mesh`'s vertices from its origin."""
        while len(self.radius) <= mesh:
            self.radius.append(-1.0)
            self.version.append(-1)
        if self.radius[mesh] < 0.0 or self.version[mesh] != registry.versions[mesh]:
            var r2 = 0.0
            ref p = registry.meshes[mesh].positions
            for i in range(len(p) // 3):
                var d = Float64(p[3 * i]) * Float64(p[3 * i]) + Float64(p[3 * i + 1]) * Float64(p[3 * i + 1]) + Float64(p[3 * i + 2]) * Float64(p[3 * i + 2])
                r2 = max(r2, d)
            self.radius[mesh] = sqrt(r2)
            self.version[mesh] = registry.versions[mesh]
        return self.radius[mesh]


def item_radius(it: DrawItem, registry: MeshRegistry, mut bounds: MeshBounds) -> Float64:
    """The radius of a sphere around it.pos that holds the item; negative for one that has no bound (skinned)."""
    if it.pose_id >= 0:
        return -1.0
    var hx = abs(Float64(it.half[0]))
    var hy = abs(Float64(it.half[1]))
    var hz = abs(Float64(it.half[2]))
    if it.mesh_id >= 0:
        return bounds.of(registry, it.mesh_id) * max(hx, max(hy, hz))
    if it.kind == 1:
        return hx
    return sqrt(hx * hx + hy * hy + hz * hz)


def _plane(v: View, p: Vec3, k: Int) -> Float64:
    """The signed distance (metres, positive inside) of p from plane k of the view: near, far, left, right, bottom,
    top."""
    var d = p - v.eye
    var z = Float64(d[0] * v.fwd[0] + d[1] * v.fwd[1] + d[2] * v.fwd[2])
    if k == 0:
        return z - Float64(v.near)
    if k == 1:
        return Float64(v.far) - z
    var side = k < 4
    var a = Float64(d[0] * v.right[0] + d[1] * v.right[1] + d[2] * v.right[2]) if side else Float64(d[0] * v.up[0] + d[1] * v.up[1] + d[2] * v.up[2])
    var s = Float64(v.sx) if side else Float64(v.sy)
    if k == 3 or k == 5:
        a = -a
    if v.ortho:
        return 1.0 / s + a
    return (z + a * s) / sqrt(1.0 + s * s)


def capsule_outside(v: View, p0: Vec3, p1: Vec3, radius: Float64) -> Bool:
    """True if the sphere of this radius swept from p0 to p1 is wholly outside one plane of the view."""
    for k in range(6):
        if _plane(v, p0, k) < -radius and _plane(v, p1, k) < -radius:
            return True
    return False


@fieldwise_init
struct ShadowReach(Copyable, Movable):
    """What keeps an item outside the view: the sun's direction and how far its shadows are followed (sun_on), and the
    spot and point lights that cast shadows (position xyz, range w)."""

    var sun_on: Bool
    var to_sun: Vec3
    var reach: Float64
    var lights: List[Vec3]


def visible_items(items: List[DrawItem], v: View, registry: MeshRegistry, mut bounds: MeshBounds, shadow: ShadowReach, pad: Float64 = 0.0) -> List[DrawItem]:
    """The items that can change a pixel of the view (see the module note). `pad` widens every bound (the half
    distance between the eyes of a two-eye pipeline)."""
    var out = List[DrawItem]()
    for it in items:
        var r = item_radius(it, registry, bounds)
        if r < 0.0:
            out.append(it.copy())
            continue
        r += pad
        var far_end = it.pos
        var caster = it.mesh_id >= 0  # only items with a mesh cast (app/shadow_pass.mojo casts_shadow)
        if caster and shadow.sun_on:
            far_end = it.pos - shadow.to_sun * Real(shadow.reach)
        if not capsule_outside(v, it.pos, far_end, r):
            out.append(it.copy())
            continue
        var lit = False
        if caster:
            for l in shadow.lights:
                var d = it.pos - l
                var dist = sqrt(Float64(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]))
                if dist <= Float64(l[3]) + r:
                    lit = True
        if lit:
            out.append(it.copy())
    return out^
