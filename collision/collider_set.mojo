"""Collider registry + shape-pair dispatch (audit cluster 6, finding F1).

Moved out of `physics/solver6.mojo`: the collider side of a `ContactScene6`
(shape kind, half extents, hull/mesh/heightfield side tables, category/mask
filtering, sensor flag) plus the narrowphase dispatch that used to read them
straight off `self.bodies[i]`. `ColliderSet` never sees a `Body6` — every
method that needs a world transform takes a `Pose3` (position + orientation)
instead, so 17.13 scene queries and the 17.1 character controller can use the
real collider geometry without importing physics or reaching into
`ContactScene6` fields.

`ContactScene6` now *holds* a `ColliderSet` (same index space: collider `i` is
body `i`) and delegates its `add*`/`set_filter`/`set_sensor` API to it.
"""

from std.math import sqrt
from std.os import abort
from geometry.vec import Real, Vec3, dot
from geometry.aabb import AABB
from geometry.gjk import ConvexPoly, Support3
from geometry.gjk_distance import support_distance
from geometry.epa import epa3
from geometry.support import SupportEllipsoid, SupportCylinder, SupportCapsule, SupportBox
from .hull import HullShape, hull_manifold
from geometry.sdf_grid import SdfGrid
from .trimesh import TriMesh, HeightField, closest_point_on_triangle
from .manifold import (
    ContactManifold,
    Axes3,
    box_box_manifold,
    sphere_sphere_manifold,
    sphere_box_manifold,
    capsule_box_manifold,
    capsule_capsule_manifold,
    capsule_sphere_manifold,
)

# Shape kinds, named (previously bare 0-5 literals on `solver6.ContactScene6`).
# Kinds 4/5 are static-only: a mesh/heightfield has no useful inertia tensor
# and no closed volume (see `add_trimesh`/`add_heightfield`).
comptime SHAPE_BOX = 0
comptime SHAPE_SPHERE = 1
comptime SHAPE_CAPSULE = 2
comptime SHAPE_HULL = 3
comptime SHAPE_TRIMESH = 4
comptime SHAPE_HEIGHTFIELD = 5
# ROADMAP 17.52: a static signed distance grid (`geometry.sdf_grid.SdfGrid`,
# world coordinates like the meshes). Routed by `contact_gen.try_pair` to
# `try_sdf_pair` before the mesh path; the `>= SHAPE_TRIMESH` checks there
# see it only after that branch.
comptime SHAPE_SDF = 6
# ROADMAP 17.52: a solid ellipsoid, radii in `half` along the body axes.
# Contacts and queries go through its exact support mapping
# (`geometry.support.SupportEllipsoid`, GJK distance + EPA): one point per
# pair, routed in `pair_manifold` before the kind-ordered branches, and in
# `contact_gen` before the `>= SHAPE_TRIMESH` checks.
comptime SHAPE_ELLIPSOID = 7


def support_manifold[A: Support3, B: Support3](a: A, b: B, margin: Real) -> ContactManifold[3]:
    """One-point contact between two `Support3` shapes (ROADMAP 17.52):
    apart by less than `margin` -> a speculative point midway between the
    GJK witnesses, depth `margin - distance`; overlapping -> EPA's witnesses,
    depth `penetration + margin` (the caller subtracts the margin, as for
    every other pair). Normal from `a` to `b`."""
    var d = support_distance(a, 0, b, 0)
    if d.dist > margin:
        return ContactManifold[3].miss()
    if d.dist > 0:
        var m = ContactManifold[3].hit_along(d.normal)
        m.add((d.pa + d.pb) * 0.5, margin - d.dist)
        return m
    var w = epa3(a, b)
    var m = ContactManifold[3].hit_along(w.normal)
    m.add((w.point_a + w.point_b) * 0.5, w.depth + margin)
    return m

# Speculative-contact margin base (audit F19): the ONE definition -- both
# `fat_aabb` below and `collision.contact_gen`'s per-pair margin import this
# instead of each carrying their own `0.02` literal, so the two can no
# longer drift apart (the fat-AABB/margin parity guarantee at `fat_aabb`'s
# docstring depends on them staying equal).
comptime SPEC_BASE: Real = 0.02


@fieldwise_init
struct Pose3(Copyable, Movable):
    """A rigid pose: world position + world-frame box axes (the columns of
    the rotation). The seam between physics and collision — every
    `ColliderSet` query takes one of these instead of a `Body6`.

    Not `ImplicitlyCopyable`: `Axes3` (`Array[Vec3, 3]`) is not implicitly
    copyable in Mojo 1.1, so neither is a struct holding one -- duplicate a
    `Pose3` with `.copy()`, or read its fields (`.position`, `.axes[k]`)
    without copying the whole value."""

    var position: Vec3
    var axes: Axes3

    def __init__(out self, *, copy: Self):
        self.position = copy.position
        self.axes = copy.axes.copy()


