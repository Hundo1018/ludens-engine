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
from geometry.vec import Real, Vec3, dot
from geometry.aabb import AABB
from geometry.gjk import ConvexPoly
from .hull import HullShape, hull_manifold
from .trimesh import TriMesh, HeightField
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
        self.category = List[UInt32]()
        self.mask = List[UInt32]()
        self.sensor = List[Bool]()

    # ------------------------------------------------------------ registry

    def add(mut self, half: Vec3) -> Int:
        """Register a box collider (the default kind); returns its index."""
        self.shape.append(SHAPE_BOX)
        self.half.append(half)
        self.hull_id.append(-1)
        self.mesh_id.append(-1)
        self.category.append(1)
        self.mask.append(0xFFFFFFFF)
        self.sensor.append(False)
        return len(self.shape) - 1

    def add_sphere(mut self, r: Real) -> Int:
        var i = self.add(Vec3(r, r, r, 0))
        self.shape[i] = SHAPE_SPHERE
        return i

    def add_capsule(mut self, r: Real, half_len: Real) -> Int:
        # conservative box for any AABB-ish uses: r sideways, r+hl tall
        var i = self.add(Vec3(r, half_len, r, 0))
        self.shape[i] = SHAPE_CAPSULE
        return i

    def add_hull(mut self, var verts: List[Real]) -> Int:
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
        var i = self.add(h)
        self.shape[i] = SHAPE_HULL
        self.hull_id[i] = len(self.hulls)
        self.hulls.append(HullShape(verts^))
        return i

    def add_trimesh(mut self, verts: List[Real], indices: List[Int]) -> Int:
        """Static triangle soup. `verts` is flat (x, y, z per vertex) in
        WORLD space, `indices` three per triangle. Always static (see
        `physics.solver6.ContactScene6.add_trimesh`).

        # 17.0f: `half`/`fat_aabb` centre this on the OWNING BODY's pose
        # (`Pose3.position`), but these vertices are already world-space and
        # the body pose is meant to be ignored for kinds 4/5 (F3 in
        # .campaign/arch_audit.md). A level added at a non-origin body pose
        # is culled wrong under `broadphase=True`. Not fixed here (17.0e is
        # behaviour-preserving); fix alongside the other three shape bugs."""
        var m = TriMesh(verts, indices)
        var bb = m.bounds()
        var i = self.add(bb.half_extents())
        self.shape[i] = SHAPE_TRIMESH
        self.mesh_id[i] = len(self.meshes)
        self.meshes.append(m^)
        return i

    def add_heightfield(
        mut self, heights: List[Real], nx: Int, nz: Int,
        cell: Real, ox: Real = 0, oz: Real = 0,
    ) -> Int:
        """Static heightfield -- see `add_trimesh`; same # 17.0f note (F3)
        applies to the body-pose-vs-world-vertices mismatch."""
        var f = HeightField(heights, nx, nz, cell, ox, oz)
        var bb = f.bounds()
        var i = self.add(bb.half_extents())
        self.shape[i] = SHAPE_HEIGHTFIELD
        self.mesh_id[i] = len(self.fields)
        self.fields.append(f^)
        return i

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

    def pair_manifold(
        self, i: Int, j: Int, pose_i: Pose3, pose_j: Pose3, mr: Real, infl: Vec3
    ) -> ContactManifold[3]:
        """Shape-pair dispatch (kinds normalised so a-kind <= b-kind; the
        manifold normal is flipped back when the pair had to be swapped).

        # 17.0f: the final `else` below is a catch-all that treats any kind
        # combination it does not recognise as capsule-capsule (F4a). It is
        # only reachable today when a caller skips the `shape >= SHAPE_TRIMESH`
        # mesh check before calling this (`contact_gen.try_pair`'s sensor
        # short-circuit does exactly that) -- fix both sites together."""
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
        if ka == SHAPE_BOX and kb == SHAPE_BOX:
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
            m = hull_manifold(
                self.as_hull(a, pa, infl, mr), self.as_hull(b, pb, infl, mr),
                self.hull_faces(a, pa, infl, mr), self.hull_faces(b, pb, infl, mr),
            )
        else:  # capsule-capsule (see the # 17.0f note above the function)
            m = capsule_capsule_manifold(
                pa.position, pa.axes[1], self.half[a][1], self.half[a][0] + mr,
                pb.position, pb.axes[1], self.half[b][1], self.half[b][0] + mr,
            )
        if flip and m.hit:
            m.normal = -m.normal
        return m

    def fat_aabb(self, i: Int, pose: Pose3, vel: Vec3, spec_dt: Real) -> AABB[3]:
        """World AABB of collider `i`'s oriented box (`half`, conservative for
        sphere/capsule too), grown by r_i = SPEC_BASE/2 + |v_i|*spec_dt.
        Chosen so r_i + r_j == the pair speculative margin exactly, hence
        fat-AABB overlap is a conservative superset of any inflated-OBB
        overlap (the broadphase parity guarantee).

        # 17.0f: for kinds SHAPE_TRIMESH/SHAPE_HEIGHTFIELD this centres the
        # box on `pose.position` (the owning body's pose), which the mesh's
        # own world-space vertices are supposed to ignore -- same bug as
        # `add_trimesh`'s note (F3)."""
        comptime SPEC_BASE: Real = 0.02
        ref ax = pose.axes
        var h = self.half[i]
        var wh = Vec3(0, 0, 0, 0)
        comptime for k in range(3):
            wh[k] = (
                abs(ax[0][k]) * h[0]
                + abs(ax[1][k]) * h[1]
                + abs(ax[2][k]) * h[2]
            )
        var r = Real(0)
        if spec_dt > 0:
            r = SPEC_BASE * 0.5 + sqrt(dot(vel, vel)) * spec_dt
        return AABB[3].from_center(pose.position, wh + Vec3(r, r, r, 0))
