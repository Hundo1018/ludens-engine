"""6-DOF contact solving: `ContactManifold` points -> sequential impulses.

This is the first angular contact response in the engine — the piece
`physics/rigidbody.mojo` explicitly deferred until the narrowphase produced
contact points. `ContactScene6[B]` is generic over the `Body6` representation
(quat+tensor or motor+screw), so the same scene is a parity gate between the
classical and the GA path.

Two step modes share the collision prep:

  * `step` — one-shot: gravity -> manifolds -> Gauss-Seidel accumulated
    normal impulses with a Baumgarte velocity bias -> pose integration.
  * `step_soft` — SUB-STEPPED SOFT-CONSTRAINT solver (Box2D v3 "Soft Step" /
    Small Steps): collide once per frame, then n substeps of {integrate
    velocities -> soft-biased impulse sweeps -> integrate poses -> a bias-free
    RELAX sweep that removes the bias energy}. Contact separation is updated
    across substeps from body translation along the normal (rotation term
    neglected — small per substep). Soft coefficients follow Solver2D:
    ω = 2π·hertz, biasRate = ω/(2ζ + hω), c = hω(2ζ + hω),
    massScale = c/(1+c), impulseScale = 1/(1+c).

`step_soft` also solves Coulomb friction (two tangent impulses per point,
clamped to μ·λₙ) — without it, box spin is undamped and, since the box
narrowphase is axis-aligned, geometrically unconstrained. Restitution is still
deferred (e = 0 scenes).
"""

from std.math import sqrt
from std.algorithm import parallelize
from geometry.vec import Real, Vec3, dot
from geometry.aabb import AABB
from geometry.bvh import BVH
from geometry.gjk import ConvexPoly
from collision.hull import HullShape, hull_manifold
from collision.trimesh import TriMesh, HeightField
from collision.manifold import (
    ContactManifold,
    Axes3,
    box_box_manifold,
    sphere_sphere_manifold,
    sphere_box_manifold,
    capsule_box_manifold,
    capsule_capsule_manifold,
    capsule_sphere_manifold,
)
from collision.toi import swept_box_toi
from .rigid6 import Body6
from .softbody import SoftBody

comptime _BETA: Real = 0.2  # Baumgarte position-correction gain
comptime _SLOP: Real = 0.005  # allowed penetration


@fieldwise_init
struct _CPair(Copyable, ImplicitlyCopyable, Movable):
    var a: Int
    var b: Int
    # Sub-key within the pair. Zero for shape-vs-shape, which produces one
    # manifold; for static mesh contact it is the triangle index, because one
    # crate resting on a level touches several triangles at once and each is a
    # separate manifold. Without it every one of them would inherit the first
    # cached entry's impulses and warm-starting would fight itself.
    var feat: Int
    var m: ContactManifold[3]
    var acc: InlineArray[Real, 4]  # per-point accumulated normal impulse
    var acc_t1: InlineArray[Real, 4]  # accumulated friction impulses
    var acc_t2: InlineArray[Real, 4]
    # Body-frame contact anchors (Box2D scheme): both coincide with the
    # manifold point at prep; per-substep world separation is re-derived from
    # the CURRENT poses, so tilting a body deepens its near edge and the bias
    # produces a restoring torque (frozen depths cannot — towers slowly tip).
    var ra: InlineArray[Vec3, 4]
    var rb: InlineArray[Vec3, 4]
    # Restitution (Box2D v3 scheme): the approach speed captured at prep time
    # drives a dedicated post-substep pass toward v_target = -e·vn0. Neither
    # field is warm-start-inherited — both are per-frame.
    var vn0: InlineArray[Real, 4]
    var racc: InlineArray[Real, 4]


@fieldwise_init
struct ContactEvent(Copyable, ImplicitlyCopyable, Movable):
    """One transition in the contact set. `kind` is 0 began / 1 stay / 2 ended.

    `feat` is the triangle index for mesh contacts and 0 otherwise, the same
    sub-key the warm-start cache uses: a crate sliding along a floor genuinely
    begins and ends contact with each triangle in turn, and collapsing that to
    one event per body pair would report a single unbroken touch."""

    var a: Int
    var b: Int
    var feat: Int
    var kind: Int


comptime _EV_BEGAN = 0
comptime _EV_STAY = 1
comptime _EV_ENDED = 2


def _ckey(a: Int, b: Int, feat: Int) -> Int:
    """(body, body, feature) packed into one Int so the frame-to-frame diff is
    a sorted-list merge. 21 bits each: 2M bodies, 2M triangles per mesh."""
    return (a << 42) | (b << 21) | feat