struct ColliderSet(Movable, Deinitable):
    """Per-collider shape data, indexed the same as the owning `ContactScene6`
    indexes its bodies (collider `i` <-> body `i`)."""

    var shape: List[Int]
    var half: List[Vec3]  # box half-extents (conservative for every kind)
    # Convex hulls, indexed by `hull_id[i]` (-1 when body i is not a hull). A
    # side table rather than a field on every body: hulls are rare and carry
    # a vertex list, so paying for one on every sphere would be wasteful.
    var hulls: List[HullShape]
    var hull_id: List[Int]
    # Static level geometry (kinds 4 and 5), same side-table scheme. Their
    # vertices are WORLD space and their body pose is ignored: a level does
    # not move, and keeping the triangles pre-transformed is the whole reason
    # the midphase query can be a plain AABB test.
    var meshes: List[TriMesh]
    var fields: List[HeightField]
    var mesh_id: List[Int]
    var sdfs: List[SdfGrid]  # SHAPE_SDF payloads, indexed by mesh_id (17.52)
    # World AABB of collider `i`, valid only for SHAPE_TRIMESH/SHAPE_HEIGHTFIELD
    # (zero otherwise). Computed once at `add_trimesh`/`add_heightfield` time
    # from the mesh's own (already world-space) vertices, so `fat_aabb` never
    # has to consult -- and cannot be fooled by -- the owning body's pose
    # (17.0f / F3: a level's vertices are world space and its body pose is
    # documented as ignored, but the broadphase fattening used to centre the
    # box on that pose anyway, culling contacts for any mesh not centred on
    # its body).
    var world_aabb: List[AABB[3]]
    # Collision filtering, Box2D's scheme: two bodies collide when each one's
    # category is in the other's mask. Applied by `should_collide`, the
    # single point both the brute and the broadphase enumeration funnel
    # through -- so a filtered pair costs one AND on either seam, and the two
    # cannot disagree about what was filtered.
    var category: List[UInt32]
    var mask: List[UInt32]
    # A sensor reports overlap and never receives an impulse.
    var sensor: List[Bool]

    def __init__(out self):
        self.shape = List[Int]()
        self.half = List[Vec3]()
        self.hulls = List[HullShape]()
        self.hull_id = List[Int]()
        self.meshes = List[TriMesh]()
        self.fields = List[HeightField]()
        self.mesh_id = List[Int]()
        self.sdfs = List[SdfGrid]()
        self.world_aabb = List[AABB[3]]()
        self.category = List[UInt32]()
        self.mask = List[UInt32]()
        self.sensor = List[Bool]()

    # ------------------------------------------------------------ registry

    def add(mut self, half: Vec3, at: Int = -1) -> Int:
        """Register a box collider (the default kind); returns its index.

        `at` (ROADMAP 17.0i, `physics.solver6.ContactScene6.remove_body`):
        when >= 0, write into that EXACT slot instead of appending -- lets a
        caller that owns a separate free-list-based index space (`BodySet`)
        keep `collider i == body i` in lockstep after a removed body's slot
        is reused by a later `add*`. `at == len(self.shape)` behaves exactly
        like appending; `at` below that overwrites an existing (tombstoned)
        row in place. Every field list is written by every branch below, the
        same "one method, every list grows/overwrites together" discipline
        `physics.body_set.BodySet.push` uses for the body side."""
        var i = at
        if i < 0 or i == len(self.shape):
            i = len(self.shape)
            self.shape.append(SHAPE_BOX)
            self.half.append(half)
            self.hull_id.append(-1)
            self.mesh_id.append(-1)
            self.world_aabb.append(AABB[3](Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0)))
            self.category.append(1)
            self.mask.append(0xFFFFFFFF)
            self.sensor.append(False)
        else:
            debug_assert(
                i < len(self.shape),
                "ColliderSet.add: `at` must be an existing slot or the next index",
            )
            self.shape[i] = SHAPE_BOX
            self.half[i] = half
            self.hull_id[i] = -1
            self.mesh_id[i] = -1
            self.world_aabb[i] = AABB[3](Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))
            self.category[i] = 1
            self.mask[i] = 0xFFFFFFFF
            self.sensor[i] = False
        return i

    def add_ground_slab(
        mut self, top: Real, thickness: Real = 0.25, extent: Real = 1000
    ) -> Tuple[Int, Pose3]:
        """Register a horizontal slab whose upper face is the plane `y = top`;
        returns its collider index and the world `Pose3` that places it.

        The ground for callers that have no body to hang a collider on (an
        articulated chain's feet, a particle test): the slab is `2*extent`
        wide in x and z and `thickness` deep, so a point that sinks up to
        `thickness` below the plane is still INSIDE it and gets a push-out
        normal of `+y`; deeper than that it is outside the bottom face, and a
        collider-based contact query reports nothing. Size it for the deepest
        penetration you expect to repair.

        Precision: the centre sits at `top - thickness`, so `top` is recovered
        exactly (distance to the plane == `p.y - top`, bit for bit) when that
        subtraction is exact -- true whenever `top - thickness` lies in the
        same binade as `top`, e.g. `thickness` a power of two no larger than
        about half of `|top|`. Otherwise the answer is off by an ulp of
        `top`, which no contact tolerance cares about."""
        var i = self.add(Vec3(extent, thickness, extent, 0))
        var axes = Axes3(fill=Vec3(0, 0, 0, 0))
        axes[0] = Vec3(1, 0, 0, 0)
        axes[1] = Vec3(0, 1, 0, 0)
        axes[2] = Vec3(0, 0, 1, 0)
        return (i, Pose3(Vec3(0, top - thickness, 0, 0), axes^))

    def add_sphere(mut self, r: Real, at: Int = -1) -> Int:
        var i = self.add(Vec3(r, r, r, 0), at)
        self.shape[i] = SHAPE_SPHERE
        return i

    def add_capsule(mut self, r: Real, half_len: Real, at: Int = -1) -> Int:
        # `half` stores (r, half_len, r) -- readers take half[1] as the
        # segment half length; `fat_aabb` adds the cap radius to the box
        var i = self.add(Vec3(r, half_len, r, 0), at)
        self.shape[i] = SHAPE_CAPSULE
        return i

    def add_ellipsoid(mut self, radii: Vec3, at: Int = -1) -> Int:
        """Solid ellipsoid with semi-axes `radii` along the body's local
        x, y, z (ROADMAP 17.52). `half` = radii, so the AABB paths see its
        bounding box."""
        var i = self.add(radii, at)
        self.shape[i] = SHAPE_ELLIPSOID
        return i

    def support_ellipsoid(self, i: Int, pose: Pose3) -> SupportEllipsoid:
        """World support mapping of ellipsoid collider `i`."""
        return SupportEllipsoid(pose.position, pose.axes[0], pose.axes[1], pose.axes[2], self.half[i])

    def ellipsoid_pair(self, e: Int, pe: Pose3, o: Int, po: Pose3, margin: Real) -> ContactManifold[3]:
        """Ellipsoid `e` against convex collider `o` (box, sphere, capsule,
        hull -- a cylinder hull by its exact support -- or another
        ellipsoid), normal from `e` to `o`; see `support_manifold`."""
        var se = self.support_ellipsoid(e, pe)
        var k = self.shape[o]
        if k == SHAPE_ELLIPSOID:
            return support_manifold(se, self.support_ellipsoid(o, po), margin)
        if k == SHAPE_BOX:
            return support_manifold(se, SupportBox(po.position, po.axes[0], po.axes[1], po.axes[2], self.half[o]), margin)
        if k == SHAPE_SPHERE:
            return support_manifold(se, SupportCapsule(po.position, po.axes[1], self.half[o][0], 0), margin)
        if k == SHAPE_CAPSULE:
            return support_manifold(se, SupportCapsule(po.position, po.axes[1], self.half[o][0], self.half[o][1]), margin)
        if self.round_radius(o) > 0:
            return support_manifold(se, SupportCylinder(po.position, po.axes[1], self.round_radius(o), self.half[o][1]), margin)
        return support_manifold(se, self.hull_world(o, po), margin)

    def add_hull(mut self, var verts: List[Real], at: Int = -1) -> Int:
        """A convex body given by its LOCAL-frame vertices, FLAT (x, y, z per
        vertex) -- see `collision/hull.mojo` for why flat, not `List[Vec3]`.

        The `half` extent recorded is the vertex cloud's bounding half-size,
        so every AABB-based path (broadphase fattening, sleeping, islands)
        keeps working unchanged and conservatively -- a hull is never
        smaller than the box the rest of the engine already reasons about."""
        var h = Vec3(0, 0, 0, 0)
        for vi in range(len(verts) // 3):
            comptime for k in range(3):
                if abs(verts[3 * vi + k]) > h[k]:
                    h[k] = abs(verts[3 * vi + k])
        var i = self.add(h, at)
        self.shape[i] = SHAPE_HULL
        self.hull_id[i] = len(self.hulls)
        self.hulls.append(HullShape(verts^))
        return i

    def add_trimesh(
        mut self, verts: List[Real], indices: List[Int], at: Int = -1,
        active: List[UInt8] = List[UInt8](),
    ) raises -> Int:
        """Static triangle soup. `verts` is flat (x, y, z per vertex) in
        WORLD space, `indices` three per triangle. Always static (see
        `physics.solver6.ContactScene6.add_trimesh`).

        The owning body's pose is ignored, as documented: `world_aabb` is the
        mesh's own world-space bounds, computed once here, and `fat_aabb`
        returns it (grown by the usual speculative margin) instead of
        centring a box on the body's position (17.0f / F3)."""
        var m = TriMesh(verts, indices)
        if len(active) > 0:
            m.set_active_edges(active)
        var bb = m.bounds()
        var i = self.add(bb.half_extents(), at)
        self.shape[i] = SHAPE_TRIMESH
        self.mesh_id[i] = len(self.meshes)
        self.world_aabb[i] = bb
        self.meshes.append(m^)
        return i

    def add_heightfield(
        mut self, heights: List[Real], nx: Int, nz: Int,
        cell: Real, ox: Real = 0, oz: Real = 0, at: Int = -1,
    ) raises -> Int:
        """Static heightfield -- see `add_trimesh`; the same world-space
        `world_aabb` treatment (body pose ignored) applies here too."""
        var f = HeightField(heights, nx, nz, cell, ox, oz)
        var bb = f.bounds()
        var i = self.add(bb.half_extents(), at)
        self.shape[i] = SHAPE_HEIGHTFIELD
        self.mesh_id[i] = len(self.fields)
        self.world_aabb[i] = bb
        self.fields.append(f^)
        return i

    def add_sdf(mut self, var grid: SdfGrid, at: Int = -1) -> Int:
        """Static signed distance grid (ROADMAP 17.52), world coordinates like
        `add_trimesh` (the owning body's pose is ignored). Contacts sample
        the other shape against the grid (`contact_gen.try_sdf_pair`)."""
        var span = grid.cell * Real(max(grid.res - 1, 0))
        var bb = AABB[3](grid.origin, grid.origin + Vec3(span, span, span, 0))
        var i = self.add(bb.half_extents(), at)
        self.shape[i] = SHAPE_SDF
        self.mesh_id[i] = len(self.sdfs)
        self.world_aabb[i] = bb
        self.sdfs.append(grid^)
        return i

    def shift_static(mut self, d: Vec3) raises:
        """Origin rebasing (ROADMAP 17.8): move every WORLD-space static shape
        by `-d` -- triangle meshes and heightfields store world coordinates
        (their owning body's pose is ignored, see `add_trimesh`). Each is
        rebuilt through its constructor from the shifted source data, so the
        BVH, normals and per-block bounds come out exactly as if it had been
        added at the new coordinates; `world_aabb` follows. Box, sphere,
        capsule and hull shapes are body-relative and need nothing."""
        for i in range(len(self.shape)):
            var k = self.shape[i]
            if k == SHAPE_TRIMESH:
                var mi = self.mesh_id[i]
                var v = self.meshes[mi].v.copy()
                for j in range(len(v) // 3):
                    v[3 * j] -= d[0]
                    v[3 * j + 1] -= d[1]
                    v[3 * j + 2] -= d[2]
                self.meshes[mi] = TriMesh(v, self.meshes[mi].idx)
                self.world_aabb[i] = self.meshes[mi].bounds()
            elif k == SHAPE_HEIGHTFIELD:
                var fi = self.mesh_id[i]
                ref f = self.fields[fi]
                var h = f.h.copy()
                for j in range(len(h)):
                    h[j] -= d[1]
                self.fields[fi] = HeightField(h, f.nx, f.nz, f.cell, f.ox - d[0], f.oz - d[2])
                self.world_aabb[i] = self.fields[fi].bounds()
            elif k == SHAPE_SDF:
                var si = self.mesh_id[i]
                self.sdfs[si].origin = self.sdfs[si].origin - d
                self.world_aabb[i] = AABB[3](self.world_aabb[i].min - d, self.world_aabb[i].max - d)

    def deform_heightfield(
        mut self, i: Int, cx: Real, cz: Real, radius: Real, delta: Real,
        incremental: Bool = True,
    ) raises -> Int:
        """Edit heightfield collider `i` (ROADMAP 17.30) and refresh its
        world AABB and conservative half extents -- from the field's block
        summary (`incremental`) or by rescanning every height; the two give
        the same box. Returns the number of corners edited."""
        if self.shape[i] != SHAPE_HEIGHTFIELD:
            raise Error("ColliderSet.deform_heightfield: collider is not a heightfield")
        var k = self.mesh_id[i]
        var edited = self.fields[k].deform(cx, cz, radius, delta)
        var bb = self.fields[k].bounds_blocks() if incremental else self.fields[k].bounds()
        self.world_aabb[i] = bb
        self.half[i] = bb.half_extents()
        return edited

    def set_filter(mut self, i: Int, category: UInt32, mask: UInt32):
        """Which layer collider `i` is on, and which layers it collides with.

        Symmetric by construction: both directions must agree, so "players do
        not hit players" is one bit cleared, not a rule that has to be
        repeated on every other body."""
        self.category[i] = category
        self.mask[i] = mask

    def set_sensor(mut self, i: Int, on: Bool):
        """A sensor overlaps but never pushes: it reports contact events and
        is skipped by every solve pass. Trigger volumes are the point."""
        self.sensor[i] = on

    # --------------------------------------------------------- predicates

    def should_collide(self, i: Int, j: Int) -> Bool:
        return (self.category[i] & self.mask[j]) != 0 and (
            self.category[j] & self.mask[i]
        ) != 0

    def is_sensor(self, i: Int) -> Bool:
        return self.sensor[i]

    # ------------------------------------------------------- mesh midphase

    def round_radius(self, i: Int) -> Real:
        """Cylinder radius of hull collider `i` (ROADMAP 17.52), else 0."""
        if self.shape[i] == SHAPE_HULL:
            return self.hulls[self.hull_id[i]].round_r
        return 0

    def mesh_ray_candidates(self, i: Int, o: Vec3, d: Vec3, max_t: Real, mut out: List[Int]):
        """Triangles of static collider `i` along a ray segment (ROADMAP
        17.53): BVH descent for a trimesh, a grid DDA for a heightfield."""
        if self.shape[i] == SHAPE_TRIMESH:
            self.meshes[self.mesh_id[i]].ray_candidates(o, d, max_t, out)
        else:
            self.fields[self.mesh_id[i]].ray_candidates(o, d, max_t, out)

    def mesh_candidates(self, i: Int, box: AABB[3], mut out: List[Int]):
        """Triangles of static collider `i` that could touch `box`. The two
        static kinds answer this differently -- BVH descent vs cell
        arithmetic -- and that is the only place they differ; everything
        downstream is shared."""
        if self.shape[i] == SHAPE_TRIMESH:
            self.meshes[self.mesh_id[i]].candidates(box, out)
        else:
            self.fields[self.mesh_id[i]].candidates(box, out)

    def mesh_tri(self, i: Int, t: Int) -> ConvexPoly[3]:
        if self.shape[i] == SHAPE_TRIMESH:
            return self.meshes[self.mesh_id[i]].tri(t)
        return self.fields[self.mesh_id[i]].tri(t)

    def mesh_active(self, i: Int, t: Int) -> UInt8:
        """Active-edge flags of triangle `t` (ROADMAP 17.45); a heightfield
        reports every edge active (unchanged behaviour)."""
        if self.shape[i] == SHAPE_TRIMESH:
            return self.meshes[self.mesh_id[i]].active[t]
        return 7

    def mesh_tri_faces(self, i: Int, t: Int) -> List[Real]:
        if self.shape[i] == SHAPE_TRIMESH:
            return self.meshes[self.mesh_id[i]].tri_faces(t)
        return self.fields[self.mesh_id[i]].tri_faces(t)

    # ------------------------------------------------------- hull dispatch

    def hull_world(self, i: Int, pose: Pose3) -> ConvexPoly[3]:
        """The real hull geometry (no shape substitution, no inflation) --
        for 17.13 scene queries that want the exact collider, not the
        contact-margin-inflated approximation `as_hull` builds."""
        return self.hulls[self.hull_id[i]].world(
            pose.position, pose.axes[0], pose.axes[1], pose.axes[2]
        )

    def hull_faces(self, i: Int, pose: Pose3, infl: Vec3, mr: Real) -> List[Real]:
        """World-frame face normals for collider `i` under the same shape
        substitution `as_hull` makes. Needed because EPA's normal is only as
        good as its polytope, and the contact patch depends on snapping it to
        a real face (see `collision/hull.mojo`)."""
        ref ax = pose.axes
        var k = self.shape[i]
        if k == SHAPE_HULL:
            return self.hulls[self.hull_id[i]].world_normals(ax[0], ax[1], ax[2])
        var hs = self.half[i] + infl
        if k == SHAPE_SPHERE:
            hs = Vec3(self.half[i][0] + mr, self.half[i][0] + mr, self.half[i][0] + mr, 0)
        elif k == SHAPE_CAPSULE:
            hs = Vec3(self.half[i][0] + mr, self.half[i][1] + self.half[i][0] + mr, self.half[i][0] + mr, 0)
        return HullShape.box(hs).world_normals(ax[0], ax[1], ax[2])

    def as_hull(self, i: Int, pose: Pose3, infl: Vec3, mr: Real) -> ConvexPoly[3]:
        """Any supported shape as a convex point cloud, so the hull path can
        meet box/sphere/capsule without a separate routine per pairing.

        Spheres and capsules are only APPROXIMATED here (a sphere has no
        vertices), so they keep their own exact routines in `pair_manifold`
        and this is used solely for hull-vs-* pairs, where an approximation
        of the round side is still better than no contact at all."""
        ref ax = pose.axes
        var k = self.shape[i]
        if k == SHAPE_HULL:
            # Inflate the hull the same way the box path inflates its boxes,
            # by pushing each vertex out along its own octant. For a box hull
            # this reproduces `half + infl` exactly; for a general hull it is
            # the same conservative widening.
            var p = ConvexPoly[3]()
            for vi in range(self.hulls[self.hull_id[i]].nv()):
                var v = self.hulls[self.hull_id[i]].vert(vi)
                var o = Vec3(
                    infl[0] if v[0] >= 0 else -infl[0],
                    infl[1] if v[1] >= 0 else -infl[1],
                    infl[2] if v[2] >= 0 else -infl[2],
                    0,
                )
                var w = v + o
                p.add(pose.position + ax[0] * w[0] + ax[1] * w[1] + ax[2] * w[2])
            return p^
        var hs = self.half[i] + infl
        if k == SHAPE_SPHERE:
            hs = Vec3(self.half[i][0] + mr, self.half[i][0] + mr, self.half[i][0] + mr, 0)
        elif k == SHAPE_CAPSULE:
            hs = Vec3(self.half[i][0] + mr, self.half[i][1] + self.half[i][0] + mr, self.half[i][0] + mr, 0)
        return HullShape.box(hs).world(pose.position, ax[0], ax[1], ax[2])

    def hull_is_bent_by_inflation(self, i: Int) -> Bool:
        """True for a HULL collider that is not a centred box: octant inflation
        would bend its faces, so the speculative margin goes to
        `hull_manifold` instead (see there)."""
        return self.shape[i] == SHAPE_HULL and not self.hulls[self.hull_id[i]].box_like

    def pair_manifold(
        self, i: Int, j: Int, pose_i: Pose3, pose_j: Pose3, mr: Real, infl: Vec3
    ) -> ContactManifold[3]:
        """Shape-pair dispatch (kinds normalised so a-kind <= b-kind; the
        manifold normal is flipped back when the pair had to be swapped).

        Callers must pre-filter out static-mesh kinds (SHAPE_TRIMESH /
        SHAPE_HEIGHTFIELD) -- `contact_gen.try_pair` routes those through
        `try_mesh_pair`'s triangle-candidate path before either shape can
        reach here (17.0f / F4a). What is left below is exhaustive over the
        remaining kinds {BOX, SPHERE, CAPSULE, HULL}: with ka <= kb, every
        pair through (0,0)-(2,3) is either an explicit branch or caught by
        `kb == SHAPE_HULL` (hull is the largest of the four, so that branch
        alone covers every hull combination), leaving exactly (CAPSULE,
        CAPSULE) for the explicit branch below -- an unrecognised pair past
        that point is a broken invariant upstream (a caller that let a mesh
        kind through), not a case this function can make sense of, so it
        aborts rather than guessing (docs/ARCHITECTURE.md error policy S2)."""
        var a = i
        var b = j
        var pa = pose_i.copy()
        var pb = pose_j.copy()
        var flip = False
        if self.shape[a] > self.shape[b]:
            a = j
            b = i
            pa = pose_j.copy()
            pb = pose_i.copy()
            flip = True
        var ka = self.shape[a]
        var kb = self.shape[b]
        var m: ContactManifold[3]
        if kb == SHAPE_ELLIPSOID:
            # ROADMAP 17.52: the largest kind, so always `b` here; computed
            # from the ellipsoid's side (exact shapes, the whole margin)
            m = self.ellipsoid_pair(b, pb, a, pa, mr * 2)
            m.normal = -m.normal
        elif ka == SHAPE_BOX and kb == SHAPE_BOX:
            m = box_box_manifold(
                pa.position, pa.axes, self.half[a] + infl,
                pb.position, pb.axes, self.half[b] + infl,
            )
        elif ka == SHAPE_BOX and kb == SHAPE_SPHERE:
            # sphere_box normal is sphere->box == b->a: flip once more
            m = sphere_box_manifold(
                pb.position, self.half[b][0] + mr,
                pa.position, pa.axes, self.half[a] + infl,
            )
            m.normal = -m.normal
        elif ka == SHAPE_BOX and kb == SHAPE_CAPSULE:
            m = capsule_box_manifold(
                pb.position, pb.axes[1],
                self.half[b][1], self.half[b][0] + mr,
                pa.position, pa.axes, self.half[a] + infl,
            )
            m.normal = -m.normal
        elif ka == SHAPE_SPHERE and kb == SHAPE_SPHERE:
            m = sphere_sphere_manifold(
                pa.position, self.half[a][0] + mr,
                pb.position, self.half[b][0] + mr,
            )
        elif ka == SHAPE_SPHERE and kb == SHAPE_CAPSULE:
            # capsule_sphere normal is capsule->sphere == b->a
            m = capsule_sphere_manifold(
                pb.position, pb.axes[1],
                self.half[b][1], self.half[b][0] + mr,
                pa.position, self.half[a][0] + mr,
            )
            m.normal = -m.normal
        elif kb == SHAPE_HULL:
            # any-vs-hull: both sides go through the convex point-cloud path.
            # Placed before capsule-capsule because the kinds are normalised
            # (ka <= kb) and hull is the highest kind BELOW the static mesh
            # kinds, so kb == SHAPE_HULL catches hull-box, hull-sphere,
            # hull-capsule and hull-hull alike.
            # A HULL side is not inflated by the speculative margin (inflation
            # bends the faces of any non-box hull -- see `hull_manifold`); its
            # share of the margin goes to `hull_manifold` as `spec` instead and
            # is added back to the depths, the convention `try_pair` expects.
            var zero = Vec3(0, 0, 0, 0)
            var spec = Real(0)
            var ia = infl
            var ma = mr
            var ib = infl
            var mb = mr
            if self.hull_is_bent_by_inflation(a):
                ia = zero
                ma = Real(0)
                spec += infl[0]
            if self.hull_is_bent_by_inflation(b):
                ib = zero
                mb = Real(0)
                spec += infl[0]
            m = hull_manifold(
                self.as_hull(a, pa, ia, ma), self.as_hull(b, pb, ib, mb),
                self.hull_faces(a, pa, ia, ma), self.hull_faces(b, pb, ib, mb),
                spec,
            )
            if spec > 0:
                for kk in range(m.count):
                    m.depths[kk] += spec
            # ROADMAP 17.52: a cylinder lying on a box touches it along its
            # curved side -- the capsule manifold of the same axis and radius
            # is exact there (the polygon hull would roll like a polygon).
            # Only when the hull normal is across the axis (|n . axis| < 0.5):
            # an end cap on the box stays on the hull path.
            if ka == SHAPE_BOX and self.round_radius(b) > 0 and m.hit:
                if abs(dot(m.normal, pb.axes[1])) < 0.5:
                    m = capsule_box_manifold(
                        pb.position, pb.axes[1],
                        self.half[b][1], self.round_radius(b) + mr,
                        pa.position, pa.axes, self.half[a] + infl,
                    )
                    m.normal = -m.normal
        elif ka == SHAPE_CAPSULE and kb == SHAPE_CAPSULE:
            m = capsule_capsule_manifold(
                pa.position, pa.axes[1], self.half[a][1], self.half[a][0] + mr,
                pb.position, pb.axes[1], self.half[b][1], self.half[b][0] + mr,
            )
        else:
            abort(
                "ColliderSet.pair_manifold: unsupported collider-kind pair ("
                + String(ka) + ", " + String(kb) + ") -- static mesh kinds"
                " must be routed through contact_gen.try_mesh_pair before"
                " reaching this exhaustive box/sphere/capsule/hull dispatch"
            )
        if flip and m.hit:
            m.normal = -m.normal
        return m

    def fat_aabb(
        self, i: Int, pose: Pose3, vel: Vec3, spec_dt: Real, margin_base: Real = SPEC_BASE
    ) -> AABB[3]:
        """World AABB of collider `i`'s oriented box (`half`, conservative for
        sphere/capsule too), grown by r_i = margin_base/2 + |v_i|*spec_dt.
        Chosen so r_i + r_j == the pair speculative margin exactly, hence
        fat-AABB overlap is a conservative superset of any inflated-OBB
        overlap (the broadphase parity guarantee).

        SHAPE_TRIMESH/SHAPE_HEIGHTFIELD are the exception: their `world_aabb`
        (set once at `add_trimesh`/`add_heightfield` time, world-space,
        ignoring the owning body's pose per the documented contract) is
        returned instead of a box centred on `pose.position` -- grown by the
        same r_i so the parity guarantee above still holds even though a
        static mesh never moves (17.0f / F3)."""
        var k = self.shape[i]
        if k == SHAPE_TRIMESH or k == SHAPE_HEIGHTFIELD or k == SHAPE_SDF:
            var r0 = Real(0)
            if spec_dt > 0:
                r0 = margin_base * 0.5 + sqrt(dot(vel, vel)) * spec_dt
            var bb = self.world_aabb[i]
            return AABB[3](
                bb.min - Vec3(r0, r0, r0, 0), bb.max + Vec3(r0, r0, r0, 0)
            )
        ref ax = pose.axes
        var h = self.half[i]
        if k == SHAPE_CAPSULE:
            # `half` is (r, half_len, r): the segment's box. The end caps
            # reach r further along the axis (ROADMAP 17.53 found a ray
            # hitting a cap outside this box).
            h[1] += h[0]
        var wh = Vec3(0, 0, 0, 0)
        comptime for k in range(3):
            wh[k] = (
                abs(ax[0][k]) * h[0]
                + abs(ax[1][k]) * h[1]
                + abs(ax[2][k]) * h[2]
            )
        var r = Real(0)
        if spec_dt > 0:
            r = margin_base * 0.5 + sqrt(dot(vel, vel)) * spec_dt
        return AABB[3].from_center(pose.position, wh + Vec3(r, r, r, 0))

    def soft_particle_contact(
        self, i: Int, pose: Pose3, p: Vec3, r: Real
    ) -> Tuple[Bool, Vec3, Vec3]:
        """Point-vs-shape closest point / signed distance for a soft-body
        particle of radius `r` centred at world point `p` against collider
        `i`, restricted to HULL/TRIMESH/HEIGHTFIELD -- box/sphere/capsule
        keep their own exact closed forms inline in
        `physics.solver6._softbody_pass` (17.0f / F4b: those three kinds
        used to be substituted with a sphere of radius `half.x` at the
        body's position, which for a level mesh is a sphere the size of the
        level). Returns (hit, target, normal): if `hit`, `target` is where
        the particle should be moved so it just touches the surface and
        `normal` is the outward push direction (unit length).

        HULL: SAT over the hull's own face planes (`HullShape.face` /
        `face_offset`, built once at construction) -- the same
        exact-on-a-face, approximate-at-an-edge-or-corner tradeoff
        `hull_manifold` already makes for rigid hull contacts.

        TRIMESH / HEIGHTFIELD: triangle CANDIDATES from the shared midphase
        (`mesh_candidates`) -- a heightfield's candidate lookup is already
        O(1) grid arithmetic (see `collision.trimesh`'s docstring), so there
        is no separate cheaper 'sample the height' path worth having; this
        reuses the identical candidate/tri/tri_faces calls the rigid mesh
        path uses -- then closest-point-on-triangle over the candidates,
        nearest one wins. Degenerate (zero-area) triangles are skipped, the
        same rule `try_mesh_pair` uses.

        ELLIPSOID (17.52): GJK distance from the particle centre to the
        exact support mapping; EPA when the centre is inside."""
        var k = self.shape[i]
        if k == SHAPE_ELLIPSOID:
            var se = self.support_ellipsoid(i, pose)
            var pt = SupportCapsule(p, Vec3(0, 1, 0, 0), 0, 0)
            var d = support_distance(pt, 0, se, 0)
            if d.dist >= r:
                return (False, p, Vec3(0, 1, 0, 0))
            if d.dist > 0:
                var n_out = -d.normal
                return (True, d.pb + n_out * r, n_out)
            var w = epa3(pt, se)
            var n_in = -w.normal
            return (True, w.point_b + n_in * r, n_in)
        if k == SHAPE_HULL:
            ref hs = self.hulls[self.hull_id[i]]
            var nf = hs.nf()
            if nf == 0:
                return (False, p, Vec3(0, 1, 0, 0))
            ref ax = pose.axes
            var d = p - pose.position
            var lp = Vec3(dot(d, ax[0]), dot(d, ax[1]), dot(d, ax[2]), 0)
            var best = Real(-1e30)
            var best_f = -1
            for f in range(nf):
                var n = hs.face(f)
                var raw = dot(lp, n) - hs.face_offset(f)
                if raw > best:
                    best = raw
                    best_f = f
            if best_f < 0 or best > r:
                return (False, p, Vec3(0, 1, 0, 0))
            var n = hs.face(best_f)
            var lp2 = lp + n * (r - best)
            var wn = ax[0] * n[0] + ax[1] * n[1] + ax[2] * n[2]
            var target = (
                pose.position + ax[0] * lp2[0] + ax[1] * lp2[1] + ax[2] * lp2[2]
            )
            return (True, target, wn)
        if k == SHAPE_SDF:
            ref g = self.sdfs[self.mesh_id[i]]
            var dd = g.distance(p)
            if dd >= r:
                return (False, p, Vec3(0, 1, 0, 0))
            var gn = g.gradient(p)
            var gl = sqrt(dot(gn, gn))
            var nn = gn / gl if gl > 1e-12 else Vec3(0, 1, 0, 0)
            return (True, p + nn * (r - dd), nn)
        if k == SHAPE_TRIMESH or k == SHAPE_HEIGHTFIELD:
            var wide = Vec3(r, r, r, 0)
            var box = AABB[3](p - wide, p + wide)
            var tris = List[Int]()
            self.mesh_candidates(i, box, tris)
            var best_d2 = r * r
            var best_pt = p
            var best_n = Vec3(0, 1, 0, 0)
            var hit = False
            for c in range(len(tris)):
                var t = tris[c]
                var tf = self.mesh_tri_faces(i, t)
                if len(tf) < 3:
                    continue  # degenerate triangle: no normal, no contact
                var tri = self.mesh_tri(i, t)
                if len(tri.points) < 3:
                    continue
                var cp = closest_point_on_triangle(
                    p, tri.points[0], tri.points[1], tri.points[2]
                )
                var dvec = p - cp
                var d2 = dot(dvec, dvec)
                if d2 < best_d2:
                    best_d2 = d2
                    best_pt = cp
                    best_n = Vec3(tf[0], tf[1], tf[2], 0)
                    hit = True
            if not hit:
                return (False, p, Vec3(0, 1, 0, 0))
            var dist = sqrt(best_d2)
            var n: Vec3
            if dist > 1e-9:
                n = (p - best_pt) * (1 / dist)
                # `p - cp` points the wrong way when the particle has already
                # sunk past the surface (cp is then roughly below p along the
                # triangle's own normal) -- fall back to the triangle's face
                # normal, the same disambiguation `try_mesh_pair` gets for
                # free from SAT over both shapes' faces.
                if dot(n, best_n) < 0:
                    n = best_n
            else:
                n = best_n
            var target = best_pt + n * r
            return (True, target, n)
        return (False, p, Vec3(0, 1, 0, 0))