def _sort_keys(mut k: List[Int]):
    """Bottom-up merge sort. The event stream has to be in a canonical order,
    not in whatever order the broadphase happened to enumerate pairs, or the
    same scene would report the same events differently depending on which
    collision seam it ran through."""
    var n = len(k)
    if n < 2:
        return
    var buf = List[Int](capacity=n)
    for i in range(n):
        buf.append(k[i])
    var width = 1
    while width < n:
        var i = 0
        while i < n:
            var mid = min(i + width, n)
            var hi = min(i + 2 * width, n)
            var l = i
            var r = mid
            var o = i
            while l < mid and r < hi:
                if k[l] <= k[r]:
                    buf[o] = k[l]
                    l += 1
                else:
                    buf[o] = k[r]
                    r += 1
                o += 1
            while l < mid:
                buf[o] = k[l]
                l += 1
                o += 1
            while r < hi:
                buf[o] = k[r]
                r += 1
                o += 1
            i += 2 * width
        for j in range(n):
            k[j] = buf[j]
        width *= 2


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return Vec3(
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def _tangent_basis(n: Vec3) -> Tuple[Vec3, Vec3]:
    """Two unit tangents perpendicular to `n` (and each other)."""
    var seed = Vec3(0, 1, 0) if abs(n[0]) > 0.9 else Vec3(1, 0, 0)
    var t1 = _cross(seed, n)
    t1 = t1 / sqrt(max(dot(t1, t1), Real(1e-12)))
    return (t1, _cross(n, t1))


@fieldwise_init
struct _Half(Copyable, ImplicitlyCopyable, Movable):
    """Struct-wrapped Vec3: a bare `List[SIMD[_, 3]]` corrupts on realloc
    (documented nightly hazard, see geometry/gjk.mojo)."""

    var v: Vec3


comptime JOINT_BALL = 0
comptime JOINT_DISTANCE = 1
comptime JOINT_HINGE = 2


@fieldwise_init
struct Joint6(Copyable, ImplicitlyCopyable, Movable):
    """A two-body joint solved in the soft substep loop (equality constraints,
    no cone clamp). `kind`: ball (anchors coincide), distance (anchor gap =
    rest), hinge (ball + the two local axes stay aligned)."""

    var kind: Int
    var a: Int
    var b: Int
    var la: Vec3  # anchor in a's body frame
    var lb: Vec3
    var rest: Real  # distance joint rest length
    var axis_a: Vec3  # hinge axis in each body frame
    var axis_b: Vec3
    var acc: Vec3  # accumulated linear impulse (distance uses acc[0])
    var acc_ang: Vec3  # accumulated angular impulse (hinge tangents)

    @staticmethod
    def ball(a: Int, b: Int, la: Vec3, lb: Vec3) -> Self:
        return Self(
            JOINT_BALL, a, b, la, lb, 0,
            Vec3(0, 0, 1), Vec3(0, 0, 1), Vec3(0, 0, 0), Vec3(0, 0, 0),
        )

    @staticmethod
    def distance(a: Int, b: Int, la: Vec3, lb: Vec3, rest: Real) -> Self:
        return Self(
            JOINT_DISTANCE, a, b, la, lb, rest,
            Vec3(0, 0, 1), Vec3(0, 0, 1), Vec3(0, 0, 0), Vec3(0, 0, 0),
        )

    @staticmethod
    def hinge(a: Int, b: Int, la: Vec3, lb: Vec3, axis: Vec3) -> Self:
        return Self(
            JOINT_HINGE, a, b, la, lb, 0,
            axis, axis, Vec3(0, 0, 0), Vec3(0, 0, 0),
        )


struct ContactScene6[B: Body6](Movable, ImplicitlyDeletable):
    """Boxes (dynamic or static) under gravity with contact impulses."""

    var bodies: List[Self.B]
    var half: List[_Half]  # box half-extents, parallel to `bodies`
    var statics: List[Bool]
    var cache: List[_CPair]  # last frame's pairs (cross-frame warm starting)
    var joints: List[Joint6]
    var sleeping: List[Bool]
    var sleep_timer: List[Real]
    var island: List[Int]  # island label per body (last step; -1 = static)
    var softs: List[SoftBody]
    var restitution: List[Real]  # per-body coefficient (pair uses max)
    # shape kind per body: 0 = box(half), 1 = sphere(r = half.x),
    # 2 = capsule (r = half.x, half-length = half.y, local Y axis),
    # 3 = convex hull (`hull_id`), 4 = triangle mesh, 5 = heightfield
    # (both `mesh_id`, both static-only)
    var shape: List[Int]
    # Convex hulls, indexed by `hull_id[i]` (-1 when body i is not a hull).
    # A side table rather than a field on every body: hulls are rare and carry
    # a vertex list, so paying for one on every sphere would be wasteful.
    var hulls: List[HullShape]
    var hull_id: List[Int]
    # Static level geometry (kinds 4 and 5), same side-table scheme. Their
    # vertices are WORLD space and their body pose is ignored: a level does not
    # move, and keeping the triangles pre-transformed is the whole reason the
    # midphase query can be a plain AABB test.
    var meshes: List[TriMesh]
    var fields: List[HeightField]
    var mesh_id: List[Int]
    # Collision filtering, Box2D's scheme: two bodies collide when each one's
    # category is in the other's mask. Applied at the top of `_try_pair`, which
    # is the single point both the brute and the broadphase enumeration funnel
    # through — so a filtered pair costs one AND on either seam, and the two
    # cannot disagree about what was filtered.
    var category: List[UInt32]
    var mask: List[UInt32]
    # A sensor reports overlap and never receives an impulse. Its pairs are
    # collected separately rather than flagged in `pairs`, so that not one of
    # the solve, warm-start, island or restitution loops needs to learn about
    # them.
    var sensor: List[Bool]
    var sensor_pairs: List[_CPair]
    # Contact events, rebuilt every step when `events` is on. Off by default:
    # the diff sorts the contact set, which is real work for a scene that never
    # reads the result.
    var events_on: Bool
    var events: List[ContactEvent]
    var _prev_keys: List[Int]

    def __init__(out self):
        self.bodies = List[Self.B]()
        self.hulls = List[HullShape]()
        self.hull_id = List[Int]()
        self.meshes = List[TriMesh]()
        self.fields = List[HeightField]()
        self.mesh_id = List[Int]()
        self.category = List[UInt32]()
        self.mask = List[UInt32]()
        self.sensor = List[Bool]()
        self.sensor_pairs = List[_CPair]()
        self.events_on = False
        self.events = List[ContactEvent]()
        self._prev_keys = List[Int]()
        self.half = List[_Half]()
        self.statics = List[Bool]()
        self.cache = List[_CPair]()
        self.joints = List[Joint6]()
        self.sleeping = List[Bool]()
        self.sleep_timer = List[Real]()
        self.island = List[Int]()
        self.softs = List[SoftBody]()
        self.restitution = List[Real]()
        self.shape = List[Int]()

    def add_soft(mut self, var sb: SoftBody) -> Int:
        self.softs.append(sb^)
        return len(self.softs) - 1

    def add_joint(mut self, j: Joint6) -> Int:
        self.joints.append(j)
        return len(self.joints) - 1

    def island_count(self) -> Int:
        """Number of distinct dynamic islands from the last `step_soft`."""
        var seen = List[Int]()
        for i in range(len(self.island)):
            if self.island[i] < 0:
                continue
            var known = False
            for j in range(len(seen)):
                if seen[j] == self.island[i]:
                    known = True
                    break
            if not known:
                seen.append(self.island[i])
        return len(seen)

    def _find(self, mut parent: List[Int], i: Int) -> Int:
        var r = i
        while parent[r] != r:
            var pr = parent[r]
            var gp = parent[pr]  # path halving
            parent[r] = gp
            r = gp
        return r

    def _refresh_islands(mut self, pairs: List[_CPair]):
        """Union-find over the constraint graph (contacts + joints between
        dynamic bodies; statics do not merge islands), then the wake rule:
        an island with ANY awake member wakes entirely."""
        var n = len(self.bodies)
        var parent = List[Int]()
        for i in range(n):
            parent.append(i)
        for c in range(len(pairs)):
            var a = pairs[c].a
            var b = pairs[c].b
            if not self.statics[a] and not self.statics[b]:
                parent[self._find(parent, a)] = self._find(parent, b)
        for c in range(len(self.joints)):
            var a = self.joints[c].a
            var b = self.joints[c].b
            if not self.statics[a] and not self.statics[b]:
                parent[self._find(parent, a)] = self._find(parent, b)
        # labels + island-wide wake
        while len(self.island) < n:
            self.island.append(-1)
        for i in range(n):
            self.island[i] = -1 if self.statics[i] else self._find(parent, i)
        for i in range(n):
            if self.statics[i] or self.sleeping[i]:
                continue
            # island member i is awake -> wake everyone sharing its label
            for j in range(n):
                if self.island[j] == self.island[i] and self.sleeping[j]:
                    self.sleeping[j] = False
                    self.sleep_timer[j] = 0

    def _update_sleep(mut self, dt: Real):
        """Advance per-body still-timers; a whole island sleeps together."""
        comptime LIN_TOL: Real = 0.01
        comptime ANG_TOL: Real = 0.05
        comptime SLEEP_TIME: Real = 0.5
        var n = len(self.bodies)
        for i in range(n):
            if self.statics[i] or self.sleeping[i]:
                continue
            var v = self.bodies[i].linear_velocity()
            var w = self.bodies[i].omega_world()
            if dot(v, v) < LIN_TOL * LIN_TOL and dot(w, w) < ANG_TOL * ANG_TOL:
                self.sleep_timer[i] += dt
            else:
                self.sleep_timer[i] = 0
        # sleep islands whose every member has been still long enough
        for i in range(n):
            if self.statics[i] or self.sleeping[i]:
                continue
            var all_still = True
            for j in range(n):
                if self.island[j] == self.island[i] and self.sleep_timer[
                    j
                ] < SLEEP_TIME:
                    all_still = False
                    break
            if all_still:
                for j in range(n):
                    if self.island[j] == self.island[i]:
                        self.sleeping[j] = True
                        self.bodies[j].halt()

    def add(mut self, var b: Self.B, half: Vec3, is_static: Bool) -> Int:
        self.bodies.append(b^)
        self.half.append(_Half(half))
        self.statics.append(is_static)
        self.sleeping.append(False)
        self.sleep_timer.append(0)
        self.island.append(-1)
        self.restitution.append(0)
        self.shape.append(0)
        self.hull_id.append(-1)
        self.mesh_id.append(-1)
        self.category.append(1)
        self.mask.append(0xFFFFFFFF)
        self.sensor.append(False)
        return len(self.bodies) - 1

    def add_sphere(mut self, var b: Self.B, r: Real, is_static: Bool) -> Int:
        var i = self.add(b^, Vec3(r, r, r), is_static)
        self.shape[i] = 1
        return i

    def add_capsule(
        mut self, var b: Self.B, r: Real, half_len: Real, is_static: Bool
    ) -> Int:
        # conservative box for any AABB-ish uses: r sideways, r+hl tall
        var i = self.add(b^, Vec3(r, half_len, r), is_static)
        self.shape[i] = 2
        return i

    def add_hull(
        mut self, var b: Self.B, var verts: List[Real], is_static: Bool
    ) -> Int:
        """A convex body given by its LOCAL-frame vertices, FLAT (x, y, z per
        vertex). Flat rather than `List[Vec3]` because a width-3 list is
        miscompiled when passed between functions on this nightly — the reason
        is measured out in `collision/hull.mojo`.

        The `half` extent recorded is the vertex cloud's bounding half-size, so
        every AABB-based path (broadphase fattening, sleeping, islands) keeps
        working unchanged and conservatively — a hull is never smaller than the
        box the rest of the engine already reasons about."""
        var h = Vec3(0, 0, 0)
        for vi in range(len(verts) // 3):
            comptime for k in range(3):
                if abs(verts[3 * vi + k]) > h[k]:
                    h[k] = abs(verts[3 * vi + k])
        var i = self.add(b^, h, is_static)
        self.shape[i] = 3
        self.hull_id[i] = len(self.hulls)
        self.hulls.append(HullShape(verts^))
        return i

    def add_trimesh(
        mut self, var b: Self.B, verts: List[Real], indices: List[Int]
    ) -> Int:
        """Static triangle soup. `verts` is flat (x, y, z per vertex) in WORLD
        space, `indices` three per triangle.

        Always static. A mesh has no useful inertia tensor and no closed
        volume, so a dynamic one would be resolved against by contacts that
        cannot conserve anything; refusing it here is cheaper than discovering
        it as drift. The recorded `half` is the mesh's bounding half-size, so
        broadphase, sleeping and islands keep working unchanged."""
        var m = TriMesh(verts, indices)
        var bb = m.bounds()
        var i = self.add(b^, bb.half_extents(), True)
        self.shape[i] = 4
        self.mesh_id[i] = len(self.meshes)
        self.meshes.append(m^)
        return i

    def add_heightfield(
        mut self, var b: Self.B, heights: List[Real], nx: Int, nz: Int,
        cell: Real, ox: Real = 0, oz: Real = 0,
    ) -> Int:
        """Static heightfield: the same surface as a mesh, with the triangles
        left implicit and the midphase reduced to arithmetic. Static for the
        same reason as `add_trimesh`."""
        var f = HeightField(heights, nx, nz, cell, ox, oz)
        var bb = f.bounds()
        var i = self.add(b^, bb.half_extents(), True)
        self.shape[i] = 5
        self.mesh_id[i] = len(self.fields)
        self.fields.append(f^)
        return i

    def set_filter(mut self, i: Int, category: UInt32, mask: UInt32):
        """Which layer body `i` is on, and which layers it collides with.

        Symmetric by construction: both directions must agree, so "players do
        not hit players" is one bit cleared, not a rule that has to be repeated
        on every other body."""
        self.category[i] = category
        self.mask[i] = mask

    def set_sensor(mut self, i: Int, on: Bool):
        """A sensor overlaps but never pushes: it reports contact events and is
        skipped by every solve pass. Trigger volumes are the point."""
        self.sensor[i] = on

    def _should_collide(self, i: Int, j: Int) -> Bool:
        return (self.category[i] & self.mask[j]) != 0 and (
            self.category[j] & self.mask[i]
        ) != 0

    def _mesh_candidates(self, i: Int, box: AABB[3], mut out: List[Int]):
        """Triangles of static body `i` that could touch `box`. The two static
        kinds answer this differently — BVH descent vs cell arithmetic — and
        that is the only place they differ; everything downstream is shared."""
        if self.shape[i] == 4:
            self.meshes[self.mesh_id[i]].candidates(box, out)
        else:
            self.fields[self.mesh_id[i]].candidates(box, out)

    def _mesh_tri(self, i: Int, t: Int) -> ConvexPoly[3]:
        if self.shape[i] == 4:
            return self.meshes[self.mesh_id[i]].tri(t)
        return self.fields[self.mesh_id[i]].tri(t)

    def _mesh_tri_faces(self, i: Int, t: Int) -> List[Real]:
        if self.shape[i] == 4:
            return self.meshes[self.mesh_id[i]].tri_faces(t)
        return self.fields[self.mesh_id[i]].tri_faces(t)

    def _hull_world(self, i: Int) -> ConvexPoly[3]:
        var ax = self._axes(i)
        return self.hulls[self.hull_id[i]].world(
            self.bodies[i].position(), ax[0], ax[1], ax[2]
        )

    def _hull_faces(self, i: Int, infl: Vec3, mr: Real) -> List[Real]:
        """World-frame face normals for body `i` under the same shape
        substitution `_as_hull` makes. Needed because EPA's normal is only as
        good as its polytope, and the contact patch depends on snapping it to a
        real face (see `collision/hull.mojo`)."""
        var ax = self._axes(i)
        var k = self.shape[i]
        if k == 3:
            return self.hulls[self.hull_id[i]].world_normals(ax[0], ax[1], ax[2])
        var hs = self.half[i].v + infl
        if k == 1:
            hs = Vec3(self.half[i].v[0] + mr, self.half[i].v[0] + mr, self.half[i].v[0] + mr)
        elif k == 2:
            hs = Vec3(self.half[i].v[0] + mr, self.half[i].v[1] + self.half[i].v[0] + mr, self.half[i].v[0] + mr)
        return HullShape.box(hs).world_normals(ax[0], ax[1], ax[2])

    def _as_hull(self, i: Int, infl: Vec3, mr: Real) -> ConvexPoly[3]:
        """Any supported shape as a convex point cloud, so the hull path can
        meet box/sphere/capsule without a separate routine per pairing.

        Spheres and capsules are only APPROXIMATED here (a sphere has no
        vertices), so they keep their own exact routines in `_pair_manifold`
        and this is used solely for hull-vs-* pairs, where an approximation of
        the round side is still better than no contact at all. The limitation
        is stated rather than hidden: `test_hull` asserts hull-vs-box exactly
        and hull-vs-sphere only within the polygonal tolerance."""
        var ax = self._axes(i)
        var k = self.shape[i]
        if k == 3:
            # Inflate the hull the same way the box path inflates its boxes,
            # by pushing each vertex out along its own octant. For a box hull
            # this reproduces `half + infl` exactly; for a general hull it is
            # the same conservative widening. Without it a hull rests measurably
            # deeper than an identical box, because the box pair reports an
            # inflated penetration on BOTH sides and settles shallower.
            var p = ConvexPoly[3]()
            for vi in range(self.hulls[self.hull_id[i]].nv()):
                var v = self.hulls[self.hull_id[i]].vert(vi)
                var o = Vec3(
                    infl[0] if v[0] >= 0 else -infl[0],
                    infl[1] if v[1] >= 0 else -infl[1],
                    infl[2] if v[2] >= 0 else -infl[2],
                )
                var w = v + o
                p.add(
                    self.bodies[i].position()
                    + ax[0] * w[0] + ax[1] * w[1] + ax[2] * w[2]
                )
            return p^
        var hs = self.half[i].v + infl
        if k == 1:
            hs = Vec3(self.half[i].v[0] + mr, self.half[i].v[0] + mr, self.half[i].v[0] + mr)
        elif k == 2:
            hs = Vec3(self.half[i].v[0] + mr, self.half[i].v[1] + self.half[i].v[0] + mr, self.half[i].v[0] + mr)
        return HullShape.box(hs).world(
            self.bodies[i].position(), ax[0], ax[1], ax[2]
        )

    def set_restitution(mut self, i: Int, e: Real):
        self.restitution[i] = e

    def _inactive(self, i: Int) -> Bool:
        return self.statics[i] or self.sleeping[i]

    def _solve_point(
        mut self,
        ia: Int,
        ib: Int,
        n: Vec3,
        p: Vec3,
        depth: Real,
        dt: Real,
        acc: Real,
    ) -> Real:
        """One accumulated-impulse Gauss-Seidel update; returns the new
        accumulated normal impulse (clamped >= 0, so later sweeps can remove
        an earlier over-push — without this the solve order injects a net
        torque and resting boxes slowly rotate)."""
        var va = Vec3(0, 0, 0)
        var ka = Real(0)
        if not self.statics[ia]:
            va = self.bodies[ia].velocity_at(p)
            ka = self.bodies[ia].inv_mass() + self.bodies[ia].angular_factor(
                p - self.bodies[ia].position(), n
            )
        var vb = Vec3(0, 0, 0)
        var kb = Real(0)
        if not self.statics[ib]:
            vb = self.bodies[ib].velocity_at(p)
            kb = self.bodies[ib].inv_mass() + self.bodies[ib].angular_factor(
                p - self.bodies[ib].position(), n
            )
        var denom = ka + kb
        if denom <= 0:
            return acc
        var vn = dot(vb - va, n)  # >0 means separating (n points a -> b)
        var bias = _BETA / dt * max(depth - _SLOP, 0)
        var new_acc = max(acc + (bias - vn) / denom, 0)
        var dl = new_acc - acc
        if dl == 0:
            return acc
        var j = n * dl
        if not self.statics[ia]:
            self.bodies[ia].apply_impulse(-j, p)
        if not self.statics[ib]:
            self.bodies[ib].apply_impulse(j, p)
        return new_acc

    def _axes(self, i: Int) -> Axes3:
        """World-frame box axes of body `i` (via `act`, representation-free)."""
        var o = self.bodies[i].act(Vec3(0, 0, 0))
        var out = InlineArray[Vec3, 3](fill=Vec3(0, 0, 0))
        out[0] = self.bodies[i].act(Vec3(1, 0, 0)) - o
        out[1] = self.bodies[i].act(Vec3(0, 1, 0)) - o
        out[2] = self.bodies[i].act(Vec3(0, 0, 1)) - o
        return out

    def _pair_manifold(
        self, i: Int, j: Int, mr: Real, infl: Vec3
    ) -> ContactManifold[3]:
        """Shape-pair dispatch (kinds normalised so a-kind <= b-kind; the
        manifold normal is flipped back when the pair had to be swapped)."""
        var a = i
        var b = j
        var flip = False
        if self.shape[a] > self.shape[b]:
            a = j
            b = i
            flip = True
        var ka = self.shape[a]
        var kb = self.shape[b]
        var m = ContactManifold[3].miss()
        if ka == 0 and kb == 0:
            m = box_box_manifold(
                self.bodies[a].position(), self._axes(a), self.half[a].v + infl,
                self.bodies[b].position(), self._axes(b), self.half[b].v + infl,
            )
        elif ka == 0 and kb == 1:
            # sphere_box normal is sphere->box == b->a: flip once more
            m = sphere_box_manifold(
                self.bodies[b].position(), self.half[b].v[0] + mr,
                self.bodies[a].position(), self._axes(a), self.half[a].v + infl,
            )
            m.normal = -m.normal
        elif ka == 0 and kb == 2:
            m = capsule_box_manifold(
                self.bodies[b].position(), self._axes(b)[1],
                self.half[b].v[1], self.half[b].v[0] + mr,
                self.bodies[a].position(), self._axes(a), self.half[a].v + infl,
            )
            m.normal = -m.normal
        elif ka == 1 and kb == 1:
            m = sphere_sphere_manifold(
                self.bodies[a].position(), self.half[a].v[0] + mr,
                self.bodies[b].position(), self.half[b].v[0] + mr,
            )
        elif ka == 1 and kb == 2:
            # capsule_sphere normal is capsule->sphere == b->a
            m = capsule_sphere_manifold(
                self.bodies[b].position(), self._axes(b)[1],
                self.half[b].v[1], self.half[b].v[0] + mr,
                self.bodies[a].position(), self.half[a].v[0] + mr,
            )
            m.normal = -m.normal
        elif kb == 3:
            # any-vs-hull: both sides go through the convex point-cloud path.
            # Placed before capsule-capsule because the kinds are normalised
            # (ka <= kb) and hull is the highest kind, so kb == 3 catches
            # hull-box, hull-sphere, hull-capsule and hull-hull alike.
            m = hull_manifold(
                self._as_hull(a, infl, mr), self._as_hull(b, infl, mr),
                self._hull_faces(a, infl, mr), self._hull_faces(b, infl, mr),
            )
        else:  # capsule-capsule
            m = capsule_capsule_manifold(
                self.bodies[a].position(), self._axes(a)[1],
                self.half[a].v[1], self.half[a].v[0] + mr,
                self.bodies[b].position(), self._axes(b)[1],
                self.half[b].v[1], self.half[b].v[0] + mr,
            )
        if flip and m.hit:
            m.normal = -m.normal
        return m

    def _fat_aabb(self, i: Int, spec_dt: Real) -> AABB[3]:
        """World AABB of body `i`'s oriented box (`half`, conservative for
        sphere/capsule too), grown by r_i = SPEC_BASE/2 + |v_i|·spec_dt.
        Chosen so r_i + r_j == the pair speculative margin exactly, hence
        fat-AABB overlap is a conservative superset of any inflated-OBB
        overlap (the broadphase parity guarantee)."""
        comptime SPEC_BASE: Real = 0.02
        var ax = self._axes(i)
        var h = self.half[i].v
        var wh = Vec3(0, 0, 0)
        comptime for k in range(3):
            wh[k] = (
                abs(ax[0][k]) * h[0]
                + abs(ax[1][k]) * h[1]
                + abs(ax[2][k]) * h[2]
            )
        var r = Real(0)
        if spec_dt > 0:
            var v = self.bodies[i].linear_velocity()
            r = SPEC_BASE * 0.5 + sqrt(dot(v, v)) * spec_dt
        return AABB[3].from_center(
            self.bodies[i].position(), wh + Vec3(r, r, r)
        )

    def _try_mesh_pair(
        mut self, mut pairs: List[_CPair], i: Int, j: Int,
        warm: Bool, margin: Real,
    ):
        """Contact against static level geometry.

        Unlike every other pair, this emits MORE THAN ONE manifold: a crate
        landing in a valley rests on several triangles, and collapsing them
        into one contact would pick a single normal for a surface that has
        two. Each triangle therefore becomes its own `_CPair`, keyed by
        triangle index so warm-starting stays per-triangle across frames.

        A triangle is handed to the ordinary convex-hull narrowphase with its
        winding normal as its one face. That single normal is what makes a
        ramp behave like a ramp: the separating axis is chosen by minimum
        penetration over both shapes' face normals, and without the triangle's
        own the crate would be resolved along one of ITS axes instead."""
        var a = i  # the dynamic body
        var b = j  # the static mesh
        if self.shape[i] >= 4:
            a = j
            b = i
        if self.shape[a] >= 4:
            return  # mesh vs mesh: two static bodies, nothing to resolve

        # The speculative margin is split half-and-half between the two shapes
        # everywhere else, and the full margin is subtracted from the depth
        # afterwards. A triangle has no thickness to inflate, so the dynamic
        # body carries the WHOLE margin here. Inflating it by half instead
        # leaves the body resting margin/2 too deep -- 0.0102 on a 0.02 margin,
        # measured against the same crate on a solid box floor.
        var mr = margin
        var wide = Vec3(margin, margin, margin)

        var box = self._fat_aabb(a, 0)
        var lo = box.min - wide
        var hi = box.max + wide
        var tris = List[Int]()
        self._mesh_candidates(b, AABB[3](lo, hi), tris)
        if len(tris) == 0:
            return

        var poly_a = self._as_hull(a, wide, mr)
        var faces_a = self._hull_faces(a, wide, mr)
        for c in range(len(tris)):
            var t = tris[c]
            var tf = self._mesh_tri_faces(b, t)
            if len(tf) < 3:
                continue  # degenerate triangle: no normal, no contact
            var m = hull_manifold(poly_a, self._mesh_tri(b, t), faces_a, tf)
            if not m.hit:
                continue
            if margin > 0:
                for k in range(m.count):
                    m.depths[k] -= margin
            var pr = _CPair(
                a, b, t, m,
                InlineArray[Real, 4](fill=0),
                InlineArray[Real, 4](fill=0),
                InlineArray[Real, 4](fill=0),
                InlineArray[Vec3, 4](fill=Vec3(0, 0, 0)),
                InlineArray[Vec3, 4](fill=Vec3(0, 0, 0)),
                InlineArray[Real, 4](fill=0),
                InlineArray[Real, 4](fill=0),
            )
            for k in range(m.count):
                pr.ra[k] = self.bodies[a].to_local(m.points[k])
                pr.rb[k] = self.bodies[b].to_local(m.points[k])
                var va0 = Vec3(0, 0, 0)
                if not self.statics[a]:
                    va0 = self.bodies[a].velocity_at(m.points[k])
                pr.vn0[k] = dot(-va0, m.normal)
            if warm:
                for q in range(len(self.cache)):
                    var old = self.cache[q]
                    if (
                        old.a == a
                        and old.b == b
                        and old.feat == t
                        and old.m.count == m.count
                    ):
                        pr.acc = old.acc
                        pr.acc_t1 = old.acc_t1
                        pr.acc_t2 = old.acc_t2
                        break
            pairs.append(pr)

    def _try_pair(
        mut self, mut pairs: List[_CPair], i: Int, j: Int,
        warm: Bool, spec_dt: Real,
    ):
        """The per-pair body of `_collect_pairs`: speculative manifold +
        restitution prep + warm-start match. Extracted so both the brute and
        the broadphase enumeration feed the IDENTICAL logic (parity)."""
        if not self._should_collide(i, j):
            return
        comptime SPEC_BASE: Real = 0.02
        var margin = Real(0)
        if spec_dt > 0:
            var va = self.bodies[i].linear_velocity()
            var vb = self.bodies[j].linear_velocity()
            margin = SPEC_BASE + (
                sqrt(dot(va, va)) + sqrt(dot(vb, vb))
            ) * spec_dt
        var infl = Vec3(margin * 0.5, margin * 0.5, margin * 0.5)

        if self.sensor[i] or self.sensor[j]:
            # No speculative margin: a trigger should fire when the shapes
            # actually overlap, not a margin early, and there is no impulse for
            # the margin to smooth out anyway.
            var sm = self._pair_manifold(i, j, 0, Vec3(0, 0, 0))
            if sm.hit:
                self.sensor_pairs.append(
                    _CPair(
                        i, j, 0, sm,
                        InlineArray[Real, 4](fill=0),
                        InlineArray[Real, 4](fill=0),
                        InlineArray[Real, 4](fill=0),
                        InlineArray[Vec3, 4](fill=Vec3(0, 0, 0)),
                        InlineArray[Vec3, 4](fill=Vec3(0, 0, 0)),
                        InlineArray[Real, 4](fill=0),
                        InlineArray[Real, 4](fill=0),
                    )
                )
            return

        if self.shape[i] >= 4 or self.shape[j] >= 4:
            self._try_mesh_pair(pairs, i, j, warm, margin)
            return

        var m = self._pair_manifold(i, j, margin * 0.5, infl)
        if m.hit and margin > 0:
            for k in range(m.count):
                m.depths[k] -= margin
        if m.hit:
            var pr = _CPair(
                i,
                j,
                0,
                m,
                InlineArray[Real, 4](fill=0),
                InlineArray[Real, 4](fill=0),
                InlineArray[Real, 4](fill=0),
                InlineArray[Vec3, 4](fill=Vec3(0, 0, 0)),
                InlineArray[Vec3, 4](fill=Vec3(0, 0, 0)),
                InlineArray[Real, 4](fill=0),
                InlineArray[Real, 4](fill=0),
            )
            for k in range(m.count):
                pr.ra[k] = self.bodies[i].to_local(m.points[k])
                pr.rb[k] = self.bodies[j].to_local(m.points[k])
                # approach speed at prep: drives the restitution pass
                var va0 = Vec3(0, 0, 0)
                var vb0 = Vec3(0, 0, 0)
                if not self.statics[i]:
                    va0 = self.bodies[i].velocity_at(m.points[k])
                if not self.statics[j]:
                    vb0 = self.bodies[j].velocity_at(m.points[k])
                pr.vn0[k] = dot(vb0 - va0, m.normal)
            if warm:
                for c in range(len(self.cache)):
                    var old = self.cache[c]
                    if (
                        old.a == i
                        and old.b == j
                        and old.feat == 0
                        and old.m.count == m.count
                    ):
                        pr.acc = old.acc
                        pr.acc_t1 = old.acc_t1
                        pr.acc_t2 = old.acc_t2
                        break
            pairs.append(pr)

    def _emit_events(mut self, pairs: List[_CPair]):
        """Diff this step's contact set against last step's: began / stay /
        ended.

        The set is derived, not tracked. The solver already knows exactly which
        contacts exist this step — it just built them — and the warm-start
        cache is last step's answer to the same question, so the events are a
        sorted merge of two key lists and nothing has to be maintained
        incrementally or invalidated when a body is removed.

        Sensor overlaps are included: a trigger volume that never receives an
        impulse still has to say when something entered it, and that is the
        whole reason sensors exist."""
        self.events = List[ContactEvent]()
        var cur = List[Int](capacity=len(pairs) + len(self.sensor_pairs))
        for c in range(len(pairs)):
            cur.append(_ckey(pairs[c].a, pairs[c].b, pairs[c].feat))
        for c in range(len(self.sensor_pairs)):
            ref sp = self.sensor_pairs[c]
            cur.append(_ckey(sp.a, sp.b, sp.feat))
        _sort_keys(cur)

        var i = 0
        var j = 0
        while i < len(cur) or j < len(self._prev_keys):
            if j >= len(self._prev_keys) or (
                i < len(cur) and cur[i] < self._prev_keys[j]
            ):
                self._push_event(cur[i], _EV_BEGAN)
                i += 1
            elif i >= len(cur) or cur[i] > self._prev_keys[j]:
                self._push_event(self._prev_keys[j], _EV_ENDED)
                j += 1
            else:
                self._push_event(cur[i], _EV_STAY)
                i += 1
                j += 1
        self._prev_keys = cur^

    def _push_event(mut self, key: Int, kind: Int):
        self.events.append(
            ContactEvent(
                key >> 42,
                (key >> 21) & 0x1FFFFF,
                key & 0x1FFFFF,
                kind,
            )
        )

    def _collect_pairs(
        mut self, warm: Bool, spec_dt: Real, use_bp: Bool = False
    ) -> List[_CPair]:
        """Manifolds at the current poses (ROTATED box-box manifold — tilted
        geometry produces restoring contacts). With `warm`, impulses are
        inherited from last frame's matching pair by (a, b) key (order-
        independent). `spec_dt > 0` = SPECULATIVE detection (first-stage CCD,
        Jolt/Box2D): boxes inflated by a velocity-scaled margin, subtracted
        back from the depths so near-contacts enter with NEGATIVE depth and
        the `d < 0 -> bias = -d/h` branch stops fast movers AT the surface.

        `use_bp` swaps the O(n²) double loop for a per-frame BVH over fat
        world-AABBs: candidates are a conservative superset of the hitting
        pairs (see `_fat_aabb`), and are fed to `_try_pair` in the SAME
        (i, j) lexicographic order as the brute path, so the pair set and the
        Gauss-Seidel sweep are bit-identical (`test_solver_broadphase`)."""
        var pairs = List[_CPair]()
        self.sensor_pairs = List[_CPair]()  # rebuilt with the solved pairs
        var n = len(self.bodies)
        if use_bp:
            var bvh = BVH[3]()
            var boxes = List[AABB[3]]()
            var proxies = List[Int]()
            for i in range(n):
                boxes.append(self._fat_aabb(i, spec_dt))
                proxies.append(i)
            # SAH build: the solver sorts candidates by (i,j) before use, so
            # the heuristic can't change the pair order — still bit-identical
            # to brute (test_solver_broadphase), and SAH is tighter + faster.
            bvh.build_boxes(boxes, proxies, sah=True)
            for i in range(n):
                var cand = List[Int]()
                bvh.query_region(boxes[i], cand)
                # keep j > i, drop static-static, sort ascending -> the exact
                # order the nested brute loop would visit them
                var js = List[Int]()
                for c in range(len(cand)):
                    var j = cand[c]
                    if j <= i or (self.statics[i] and self.statics[j]):
                        continue
                    js.append(j)
                for a in range(1, len(js)):
                    var key = js[a]
                    var b = a - 1
                    while b >= 0 and js[b] > key:
                        js[b + 1] = js[b]
                        b -= 1
                    js[b + 1] = key
                for a in range(len(js)):
                    self._try_pair(pairs, i, js[a], warm, spec_dt)
        else:
            for i in range(n):
                for j in range(i + 1, n):
                    if self.statics[i] and self.statics[j]:
                        continue
                    self._try_pair(pairs, i, j, warm, spec_dt)
        return pairs^

    def _warm_start(mut self, pairs: List[_CPair], lo: Int, hi: Int):
        """Apply the accumulated impulses at each anchor (Box2D v3 scheme: the
        soft solve's `-impulseScale·acc` term is what balances this out)."""
        for c in range(lo, hi):
            var pr = pairs[c]
            if self._inactive(pr.a) and self._inactive(pr.b):
                continue
            var n = pr.m.normal
            var tb = _tangent_basis(n)
            for k in range(pr.m.count):
                var j = (
                    n * pr.acc[k]
                    + tb[0] * pr.acc_t1[k]
                    + tb[1] * pr.acc_t2[k]
                )
                if not self.statics[pr.a]:
                    self.bodies[pr.a].apply_impulse(
                        -j, self.bodies[pr.a].act(pr.ra[k])
                    )
                if not self.statics[pr.b]:
                    self.bodies[pr.b].apply_impulse(
                        j, self.bodies[pr.b].act(pr.rb[k])
                    )

    def step(mut self, dt: Real, gravity: Vec3, iters: Int = 8):
        # 1. Gravity on dynamic bodies (velocity level).
        for i in range(len(self.bodies)):
            if not self.statics[i]:
                var f = gravity / self.bodies[i].inv_mass()  # force = m·g
                self.bodies[i].integrate_force(dt, f, Vec3(0, 0, 0))
        # 2. Contact manifolds at the pre-solve poses.
        var pairs = self._collect_pairs(False, 0)
        # 3. Gauss-Seidel sweeps of accumulated per-point normal impulses.
        for _ in range(iters):
            for c in range(len(pairs)):
                var pr = pairs[c]
                for k in range(pr.m.count):
                    pr.acc[k] = self._solve_point(
                        pr.a,
                        pr.b,
                        pr.m.normal,
                        pr.m.points[k],
                        pr.m.depths[k],
                        dt,
                        pr.acc[k],
                    )
                pairs[c] = pr
        # 4. Advance poses.
        for i in range(len(self.bodies)):
            if not self.statics[i]:
                self.bodies[i].integrate_pose(dt)

    def _joint_axis(
        mut self,
        ia: Int,
        ib: Int,
        pwa: Vec3,
        pwb: Vec3,
        e: Vec3,
        c: Real,
        h: Real,
        bias_rate: Real,
        ms: Real,
        isc: Real,
        use_bias: Bool,
        acc_e: Real,
    ) -> Real:
        """One scalar equality-constraint solve along unit axis `e` with
        position error `c`; returns the accumulated-impulse delta."""
        var va = Vec3(0, 0, 0)
        var ka = Real(0)
        if not self.statics[ia]:
            va = self.bodies[ia].velocity_at(pwa)
            ka = self.bodies[ia].inv_mass() + self.bodies[ia].angular_factor(
                pwa - self.bodies[ia].position(), e
            )
        var vb = Vec3(0, 0, 0)
        var kb = Real(0)
        if not self.statics[ib]:
            vb = self.bodies[ib].velocity_at(pwb)
            kb = self.bodies[ib].inv_mass() + self.bodies[ib].angular_factor(
                pwb - self.bodies[ib].position(), e
            )
        var denom = ka + kb
        if denom <= 0:
            return 0
        var vr = dot(vb - va, e)
        var bias = bias_rate * c if use_bias else Real(0)
        var dl = -ms * (vr + bias) / denom - isc * acc_e
        var j = e * dl
        if not self.statics[ia]:
            self.bodies[ia].apply_impulse(-j, pwa)
        if not self.statics[ib]:
            self.bodies[ib].apply_impulse(j, pwb)
        return dl

    def _joint_island(self, jt: Joint6) -> Int:
        return self.island[jt.a] if not self.statics[jt.a] else self.island[jt.b]

    def _joint_sweep(
        mut self,
        h: Real,
        bias_rate: Real,
        ms: Real,
        isc: Real,
        use_bias: Bool,
        iters: Int,
        island_filter: Int,
    ):
        for _ in range(iters):
            for c in range(len(self.joints)):
                var jt = self.joints[c]
                if self._inactive(jt.a) and self._inactive(jt.b):
                    continue
                if island_filter != -2 and self._joint_island(jt) != island_filter:
                    continue
                var pwa = self.bodies[jt.a].act(jt.la)
                var pwb = self.bodies[jt.b].act(jt.lb)
                var gap = pwb - pwa
                if jt.kind == JOINT_DISTANCE:
                    var l = sqrt(max(dot(gap, gap), Real(1e-12)))
                    var u = gap / l
                    var acc_s = dot(jt.acc, u)
                    var dl = self._joint_axis(
                        jt.a, jt.b, pwa, pwb, u, l - jt.rest,
                        h, bias_rate, ms, isc, use_bias, acc_s,
                    )
                    jt.acc = u * (acc_s + dl)
                else:
                    # ball part (shared by hinge): drive the anchor gap to 0.
                    for ax in range(3):
                        var e = Vec3(0, 0, 0)
                        e[ax] = 1
                        var dl = self._joint_axis(
                            jt.a, jt.b, pwa, pwb, e, gap[ax],
                            h, bias_rate, ms, isc, use_bias, jt.acc[ax],
                        )
                        jt.acc[ax] += dl
                    if jt.kind == JOINT_HINGE:
                        var oa = self.bodies[jt.a].act(jt.axis_a) - self.bodies[
                            jt.a
                        ].act(Vec3(0, 0, 0))
                        var ob = self.bodies[jt.b].act(jt.axis_b) - self.bodies[
                            jt.b
                        ].act(Vec3(0, 0, 0))
                        var er = _cross(oa, ob)  # small-angle axis error
                        var wa = Vec3(0, 0, 0)
                        var wb2 = Vec3(0, 0, 0)
                        if not self.statics[jt.a]:
                            wa = self.bodies[jt.a].omega_world()
                        if not self.statics[jt.b]:
                            wb2 = self.bodies[jt.b].omega_world()
                        var tb = _tangent_basis(oa)
                        for ti in range(2):
                            var t = tb[0] if ti == 0 else tb[1]
                            var kaa = Real(0)
                            var kbb = Real(0)
                            if not self.statics[jt.a]:
                                kaa = self.bodies[jt.a].angular_only_factor(t)
                            if not self.statics[jt.b]:
                                kbb = self.bodies[jt.b].angular_only_factor(t)
                            var den = kaa + kbb
                            if den <= 0:
                                continue
                            var vr = dot(wb2 - wa, t)
                            var bias = (
                                bias_rate * dot(er, t) if use_bias else Real(0)
                            )
                            var acc_t = dot(jt.acc_ang, t)
                            var dl = -ms * (vr + bias) / den - isc * acc_t
                            jt.acc_ang = jt.acc_ang + t * dl
                            var limp = t * dl
                            if not self.statics[jt.a]:
                                self.bodies[jt.a].apply_angular_impulse(-limp)
                            if not self.statics[jt.b]:
                                self.bodies[jt.b].apply_angular_impulse(limp)
                            wa = Vec3(0, 0, 0)
                            wb2 = Vec3(0, 0, 0)
                            if not self.statics[jt.a]:
                                wa = self.bodies[jt.a].omega_world()
                            if not self.statics[jt.b]:
                                wb2 = self.bodies[jt.b].omega_world()
                self.joints[c] = jt

    def _warm_start_joints(mut self, island_filter: Int):
        for c in range(len(self.joints)):
            var jt = self.joints[c]
            if self._inactive(jt.a) and self._inactive(jt.b):
                continue
            if island_filter != -2 and self._joint_island(jt) != island_filter:
                continue
            var pwa = self.bodies[jt.a].act(jt.la)
            var pwb = self.bodies[jt.b].act(jt.lb)
            if not self.statics[jt.a]:
                self.bodies[jt.a].apply_impulse(-jt.acc, pwa)
                if jt.kind == JOINT_HINGE:
                    self.bodies[jt.a].apply_angular_impulse(-jt.acc_ang)
            if not self.statics[jt.b]:
                self.bodies[jt.b].apply_impulse(jt.acc, pwb)
                if jt.kind == JOINT_HINGE:
                    self.bodies[jt.b].apply_angular_impulse(jt.acc_ang)

    def _soft_sweep(
        mut self,
        mut pairs: List[_CPair],
        lo: Int,
        hi: Int,
        h: Real,
        bias_rate: Real,
        mass_scale: Real,
        impulse_scale: Real,
        use_bias: Bool,
        iters: Int,
        mu: Real,
    ):
        """Gauss-Seidel sweeps with Solver2D soft coefficients. Separation is
        re-derived per point from the CURRENT poses via body-frame anchors, so
        rotation shows up as differential depth (restoring torque)."""
        for _ in range(iters):
            for c in range(lo, hi):
                self._solve_pair(
                    pairs, c, h, bias_rate, mass_scale, impulse_scale,
                    use_bias, mu,
                )

    def _sweep_colored(
        mut self,
        mut pairs: List[_CPair],
        clo: List[Int],
        chi: List[Int],
        h: Real,
        bias_rate: Real,
        mass_scale: Real,
        impulse_scale: Real,
        use_bias: Bool,
        iters: Int,
        mu: Real,
        par: Bool,
        workers: Int = 0,
    ):
        """Graph-colored sweeps: pairs in one color share no DYNAMIC body
        (statics are excluded from adjacency and never written), so a color
        solves in parallel — Jacobi within the color, Gauss-Seidel across
        colors. The schedule is fixed and same-color writes are disjoint, so
        par=True is bit-identical to par=False (and to any `workers` count)."""
        for _ in range(iters):
            for col in range(len(clo)):
                if par and chi[col] - clo[col] >= 8:
                    _solve_color_parallel(
                        self, pairs, clo[col], chi[col], h, bias_rate,
                        mass_scale, impulse_scale, use_bias, mu, workers,
                    )
                else:
                    for c in range(clo[col], chi[col]):
                        self._solve_pair(
                            pairs, c, h, bias_rate, mass_scale,
                            impulse_scale, use_bias, mu,
                        )

    def _solve_pair(
        mut self,
        mut pairs: List[_CPair],
        c: Int,
        h: Real,
        bias_rate: Real,
        mass_scale: Real,
        impulse_scale: Real,
        use_bias: Bool,
        mu: Real,
    ):
        """One pair's normal + friction solve (the body of `_soft_sweep`,
        extracted so the colored sweep can schedule it per pair)."""
        var pr = pairs[c]
        if self._inactive(pr.a) and self._inactive(pr.b):
            return
        var n = pr.m.normal
        for k in range(pr.m.count):
            var pwa = self.bodies[pr.a].act(pr.ra[k])
            var pwb = self.bodies[pr.b].act(pr.rb[k])
            # anchors coincided at prep with depth d0; separation since
            # then is the anchor drift along the normal
            var d = pr.m.depths[k] - dot(pwb - pwa, n)
            var va = Vec3(0, 0, 0)
            var ka = Real(0)
            if not self.statics[pr.a]:
                va = self.bodies[pr.a].velocity_at(pwa)
                ka = self.bodies[pr.a].inv_mass() + self.bodies[
                    pr.a
                ].angular_factor(pwa - self.bodies[pr.a].position(), n)
            var vb = Vec3(0, 0, 0)
            var kb = Real(0)
            if not self.statics[pr.b]:
                vb = self.bodies[pr.b].velocity_at(pwb)
                kb = self.bodies[pr.b].inv_mass() + self.bodies[
                    pr.b
                ].angular_factor(pwb - self.bodies[pr.b].position(), n)
            var denom = ka + kb
            if denom <= 0:
                continue
            var vn = dot(vb - va, n)
            # Box2D sign convention: separation s = -d (negative when
            # penetrating), bias <= 0 pulls vn upward past zero.
            var bias = Real(0)
            var ms = Real(1)
            var isc = Real(0)
            if d < 0:
                bias = -d / h  # speculative: match approach speed
            elif use_bias:
                bias = max(-bias_rate * d, Real(-4))
                ms = mass_scale
                isc = impulse_scale
            var raw = -ms * (vn + bias) / denom - isc * pr.acc[k]
            var new_acc = max(pr.acc[k] + raw, 0)
            var dl = new_acc - pr.acc[k]
            pr.acc[k] = new_acc
            if dl != 0:
                var j = n * dl
                if not self.statics[pr.a]:
                    self.bodies[pr.a].apply_impulse(-j, pwa)
                if not self.statics[pr.b]:
                    self.bodies[pr.b].apply_impulse(j, pwb)
            # Coulomb friction: tangent impulses clamped to mu * lambda_n.
            var tb = _tangent_basis(n)
            var cap = mu * pr.acc[k]
            for ti in range(2):
                var t = tb[0] if ti == 0 else tb[1]
                var vat = Vec3(0, 0, 0)
                var kat = Real(0)
                if not self.statics[pr.a]:
                    vat = self.bodies[pr.a].velocity_at(pwa)
                    kat = self.bodies[pr.a].inv_mass() + self.bodies[
                        pr.a
                    ].angular_factor(
                        pwa - self.bodies[pr.a].position(), t
                    )
                var vbt = Vec3(0, 0, 0)
                var kbt = Real(0)
                if not self.statics[pr.b]:
                    vbt = self.bodies[pr.b].velocity_at(pwb)
                    kbt = self.bodies[pr.b].inv_mass() + self.bodies[
                        pr.b
                    ].angular_factor(
                        pwb - self.bodies[pr.b].position(), t
                    )
                var dent = kat + kbt
                if dent <= 0:
                    continue
                var vt = dot(vbt - vat, t)
                var acc_t = pr.acc_t1[k] if ti == 0 else pr.acc_t2[k]
                var new_t = acc_t - vt / dent
                if new_t > cap:
                    new_t = cap
                elif new_t < -cap:
                    new_t = -cap
                var dtl = new_t - acc_t
                if ti == 0:
                    pr.acc_t1[k] = new_t
                else:
                    pr.acc_t2[k] = new_t
                if dtl != 0:
                    var jt = t * dtl
                    if not self.statics[pr.a]:
                        self.bodies[pr.a].apply_impulse(-jt, pwa)
                    if not self.statics[pr.b]:
                        self.bodies[pr.b].apply_impulse(jt, pwb)
        pairs[c] = pr

    def _ccd_advance(mut self, h: Real):
        """Swept/TOI pose advance (second-stage CCD, Jolt LinearCast
        direction): a body whose relative travel this substep could jump the
        thinnest feature of a pair linear-casts its box along the substep
        displacement (`swept_box_toi`) and advances only to the time of
        impact, minus a hair of back-off — the speculative solver then removes
        the approach velocity with the pair already AT the surface, so the
        midplane can never be crossed. Slow bodies take the plain pose step,
        bit-identical to the non-CCD path (zero-regression guarantee). Clamp
        fractions are decided against the substep-start snapshot before any
        pose moves, so mutually-approaching fast pairs resolve symmetrically
        (the relative displacement already contains both velocities)."""
        var n = len(self.bodies)
        var frac = List[Real]()
        for _ in range(n):
            frac.append(1)
        for i in range(n):
            if self._inactive(i):
                continue
            var vi = self.bodies[i].linear_velocity()
            if dot(vi, vi) * h * h < 1e-12:
                continue
            for j in range(n):
                if j == i:
                    continue
                var vj = Vec3(0, 0, 0)
                if not self._inactive(j):
                    vj = self.bodies[j].linear_velocity()
                var rel = (vi - vj) * h
                var ha = self.half[i].v
                var hb = self.half[j].v
                var thin = min(
                    min(ha[0], min(ha[1], ha[2])),
                    min(hb[0], min(hb[1], hb[2])),
                )
                if dot(rel, rel) <= (thin * 0.5) * (thin * 0.5):
                    continue  # cannot jump the pair's thinnest feature
                var r = swept_box_toi(
                    self.bodies[j].position(),
                    self._axes(j),
                    hb,
                    self.bodies[i].position(),
                    self._axes(i),
                    ha,
                    rel,
                )
                if r.hit and r.t < frac[i]:
                    frac[i] = r.t
        for i in range(n):
            if self._inactive(i):
                continue
            var f = frac[i]
            if f < 1:
                f = max(f - Real(0.01), 0)
            self.bodies[i].integrate_pose(h * f)

    def _restitution_pass(
        mut self, mut pairs: List[_CPair], lo: Int, hi: Int, iters: Int
    ):
        """Box2D v3 restitution: after the substeps have resolved penetration,
        push each point that arrived faster than the threshold back toward
        `vn = -e·vn0` (its own clamped accumulator, so sweeps can correct)."""
        comptime REST_THRESH: Real = 1.0  # m/s approach speed to trigger
        for _ in range(iters):
            for c in range(lo, hi):
                var pr = pairs[c]
                var e = max(
                    self.restitution[pr.a], self.restitution[pr.b]
                )
                if e <= 0:
                    continue
                var n = pr.m.normal
                for k in range(pr.m.count):
                    if pr.vn0[k] >= -REST_THRESH:
                        continue
                    var pwa = self.bodies[pr.a].act(pr.ra[k])
                    var pwb = self.bodies[pr.b].act(pr.rb[k])
                    var va = Vec3(0, 0, 0)
                    var ka = Real(0)
                    if not self.statics[pr.a]:
                        va = self.bodies[pr.a].velocity_at(pwa)
                        ka = self.bodies[pr.a].inv_mass() + self.bodies[
                            pr.a
                        ].angular_factor(pwa - self.bodies[pr.a].position(), n)
                    var vb = Vec3(0, 0, 0)
                    var kb = Real(0)
                    if not self.statics[pr.b]:
                        vb = self.bodies[pr.b].velocity_at(pwb)
                        kb = self.bodies[pr.b].inv_mass() + self.bodies[
                            pr.b
                        ].angular_factor(pwb - self.bodies[pr.b].position(), n)
                    var denom = ka + kb
                    if denom <= 0:
                        continue
                    var vn = dot(vb - va, n)
                    var target = -e * pr.vn0[k]
                    var new_acc = max(pr.racc[k] + (target - vn) / denom, 0)
                    var dl = new_acc - pr.racc[k]
                    pr.racc[k] = new_acc
                    if dl != 0:
                        var j = n * dl
                        if not self.statics[pr.a]:
                            self.bodies[pr.a].apply_impulse(-j, pwa)
                        if not self.statics[pr.b]:
                            self.bodies[pr.b].apply_impulse(j, pwb)
                pairs[c] = pr

    def _soft_fric(
        self, b: Int, x0: Vec3, pv: Vec3, nw: Vec3, nrm: Vec3,
        h: Real, mu: Real,
    ) -> Vec3:
        """Position-level Coulomb friction for a particle contact: clamp the
        tangential slide (relative to the body's contact-point motion) to
        mu times the normal correction — static grip inside the cone,
        sliding on it. Folded into the target point so the coupling impulse
        carries the tangential reaction automatically."""
        var nl = sqrt(max(dot(nrm, nrm), Real(1e-18)))
        var n = nrm * (1 / nl)
        var dn = abs(dot(nw - x0, n))
        var vb = self.bodies[b].velocity_at(nw)
        var slide = (x0 - pv) - vb * h
        var st = slide - n * dot(slide, n)
        var stl = sqrt(max(dot(st, st), Real(1e-18)))
        if stl <= Real(1e-9):
            return nw
        var corr = stl
        if mu * dn < corr:
            corr = mu * dn
        return nw - st * (corr / stl)

    def _softbody_pass(mut self, h: Real, gravity: Vec3, iters: Int, ccd: Bool):
        """One XPBD substep for every soft body: predict, solve the lattice
        distance constraints, collide particles against every box (pushing
        the equivalent impulse back into dynamic bodies), derive velocities.

        With `ccd` a particle that ends the substep OUTSIDE a box is also
        swept: its pre-substep-to-current segment (in the box's current local
        frame — first-order relative motion) is slab-tested against the
        inflated box, and a crossing snaps it back to the entry face. Slow
        paths never trigger the sweep, so ccd=False results are unchanged."""
        for s in range(len(self.softs)):
            var np = len(self.softs[s].pts)
            var alpha_h = self.softs[s].alpha / (h * h)
            var r = self.softs[s].radius
            var damp = self.softs[s].damp
            var smu = self.softs[s].mu
            # predict (store the pre-step position in v temporarily? no —
            # keep explicit: prev list rebuilt per substep)
            var prev = List[Real](capacity=np * 3)
            for i in range(np):
                var p = self.softs[s].pts[i]
                prev.append(p.x[0])
                prev.append(p.x[1])
                prev.append(p.x[2])
                p.v = p.v + gravity * h
                p.x = p.x + p.v * h
                self.softs[s].pts[i] = p
            for e in range(len(self.softs[s].edges)):
                var ed = self.softs[s].edges[e]
                ed.lam = 0
                self.softs[s].edges[e] = ed
            # XPBD Gauss-Seidel over the lattice edges
            for _ in range(iters):
                for e in range(len(self.softs[s].edges)):
                    var ed = self.softs[s].edges[e]
                    var pa = self.softs[s].pts[ed.a]
                    var pb = self.softs[s].pts[ed.b]
                    var d = pa.x - pb.x
                    var l = sqrt(max(dot(d, d), Real(1e-12)))
                    var cc = l - ed.rest
                    var wsum = pa.w + pb.w
                    if wsum <= 0:
                        continue
                    var dl = (-cc - alpha_h * ed.lam) / (wsum + alpha_h)
                    ed.lam += dl
                    var corr = d * (dl / l)
                    pa.x = pa.x + corr * pa.w
                    pb.x = pb.x - corr * pb.w
                    self.softs[s].pts[ed.a] = pa
                    self.softs[s].pts[ed.b] = pb
                    self.softs[s].edges[e] = ed
            # particle vs every box (bodies are boxes in this scene)
            for i in range(np):
                var p = self.softs[s].pts[i]
                for b in range(len(self.bodies)):
                    if self.shape[b] != 0:
                        # sphere / capsule: radial pushout from the closest
                        # interior point (capsule = sphere at the closest
                        # point of its world axis segment); same impulse
                        # coupling as the box path below
                        var hh2 = self.half[b].v
                        var rad = hh2[0]
                        var cen = self.bodies[b].position()
                        if self.shape[b] == 2:
                            var axw = self.bodies[b].act(
                                Vec3(0, hh2[1], 0)
                            ) - cen
                            var tt = dot(p.x - cen, axw) / max(
                                dot(axw, axw), Real(1e-12)
                            )
                            if tt > 1:
                                tt = 1
                            if tt < -1:
                                tt = -1
                            cen = cen + axw * tt
                        var rr = rad + r
                        var dvec = p.x - cen
                        var d2 = dot(dvec, dvec)
                        var nw2 = p.x
                        var hit = False
                        if ccd:
                            # swept segment vs the inflated sphere
                            # (quadratic, earliest root in [0,1]) — and it
                            # OUTRANKS the radial pushout, which would eject
                            # a particle that crossed the midplane within
                            # one substep out the FAR side (same trap as the
                            # box path). Capsule: the sphere sits at the
                            # closest axis point of the CURRENT position —
                            # first-order, same spirit as the box sweep.
                            var pv2 = Vec3(
                                prev[i * 3],
                                prev[i * 3 + 1],
                                prev[i * 3 + 2],
                            )
                            var s0 = pv2 + self.bodies[
                                b
                            ].linear_velocity() * h
                            var seg = p.x - s0
                            var oc = s0 - cen
                            var cc2 = dot(oc, oc) - rr * rr
                            if dot(seg, seg) > r * r and cc2 > 0:
                                var aa = dot(seg, seg)
                                var bb2 = 2 * dot(oc, seg)
                                var disc = bb2 * bb2 - 4 * aa * cc2
                                if disc >= 0:
                                    var tq = (-bb2 - sqrt(disc)) / (2 * aa)
                                    if tq >= 0 and tq <= 1:
                                        var entry = s0 + seg * tq
                                        var ed = entry - cen
                                        var el = sqrt(
                                            max(dot(ed, ed), Real(1e-12))
                                        )
                                        nw2 = cen + ed * (rr / el)
                                        hit = True
                        if not hit and d2 < rr * rr:
                            var dist = sqrt(max(d2, Real(1e-12)))
                            nw2 = cen + dvec * (rr / dist)
                            hit = True
                        if hit and smu > 0:
                            nw2 = self._soft_fric(
                                b,
                                p.x,
                                Vec3(
                                    prev[i * 3],
                                    prev[i * 3 + 1],
                                    prev[i * 3 + 2],
                                ),
                                nw2,
                                (nw2 - cen) * (1 / rr),
                                h,
                                smu,
                            )
                        if hit:
                            var dx2 = nw2 - p.x
                            p.x = nw2
                            if not self.statics[b]:
                                var j2 = dx2 * (-(1 / p.w) / h)
                                self.bodies[b].apply_impulse(j2, nw2)
                                if self.sleeping[b]:
                                    self.sleeping[b] = False
                                    self.sleep_timer[b] = 0
                        continue
                    var lp = self.bodies[b].to_local(p.x)
                    var hh = self.half[b].v
                    var pen = Real(1e30)
                    var ax = -1
                    var inside = True
                    comptime for k in range(3):
                        var pk = (hh[k] + r) - abs(lp[k])
                        if pk <= 0:
                            inside = False
                        elif pk < pen:
                            pen = pk
                            ax = k
                    var sgn = Real(0)
                    var swept = False
                    if ccd:
                        # Swept clamp, and it OUTRANKS the discrete pushout:
                        # a fast particle that crossed the box's midplane
                        # within one substep would be ejected out the FAR
                        # face by min-penetration — the entry face from the
                        # sweep is the truth. RELATIVE motion: shifting the
                        # particle's start by the box's own substep
                        # displacement (+v·h, exact for integrate_pose) lets
                        # one segment in the box's current frame carry both
                        # motions; the box's rotation change is ignored
                        # (first-order sweep). Gated on |dv| > r so slow
                        # scenes keep the discrete path bit-identically.
                        var pv = Vec3(
                            prev[i * 3], prev[i * 3 + 1], prev[i * 3 + 2]
                        )
                        var lp0 = self.bodies[b].to_local(
                            pv + self.bodies[b].linear_velocity() * h
                        )
                        var dv = lp - lp0
                        if dot(dv, dv) > r * r:
                            # t_in >= 0 (not > 0): a particle clamped ONTO
                            # the face last substep re-enters with t_in == 0
                            var t_in = Real(-1e30)
                            var t_out = Real(1)
                            var ax_in = -1
                            var miss = False
                            for k in range(3):
                                var he = hh[k] + r
                                if abs(dv[k]) < Real(1e-12):
                                    if abs(lp0[k]) > he:
                                        miss = True
                                else:
                                    var t1 = (-he - lp0[k]) / dv[k]
                                    var t2 = (he - lp0[k]) / dv[k]
                                    if t1 > t2:
                                        var tmp = t1
                                        t1 = t2
                                        t2 = tmp
                                    if t1 > t_in:
                                        t_in = t1
                                        ax_in = k
                                    if t2 < t_out:
                                        t_out = t2
                            if (
                                not miss
                                and ax_in >= 0
                                and t_in >= 0
                                and t_in <= t_out
                                and t_in <= 1
                            ):
                                ax = ax_in
                                # entry side comes from the START point:
                                # after crossing the midplane lp[ax] is
                                # already on the far side
                                sgn = Real(1) if lp0[ax] >= 0 else Real(-1)
                                swept = True
                    if not swept:
                        if inside and ax >= 0:
                            sgn = Real(1) if lp[ax] >= 0 else Real(-1)
                        else:
                            continue
                    lp[ax] = sgn * (hh[ax] + r)
                    var nw = self.bodies[b].act(lp)
                    if smu > 0:
                        # world face normal from a unit local offset
                        var lpo = lp
                        lpo[ax] = sgn * (hh[ax] + r + 1)
                        nw = self._soft_fric(
                            b,
                            p.x,
                            Vec3(
                                prev[i * 3], prev[i * 3 + 1], prev[i * 3 + 2]
                            ),
                            nw,
                            self.bodies[b].act(lpo) - nw,
                            h,
                            smu,
                        )
                    var dx = nw - p.x
                    p.x = nw
                    if not self.statics[b]:
                        # equal-and-opposite impulse into the dynamic body
                        var j = dx * (-(1 / p.w) / h)
                        self.bodies[b].apply_impulse(j, nw)
                        if self.sleeping[b]:
                            self.sleeping[b] = False
                            self.sleep_timer[b] = 0
                self.softs[s].pts[i] = p
            # velocities from positions
            for i in range(np):
                var p = self.softs[s].pts[i]
                var pv = Vec3(prev[i * 3], prev[i * 3 + 1], prev[i * 3 + 2])
                p.v = (p.x - pv) * (damp / h)
                self.softs[s].pts[i] = p

    def _pair_island(self, pr: _CPair) -> Int:
        return self.island[pr.a] if not self.statics[pr.a] else self.island[pr.b]

    def _solve_island(
        mut self,
        mut pairs: List[_CPair],
        plo: Int,
        phi: Int,
        label: Int,
        gravity: Vec3,
        h: Real,
        substeps: Int,
        iters: Int,
        bias_rate: Real,
        mass_scale: Real,
        impulse_scale: Real,
        mu: Real,
    ):
        """The full substep loop restricted to one island: its bodies, its
        contiguous pair range, its joints. Islands share nothing, so running
        these in parallel is bit-identical to running them in sequence."""
        for _ in range(substeps):
            for i in range(len(self.bodies)):
                if self.island[i] == label and not self._inactive(i):
                    var f = gravity / self.bodies[i].inv_mass()
                    self.bodies[i].integrate_force(h, f, Vec3(0, 0, 0))
            self._warm_start(pairs, plo, phi)
            self._warm_start_joints(label)
            self._joint_sweep(
                h, bias_rate, mass_scale, impulse_scale, True, iters, label
            )
            self._soft_sweep(
                pairs, plo, phi, h, bias_rate, mass_scale,
                impulse_scale, True, iters, mu,
            )
            for i in range(len(self.bodies)):
                if self.island[i] == label and not self._inactive(i):
                    self.bodies[i].integrate_pose(h)
            self._joint_sweep(h, bias_rate, 1, 0, False, 2, label)
            self._soft_sweep(pairs, plo, phi, h, bias_rate, 1, 0, False, 2, mu)
        self._restitution_pass(pairs, plo, phi, 4)

    def step_soft(
        mut self,
        dt: Real,
        gravity: Vec3,
        substeps: Int = 4,
        iters: Int = 4,
        hertz: Real = 30,
        zeta: Real = 10,
        mu: Real = 0.5,
        ccd: Bool = False,
        parallel: Bool = False,
        colored: Bool = False,
        broadphase: Bool = False,
        workers: Int = 0,
    ):
        """Sub-stepped soft-constraint step (Box2D v3 "Soft Step" scheme):
        collide once, then per substep integrate velocities, solve with soft
        bias, integrate poses, and RELAX (bias-free sweep) so the bias energy
        never becomes bounce.

        `parallel=True` solves ISLANDS on worker threads (scenes without soft
        bodies and without ccd): islands are disjoint by construction, so the
        result is bit-identical to the serial path (`test_islands_par`).

        `workers` pins the fan-out width (0 = let the runtime use every core).
        Because the partition — islands, or a color's pairs — is what makes the
        writes disjoint, the worker count changes only the SCHEDULE, never the
        result: any `workers` is bit-identical to serial. That invariance is
        what makes a core-scaling sweep (`bench_islands`, `bench_colored`) a
        fair measurement rather than a different computation per point."""
        var h = dt / Real(substeps)
        var omega = Real(6.283185307179586) * hertz
        var c = h * omega * (2 * zeta + h * omega)
        var bias_rate = omega / (2 * zeta + h * omega)
        var mass_scale = c / (1 + c)
        var impulse_scale = 1 / (1 + c)
        var pairs = self._collect_pairs(True, dt, broadphase)
        self._refresh_islands(pairs)
        # graph coloring (colored=True): greedy smallest-free-color over the
        # DYNAMIC-body adjacency (a shared static must not chain colors, or
        # one ground plane serialises the whole scene); pairs reordered into
        # contiguous per-color ranges. <= 64 colors (bit masks).
        var n_colors = 0
        var clo = List[Int]()
        var chi = List[Int]()
        if colored:
            var mask = List[Int]()
            for _ in range(len(self.bodies)):
                mask.append(0)
            var pcol = List[Int]()
            for pc in range(len(pairs)):
                var used = 0
                if not self.statics[pairs[pc].a]:
                    used |= mask[pairs[pc].a]
                if not self.statics[pairs[pc].b]:
                    used |= mask[pairs[pc].b]
                var col = 0
                while (used >> col) & 1 == 1:
                    col += 1
                pcol.append(col)
                if col + 1 > n_colors:
                    n_colors = col + 1
                if not self.statics[pairs[pc].a]:
                    mask[pairs[pc].a] |= 1 << col
                if not self.statics[pairs[pc].b]:
                    mask[pairs[pc].b] |= 1 << col
            var pairs3 = List[_CPair]()
            for col in range(n_colors):
                clo.append(len(pairs3))
                for pc in range(len(pairs)):
                    if pcol[pc] == col:
                        pairs3.append(pairs[pc])
                chi.append(len(pairs3))
            pairs = pairs3^
        if parallel and not colored and len(self.softs) == 0 and not ccd:
            # partition: pairs reordered so each island is a contiguous range
            var labels = List[Int]()
            for i in range(len(self.bodies)):
                if self.island[i] < 0:
                    continue
                var known = False
                for k in range(len(labels)):
                    if labels[k] == self.island[i]:
                        known = True
                        break
                if not known:
                    labels.append(self.island[i])
            var pairs2 = List[_CPair]()
            var plo = List[Int]()
            var phi = List[Int]()
            for k in range(len(labels)):
                plo.append(len(pairs2))
                for pc in range(len(pairs)):
                    if self._pair_island(pairs[pc]) == labels[k]:
                        pairs2.append(pairs[pc])
                phi.append(len(pairs2))

            _solve_islands_parallel(
                self, pairs2, plo, phi, labels, gravity, h,
                substeps, iters, bias_rate, mass_scale, impulse_scale, mu,
                workers,
            )
            self._update_sleep(dt)
            if self.events_on:
                self._emit_events(pairs2)
            self.cache = pairs2^
            return
        for _ in range(substeps):
            for i in range(len(self.bodies)):
                if not self._inactive(i):
                    var f = gravity / self.bodies[i].inv_mass()
                    self.bodies[i].integrate_force(h, f, Vec3(0, 0, 0))
            # Warm start: re-apply accumulated impulses; the soft solve's
            # -impulseScale·acc decay is the matching counter-term.
            self._warm_start(pairs, 0, len(pairs))
            self._warm_start_joints(-2)
            self._joint_sweep(
                h, bias_rate, mass_scale, impulse_scale, True, iters, -2
            )
            if colored:
                self._sweep_colored(
                    pairs, clo, chi, h, bias_rate, mass_scale,
                    impulse_scale, True, iters, mu, parallel, workers,
                )
            else:
                self._soft_sweep(
                    pairs, 0, len(pairs), h, bias_rate, mass_scale,
                    impulse_scale, True, iters, mu,
                )
            if ccd:
                self._ccd_advance(h)
            else:
                for i in range(len(self.bodies)):
                    if not self._inactive(i):
                        self.bodies[i].integrate_pose(h)
            # soft bodies: XPBD lattice + particle-vs-body coupling, at the
            # substep's POST-integration poses (rigid impulses land next substep)
            self._softbody_pass(h, gravity, iters, ccd)
            # relax: remove the bias energy (velocity-only, no bias)
            self._joint_sweep(h, bias_rate, 1, 0, False, 2, -2)
            if colored:
                self._sweep_colored(
                    pairs, clo, chi, h, bias_rate, 1, 0, False, 2, mu,
                    parallel, workers,
                )
            else:
                self._soft_sweep(
                    pairs, 0, len(pairs), h, bias_rate, 1, 0, False, 2, mu
                )
        self._restitution_pass(pairs, 0, len(pairs), 4)
        self._update_sleep(dt)
        if self.events_on:
            self._emit_events(pairs)
        self.cache = pairs^  # impulses persist to the next frame


def _solve_islands_parallel[BB: Body6](
    mut scene: ContactScene6[BB],
    mut pairs2: List[_CPair],
    plo: List[Int],
    phi: List[Int],
    labels: List[Int],
    gravity: Vec3,
    h: Real,
    substeps: Int,
    iters: Int,
    bias_rate: Real,
    mass_scale: Real,
    impulse_scale: Real,
    mu: Real,
    workers: Int = 0,
):
    """Worker fan-out for `step_soft(parallel=True)`. A free function so the
    closure captures `scene` as an ordinary argument (the scheduler's
    entity-actor precedent) — islands write disjoint bodies/pairs, so the
    parallel dispatch is race-free and bit-identical to serial."""

    @parameter
    def island_work(k: Int):
        scene._solve_island(
            pairs2, plo[k], phi[k], labels[k], gravity, h,
            substeps, iters, bias_rate, mass_scale, impulse_scale, mu,
        )

    # `workers <= 0` means "let the runtime pick" (all cores); a positive
    # value pins the fan-out width so the core-scaling curve can be measured.
    # Islands are disjoint, so the RESULT is worker-count-invariant either way
    # (`test_islands_par` gates this).
    if workers > 0:
        parallelize[island_work](len(labels), workers)
    else:
        parallelize[island_work](len(labels))


def _solve_color_parallel[BB: Body6](
    mut scene: ContactScene6[BB],
    mut pairs2: List[_CPair],
    lo: Int,
    hi: Int,
    h: Real,
    bias_rate: Real,
    mass_scale: Real,
    impulse_scale: Real,
    use_bias: Bool,
    mu: Real,
    workers: Int = 0,
):
    """Solve one color's pairs on worker threads (same free-function +
    @parameter implicit-capture pattern as `_solve_islands_parallel`; an
    explicit capture list does not parse on this nightly). Same-color pairs
    share no dynamic body, so the writes are disjoint and the result is
    bit-identical to solving the color serially."""

    @parameter
    def pair_work(k: Int):
        scene._solve_pair(
            pairs2, lo + k, h, bias_rate, mass_scale, impulse_scale,
            use_bias, mu,
        )

    if workers > 0:
        parallelize[pair_work](hi - lo, workers)
    else:
        parallelize[pair_work](hi - lo)
