"""6-DOF contact solving: `ContactManifold` points -> sequential impulses.

This is the first angular contact response in the engine — the piece
`physics/rigidbody.mojo` explicitly deferred until the narrowphase produced
contact points. `ContactScene6[B, BP]` is generic over the `Body6`
representation (quat+tensor or motor+screw) AND over the `BroadPhase`
backend that enumerates candidate pairs (`collision.broadphase`; defaults to
the rebuild-per-step BVH), so the same scene is both a parity gate between
the classical and the GA path, and a parity gate across every broadphase
backend (`tests/test_solver_bp_seam.mojo`).

The collider registry (shape kinds, hull/mesh/heightfield tables, filters,
sensors) and the shape-pair narrowphase dispatch live in
`collision.collider_set.ColliderSet` (audit finding F1) — this scene *holds*
one (`self.colliders`) instead of owning that data itself, so 17.13 scene
queries and the 17.1 character controller can use the real collider geometry
without importing physics. Candidate-pair enumeration through the
`BroadPhase` seam and the geometry half of the per-pair narrowphase test live
in `collision.contact_gen` (finding F2); this module keeps warm-start
matching and the body-frame anchor / approach-speed prep that need a
`Body6` (`collision.contact_gen`'s docstring explains the split).

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
from std.os import abort
from max.algorithm import parallelize
from geometry.vec import Real, Vec3, dot, cross, tangent_basis
from geometry.aabb import AABB
from geometry.quat import Quat
from collision.manifold import ContactManifold, Axes3
from collision.collider_set import (
    ColliderSet,
    Pose3,
    SHAPE_BOX,
    SHAPE_HULL,
    SHAPE_TRIMESH,
    SHAPE_HEIGHTFIELD,
)
from collision.contact_gen import RawContact, collect_bp_pairs, try_pair
from collision.contact_events import ContactEvent, pack_key, diff_events
from collision.broadphase import BroadPhase, Pair
from collision.bp_bvh import BVHBroadPhase
from collision.toi import swept_box_toi
from collision.hull import HullShape
from collision.trimesh import TriMesh, HeightField
from diag.counters import Counters, PARALLEL_FALLBACK_SERIAL
from .rigid6 import Body6, QuatBody6, Inertia3
from .body_set import BodySet, BodyId, MOTION_STATIC, MOTION_DYNAMIC
from .solver_config import SolverConfig
from .state_io import StateWriter, StateReader
from .softbody import SoftBody, SP, SEdge

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
    var acc: Array[Real, 4]  # per-point accumulated normal impulse
    var acc_t1: Array[Real, 4]  # accumulated friction impulses
    var acc_t2: Array[Real, 4]
    # Body-frame contact anchors (Box2D scheme): both coincide with the
    # manifold point at prep; per-substep world separation is re-derived from
    # the CURRENT poses, so tilting a body deepens its near edge and the bias
    # produces a restoring torque (frozen depths cannot — towers slowly tip).
    var ra: Array[Vec3, 4]
    var rb: Array[Vec3, 4]
    # Restitution (Box2D v3 scheme): the approach speed captured at prep time
    # drives a dedicated post-substep pass toward v_target = -e·vn0. Neither
    # field is warm-start-inherited — both are per-frame.
    var vn0: Array[Real, 4]
    var racc: Array[Real, 4]

    def __init__(out self, *, copy: Self):
        """Explicit copy: `Array` is not `ImplicitlyCopyable` in
        Mojo 1.0, so a struct holding one gets no synthesised copy."""
        self.a = copy.a
        self.b = copy.b
        self.feat = copy.feat
        self.m = copy.m.copy()
        self.acc = copy.acc.copy()
        self.acc_t1 = copy.acc_t1.copy()
        self.acc_t2 = copy.acc_t2.copy()
        self.ra = copy.ra.copy()
        self.rb = copy.rb.copy()
        self.vn0 = copy.vn0.copy()
        self.racc = copy.racc.copy()


# The `_Pt` / `_LV` / `_Half` wrappers that used to sit here existed for one
# stated reason: a bare `List[SIMD[_, 3]]` corrupted on realloc. Width 3 was
# never a supported SIMD width; `Vec3` is four lanes now and the claim was
# retested before removal -- a list grown from capacity 0 to 10,000 elements
# reads back with zero wrong entries.


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
            Vec3(0, 0, 1, 0), Vec3(0, 0, 1, 0), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0),
        )

    @staticmethod
    def distance(a: Int, b: Int, la: Vec3, lb: Vec3, rest: Real) -> Self:
        return Self(
            JOINT_DISTANCE, a, b, la, lb, rest,
            Vec3(0, 0, 1, 0), Vec3(0, 0, 1, 0), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0),
        )

    @staticmethod
    def hinge(a: Int, b: Int, la: Vec3, lb: Vec3, axis: Vec3) -> Self:
        return Self(
            JOINT_HINGE, a, b, la, lb, 0,
            axis, axis, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0),
        )


struct ContactScene6[B: Body6, BP: BroadPhase = BVHBroadPhase[3]](Movable, Deinitable):
    """Boxes (dynamic or static) under gravity with contact impulses."""

    var bset: BodySet[Self.B]  # body identity + per-body SoA (F5): bodies,
    # motion (static/dynamic), sleeping, sleep_timer, island, restitution --
    # see `physics/body_set.mojo`.
    var cache: List[_CPair]  # last frame's pairs (cross-frame warm starting)
    var joints: List[Joint6]
    var softs: List[SoftBody]
    var colliders: ColliderSet  # shape kinds, hull/mesh tables, filters (F1)
    var counters: Counters  # diag counters (F23: parallel fallback to serial)
    var bp: Self.BP  # persistent broadphase, used when `step_soft(broadphase=True)`
    # A sensor reports overlap and never receives an impulse. Its pairs are
    # collected separately rather than flagged in `pairs`, so that not one of
    # the solve, warm-start, island or restitution loops needs to learn about
    # them.
    var sensor_pairs: List[_CPair]
    # Contact events, rebuilt every step when `events` is on. Off by default:
    # the diff sorts the contact set, which is real work for a scene that never
    # reads the result.
    var events_on: Bool
    var events: List[ContactEvent]
    var _prev_keys: List[Int]

    def __init__(out self):
        comptime assert Self.BP.dim == 3, (
            "ContactScene6 is a 3-D solver: its BroadPhase must have dim == 3"
        )
        self.bset = BodySet[Self.B]()
        self.cache = List[_CPair]()
        self.joints = List[Joint6]()
        self.softs = List[SoftBody]()
        self.colliders = ColliderSet()
        self.counters = Counters()
        self.bp = Self.BP()
        self.sensor_pairs = List[_CPair]()
        self.events_on = False
        self.events = List[ContactEvent]()
        self._prev_keys = List[Int]()

    def add_soft(mut self, var sb: SoftBody) -> Int:
        self.softs.append(sb^)
        return len(self.softs) - 1

    def add_joint(mut self, j: Joint6) -> Int:
        self.joints.append(j)
        return len(self.joints) - 1

    def island_count(self) -> Int:
        """Number of distinct dynamic islands from the last `step_soft`."""
        var seen = List[Int]()
        for i in range(len(self.bset.island)):
            if self.bset.island[i] < 0:
                continue
            var known = False
            for j in range(len(seen)):
                if seen[j] == self.bset.island[i]:
                    known = True
                    break
            if not known:
                seen.append(self.bset.island[i])
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
        var n = len(self.bset.bodies)
        var parent = List[Int]()
        for i in range(n):
            parent.append(i)
        for c in range(len(pairs)):
            var a = pairs[c].a
            var b = pairs[c].b
            if not self.bset.is_static(a) and not self.bset.is_static(b):
                parent[self._find(parent, a)] = self._find(parent, b)
        for c in range(len(self.joints)):
            var a = self.joints[c].a
            var b = self.joints[c].b
            if not self.bset.is_static(a) and not self.bset.is_static(b):
                parent[self._find(parent, a)] = self._find(parent, b)
        # labels + island-wide wake
        while len(self.bset.island) < n:
            self.bset.island.append(-1)
        for i in range(n):
            self.bset.island[i] = -1 if self.bset.is_static(i) else self._find(parent, i)
        for i in range(n):
            if self.bset.is_static(i) or self.bset.sleeping[i]:
                continue
            # island member i is awake -> wake everyone sharing its label
            for j in range(n):
                if self.bset.island[j] == self.bset.island[i] and self.bset.sleeping[j]:
                    self.bset.sleeping[j] = False
                    self.bset.sleep_timer[j] = 0

    def _update_sleep(mut self, dt: Real, cfg: SolverConfig):
        """Advance per-body still-timers; a whole island sleeps together."""
        var n = len(self.bset.bodies)
        for i in range(n):
            if self.bset.is_static(i) or self.bset.sleeping[i]:
                continue
            var v = self.bset.bodies[i].linear_velocity()
            var w = self.bset.bodies[i].omega_world()
            if (
                dot(v, v) < cfg.lin_sleep_tol * cfg.lin_sleep_tol
                and dot(w, w) < cfg.ang_sleep_tol * cfg.ang_sleep_tol
            ):
                self.bset.sleep_timer[i] += dt
            else:
                self.bset.sleep_timer[i] = 0
        # sleep islands whose every member has been still long enough
        for i in range(n):
            if self.bset.is_static(i) or self.bset.sleeping[i]:
                continue
            var all_still = True
            for j in range(n):
                if self.bset.island[j] == self.bset.island[i] and self.bset.sleep_timer[
                    j
                ] < cfg.sleep_time:
                    all_still = False
                    break
            if all_still:
                for j in range(n):
                    if self.bset.island[j] == self.bset.island[i]:
                        self.bset.sleeping[j] = True
                        self.bset.bodies[j].halt()

    def _push_body(mut self, var b: Self.B, is_static: Bool) -> BodyId:
        """The body-list half of registration, shared by every `add*`
        variant -- always called exactly once per body, through
        `BodySet.push` (the one append site, F5), in lockstep with exactly
        one `self.colliders.add*` call, so the two index spaces stay
        aligned (collider `i` <-> body `i`; `add` below asserts it)."""
        return self.bset.push(b^, MOTION_STATIC if is_static else MOTION_DYNAMIC)

    def add(mut self, var b: Self.B, half: Vec3, is_static: Bool) -> BodyId:
        var id = self._push_body(b^, is_static)
        var ci = self.colliders.add(half)
        debug_assert(
            ci == id.index(), "ContactScene6.add: body/collider index desync"
        )
        return id

    def add_sphere(mut self, var b: Self.B, r: Real, is_static: Bool) -> BodyId:
        var id = self._push_body(b^, is_static)
        var ci = self.colliders.add_sphere(r)
        debug_assert(
            ci == id.index(),
            "ContactScene6.add_sphere: body/collider index desync",
        )
        return id

    def add_capsule(
        mut self, var b: Self.B, r: Real, half_len: Real, is_static: Bool
    ) -> BodyId:
        var id = self._push_body(b^, is_static)
        var ci = self.colliders.add_capsule(r, half_len)
        debug_assert(
            ci == id.index(),
            "ContactScene6.add_capsule: body/collider index desync",
        )
        return id

    def add_hull(
        mut self, var b: Self.B, var verts: List[Real], is_static: Bool
    ) -> BodyId:
        """A convex body given by its LOCAL-frame vertices, FLAT (x, y, z per
        vertex) -- see `collision.collider_set.ColliderSet.add_hull`."""
        var id = self._push_body(b^, is_static)
        var ci = self.colliders.add_hull(verts^)
        debug_assert(
            ci == id.index(), "ContactScene6.add_hull: body/collider index desync"
        )
        return id

    def add_trimesh(
        mut self, var b: Self.B, verts: List[Real], indices: List[Int]
    ) -> BodyId:
        """Static triangle soup. `verts` is flat (x, y, z per vertex) in WORLD
        space, `indices` three per triangle.

        Always static. A mesh has no useful inertia tensor and no closed
        volume, so a dynamic one would be resolved against by contacts that
        cannot conserve anything; refusing it here is cheaper than discovering
        it as drift."""
        var id = self._push_body(b^, True)
        var ci = self.colliders.add_trimesh(verts, indices)
        debug_assert(
            ci == id.index(),
            "ContactScene6.add_trimesh: body/collider index desync",
        )
        return id

    def add_heightfield(
        mut self, var b: Self.B, heights: List[Real], nx: Int, nz: Int,
        cell: Real, ox: Real = 0, oz: Real = 0,
    ) -> BodyId:
        """Static heightfield: the same surface as a mesh, with the triangles
        left implicit and the midphase reduced to arithmetic. Static for the
        same reason as `add_trimesh`."""
        var id = self._push_body(b^, True)
        var ci = self.colliders.add_heightfield(heights, nx, nz, cell, ox, oz)
        debug_assert(
            ci == id.index(),
            "ContactScene6.add_heightfield: body/collider index desync",
        )
        return id

    def set_filter(mut self, i: Int, category: UInt32, mask: UInt32):
        """Which layer body `i` is on, and which layers it collides with."""
        self.colliders.set_filter(i, category, mask)

    def set_sensor(mut self, i: Int, on: Bool):
        """A sensor overlaps but never pushes: it reports contact events and is
        skipped by every solve pass. Trigger volumes are the point."""
        self.colliders.set_sensor(i, on)

    def set_restitution(mut self, i: Int, e: Real):
        self.bset.restitution[i] = e

    def _inactive(self, i: Int) -> Bool:
        return self.bset.is_static(i) or self.bset.sleeping[i]

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
        var va = Vec3(0, 0, 0, 0)
        var ka = Real(0)
        if not self.bset.is_static(ia):
            va = self.bset.bodies[ia].velocity_at(p)
            ka = self.bset.bodies[ia].inv_mass() + self.bset.bodies[ia].angular_factor(
                p - self.bset.bodies[ia].position(), n
            )
        var vb = Vec3(0, 0, 0, 0)
        var kb = Real(0)
        if not self.bset.is_static(ib):
            vb = self.bset.bodies[ib].velocity_at(p)
            kb = self.bset.bodies[ib].inv_mass() + self.bset.bodies[ib].angular_factor(
                p - self.bset.bodies[ib].position(), n
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
        if not self.bset.is_static(ia):
            self.bset.bodies[ia].apply_impulse(-j, p)
        if not self.bset.is_static(ib):
            self.bset.bodies[ib].apply_impulse(j, p)
        return new_acc

    def _axes(self, i: Int) -> Axes3:
        """World-frame box axes of body `i` (via `act`, representation-free)."""
        var o = self.bset.bodies[i].act(Vec3(0, 0, 0, 0))
        var out = Array[Vec3, 3](fill=Vec3(0, 0, 0, 0))
        out[0] = self.bset.bodies[i].act(Vec3(1, 0, 0, 0)) - o
        out[1] = self.bset.bodies[i].act(Vec3(0, 1, 0, 0)) - o
        out[2] = self.bset.bodies[i].act(Vec3(0, 0, 1, 0)) - o
        return out^

    def _pose(self, i: Int) -> Pose3:
        """The seam value: everything `ColliderSet` needs from body `i`'s
        transform, and nothing else -- collision never sees a `Body6`."""
        return Pose3(self.bset.bodies[i].position(), self._axes(i))

    def _make_sensor_cpair(self, rc: RawContact) -> _CPair:
        """Wrap a sensor overlap: all-zero accumulators/anchors, matching the
        original inline construction exactly -- a sensor never receives an
        impulse, so it never needs an anchor or an approach-speed prep."""
        return _CPair(
            rc.a, rc.b, rc.feat, rc.m,
            Array[Real, 4](fill=0),
            Array[Real, 4](fill=0),
            Array[Real, 4](fill=0),
            Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
            Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
            Array[Real, 4](fill=0),
            Array[Real, 4](fill=0),
        )

    def _make_cpair(self, rc: RawContact, warm: Bool) -> _CPair:
        """Wrap raw contact geometry (`collision.contact_gen.RawContact`)
        into a solved `_CPair`: body-frame anchors and approach-speed prep
        (need `Body6.to_local`/`velocity_at`), then a warm-start match
        against last frame's cache (need `self.cache`) -- the two things
        `contact_gen` cannot do without seeing physics.

        For a mesh contact `rc.b` is always static, so `vb0` below is always
        the zero it starts as -- the same value the old mesh-specific path
        got from `dot(-va0, normal)`, just via the shared formula."""
        var pr = _CPair(
            rc.a, rc.b, rc.feat, rc.m,
            Array[Real, 4](fill=0),
            Array[Real, 4](fill=0),
            Array[Real, 4](fill=0),
            Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
            Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
            Array[Real, 4](fill=0),
            Array[Real, 4](fill=0),
        )
        for k in range(rc.m.count):
            pr.ra[k] = self.bset.bodies[rc.a].to_local(rc.m.points[k])
            pr.rb[k] = self.bset.bodies[rc.b].to_local(rc.m.points[k])
            var va0 = Vec3(0, 0, 0, 0)
            var vb0 = Vec3(0, 0, 0, 0)
            if not self.bset.is_static(rc.a):
                va0 = self.bset.bodies[rc.a].velocity_at(rc.m.points[k])
            if not self.bset.is_static(rc.b):
                vb0 = self.bset.bodies[rc.b].velocity_at(rc.m.points[k])
            pr.vn0[k] = dot(vb0 - va0, rc.m.normal)
        if warm:
            for c in range(len(self.cache)):
                var old = self.cache[c]
                if (
                    old.a == rc.a
                    and old.b == rc.b
                    and old.feat == rc.feat
                    and old.m.count == rc.m.count
                ):
                    pr.acc = old.acc.copy()
                    pr.acc_t1 = old.acc_t1.copy()
                    pr.acc_t2 = old.acc_t2.copy()
                    break
        return pr^

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

        `use_bp` swaps the O(n²) double loop for `self.bp` (any `BroadPhase`
        backend) over fat world-AABBs: `collision.contact_gen.collect_bp_pairs`
        reduces its candidates to the SAME (i, j) lexicographic order the
        brute path visits, so the pair set and the Gauss-Seidel sweep are
        bit-identical regardless of which backend `Self.BP` is
        (`tests/test_solver_bp_seam.mojo`). Candidate geometry (which pair
        touched, on what manifold) comes from `collision.contact_gen.try_pair`
        over `self.colliders`; this method's own job is wrapping that
        geometry with the warm-start match and body-frame anchors that need
        `Body6` (`_make_cpair`)."""
        var raws = List[RawContact]()
        var sraws = List[RawContact]()
        var n = len(self.bset.bodies)
        if use_bp:
            # `Self.BP.dim` is a dependent expression that never unifies
            # with the literal `3` `ColliderSet.fat_aabb` returns, even
            # though the `__init__` comptime assert guarantees they are
            # equal (mojo_1.1_migration.md Gotcha #2) -- `rebind` bridges
            # the two syntactically-distinct, semantically-equal types.
            var boxes = List[AABB[Self.BP.dim]]()
            for i in range(n):
                boxes.append(
                    rebind[AABB[Self.BP.dim]](
                        self.colliders.fat_aabb(
                            i, self._pose(i), self.bset.bodies[i].linear_velocity(), spec_dt
                        )
                    )
                )
            var bp_pairs = List[Pair]()
            # `collect_bp_pairs` still wants a plain `List[Bool]` of which
            # bodies are static (it lives in `collision`, which cannot
            # import `physics.body_set`'s `MOTION_*` constants -- physics is
            # a higher layer); build it from `self.bset.motion` once here
            # rather than widen that seam's parameter type for one caller.
            var is_static_bool = List[Bool](capacity=n)
            for i in range(n):
                is_static_bool.append(self.bset.is_static(i))
            # `collect_bp_pairs` is `raises` only because `SpatialHashBroadPhase`
            # (one of the dim-3 backends `Self.BP` can be) wraps
            # `SpatialHashGrid`, whose own methods raise. That is a broken-
            # invariant class of failure for a scene the engine already
            # validated at `add*`/`set_filter` time, not caller input this
            # method should propagate (docs/ARCHITECTURE.md S2, "programmer
            # error... terminate") -- so it is caught and aborted here rather
            # than making `step`/`step_soft` (and every one of their ~100
            # call sites across tests/benchmarks) `raises` for a path that
            # should never actually raise.
            try:
                collect_bp_pairs[Self.BP](self.bp, boxes, is_static_bool, bp_pairs)
            except e:
                abort("BroadPhase raised inside ContactScene6: " + String(e))
            for c in range(len(bp_pairs)):
                var i = bp_pairs[c].a
                var j = bp_pairs[c].b
                try_pair(
                    self.colliders, i, j, self._pose(i), self._pose(j),
                    self.bset.bodies[i].linear_velocity(),
                    self.bset.bodies[j].linear_velocity(),
                    spec_dt, raws, sraws,
                )
        else:
            for i in range(n):
                for j in range(i + 1, n):
                    if self.bset.is_static(i) and self.bset.is_static(j):
                        continue
                    try_pair(
                        self.colliders, i, j, self._pose(i), self._pose(j),
                        self.bset.bodies[i].linear_velocity(),
                        self.bset.bodies[j].linear_velocity(),
                        spec_dt, raws, sraws,
                    )
        self.sensor_pairs = List[_CPair]()  # rebuilt with the solved pairs
        for c in range(len(sraws)):
            self.sensor_pairs.append(self._make_sensor_cpair(sraws[c]))
        var pairs = List[_CPair]()
        for c in range(len(raws)):
            pairs.append(self._make_cpair(raws[c], warm))
        return pairs^

    def _warm_start(mut self, pairs: List[_CPair], lo: Int, hi: Int):
        """Apply the accumulated impulses at each anchor (Box2D v3 scheme: the
        soft solve's `-impulseScale·acc` term is what balances this out)."""
        for c in range(lo, hi):
            var pr = pairs[c]
            if self._inactive(pr.a) and self._inactive(pr.b):
                continue
            var n = pr.m.normal
            var tb = tangent_basis(n)
            for k in range(pr.m.count):
                var j = (
                    n * pr.acc[k]
                    + tb[0] * pr.acc_t1[k]
                    + tb[1] * pr.acc_t2[k]
                )
                if not self.bset.is_static(pr.a):
                    self.bset.bodies[pr.a].apply_impulse(
                        -j, self.bset.bodies[pr.a].act(pr.ra[k])
                    )
                if not self.bset.is_static(pr.b):
                    self.bset.bodies[pr.b].apply_impulse(
                        j, self.bset.bodies[pr.b].act(pr.rb[k])
                    )

    def step(mut self, dt: Real, gravity: Vec3, iters: Int = 8):
        # 1. Gravity on dynamic bodies (velocity level).
        for i in range(len(self.bset.bodies)):
            if not self.bset.is_static(i):
                var f = gravity / self.bset.bodies[i].inv_mass()  # force = m·g
                self.bset.bodies[i].integrate_force(dt, f, Vec3(0, 0, 0, 0))
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
        for i in range(len(self.bset.bodies)):
            if not self.bset.is_static(i):
                self.bset.bodies[i].integrate_pose(dt)

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
        var va = Vec3(0, 0, 0, 0)
        var ka = Real(0)
        if not self.bset.is_static(ia):
            va = self.bset.bodies[ia].velocity_at(pwa)
            ka = self.bset.bodies[ia].inv_mass() + self.bset.bodies[ia].angular_factor(
                pwa - self.bset.bodies[ia].position(), e
            )
        var vb = Vec3(0, 0, 0, 0)
        var kb = Real(0)
        if not self.bset.is_static(ib):
            vb = self.bset.bodies[ib].velocity_at(pwb)
            kb = self.bset.bodies[ib].inv_mass() + self.bset.bodies[ib].angular_factor(
                pwb - self.bset.bodies[ib].position(), e
            )
        var denom = ka + kb
        if denom <= 0:
            return 0
        var vr = dot(vb - va, e)
        var bias = bias_rate * c if use_bias else Real(0)
        var dl = -ms * (vr + bias) / denom - isc * acc_e
        var j = e * dl
        if not self.bset.is_static(ia):
            self.bset.bodies[ia].apply_impulse(-j, pwa)
        if not self.bset.is_static(ib):
            self.bset.bodies[ib].apply_impulse(j, pwb)
        return dl

    def _joint_island(self, jt: Joint6) -> Int:
        return self.bset.island[jt.a] if not self.bset.is_static(jt.a) else self.bset.island[jt.b]

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
                var pwa = self.bset.bodies[jt.a].act(jt.la)
                var pwb = self.bset.bodies[jt.b].act(jt.lb)
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
                        var e = Vec3(0, 0, 0, 0)
                        e[ax] = 1
                        var dl = self._joint_axis(
                            jt.a, jt.b, pwa, pwb, e, gap[ax],
                            h, bias_rate, ms, isc, use_bias, jt.acc[ax],
                        )
                        jt.acc[ax] += dl
                    if jt.kind == JOINT_HINGE:
                        var oa = self.bset.bodies[jt.a].act(jt.axis_a) - self.bset.bodies[
                            jt.a
                        ].act(Vec3(0, 0, 0, 0))
                        var ob = self.bset.bodies[jt.b].act(jt.axis_b) - self.bset.bodies[
                            jt.b
                        ].act(Vec3(0, 0, 0, 0))
                        var er = cross(oa, ob)  # small-angle axis error
                        var wa = Vec3(0, 0, 0, 0)
                        var wb2 = Vec3(0, 0, 0, 0)
                        if not self.bset.is_static(jt.a):
                            wa = self.bset.bodies[jt.a].omega_world()
                        if not self.bset.is_static(jt.b):
                            wb2 = self.bset.bodies[jt.b].omega_world()
                        var tb = tangent_basis(oa)
                        for ti in range(2):
                            var t = tb[0] if ti == 0 else tb[1]
                            var kaa = Real(0)
                            var kbb = Real(0)
                            if not self.bset.is_static(jt.a):
                                kaa = self.bset.bodies[jt.a].angular_only_factor(t)
                            if not self.bset.is_static(jt.b):
                                kbb = self.bset.bodies[jt.b].angular_only_factor(t)
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
                            if not self.bset.is_static(jt.a):
                                self.bset.bodies[jt.a].apply_angular_impulse(-limp)
                            if not self.bset.is_static(jt.b):
                                self.bset.bodies[jt.b].apply_angular_impulse(limp)
                            wa = Vec3(0, 0, 0, 0)
                            wb2 = Vec3(0, 0, 0, 0)
                            if not self.bset.is_static(jt.a):
                                wa = self.bset.bodies[jt.a].omega_world()
                            if not self.bset.is_static(jt.b):
                                wb2 = self.bset.bodies[jt.b].omega_world()
                self.joints[c] = jt

    def _warm_start_joints(mut self, island_filter: Int):
        for c in range(len(self.joints)):
            var jt = self.joints[c]
            if self._inactive(jt.a) and self._inactive(jt.b):
                continue
            if island_filter != -2 and self._joint_island(jt) != island_filter:
                continue
            var pwa = self.bset.bodies[jt.a].act(jt.la)
            var pwb = self.bset.bodies[jt.b].act(jt.lb)
            if not self.bset.is_static(jt.a):
                self.bset.bodies[jt.a].apply_impulse(-jt.acc, pwa)
                if jt.kind == JOINT_HINGE:
                    self.bset.bodies[jt.a].apply_angular_impulse(-jt.acc_ang)
            if not self.bset.is_static(jt.b):
                self.bset.bodies[jt.b].apply_impulse(jt.acc, pwb)
                if jt.kind == JOINT_HINGE:
                    self.bset.bodies[jt.b].apply_angular_impulse(jt.acc_ang)

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
            var pwa = self.bset.bodies[pr.a].act(pr.ra[k])
            var pwb = self.bset.bodies[pr.b].act(pr.rb[k])
            # anchors coincided at prep with depth d0; separation since
            # then is the anchor drift along the normal
            var d = pr.m.depths[k] - dot(pwb - pwa, n)
            var va = Vec3(0, 0, 0, 0)
            var ka = Real(0)
            if not self.bset.is_static(pr.a):
                va = self.bset.bodies[pr.a].velocity_at(pwa)
                ka = self.bset.bodies[pr.a].inv_mass() + self.bset.bodies[
                    pr.a
                ].angular_factor(pwa - self.bset.bodies[pr.a].position(), n)
            var vb = Vec3(0, 0, 0, 0)
            var kb = Real(0)
            if not self.bset.is_static(pr.b):
                vb = self.bset.bodies[pr.b].velocity_at(pwb)
                kb = self.bset.bodies[pr.b].inv_mass() + self.bset.bodies[
                    pr.b
                ].angular_factor(pwb - self.bset.bodies[pr.b].position(), n)
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
                if not self.bset.is_static(pr.a):
                    self.bset.bodies[pr.a].apply_impulse(-j, pwa)
                if not self.bset.is_static(pr.b):
                    self.bset.bodies[pr.b].apply_impulse(j, pwb)
            # Coulomb friction: tangent impulses clamped to mu * lambda_n.
            var tb = tangent_basis(n)
            var cap = mu * pr.acc[k]
            for ti in range(2):
                var t = tb[0] if ti == 0 else tb[1]
                var vat = Vec3(0, 0, 0, 0)
                var kat = Real(0)
                if not self.bset.is_static(pr.a):
                    vat = self.bset.bodies[pr.a].velocity_at(pwa)
                    kat = self.bset.bodies[pr.a].inv_mass() + self.bset.bodies[
                        pr.a
                    ].angular_factor(
                        pwa - self.bset.bodies[pr.a].position(), t
                    )
                var vbt = Vec3(0, 0, 0, 0)
                var kbt = Real(0)
                if not self.bset.is_static(pr.b):
                    vbt = self.bset.bodies[pr.b].velocity_at(pwb)
                    kbt = self.bset.bodies[pr.b].inv_mass() + self.bset.bodies[
                        pr.b
                    ].angular_factor(
                        pwb - self.bset.bodies[pr.b].position(), t
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
                    if not self.bset.is_static(pr.a):
                        self.bset.bodies[pr.a].apply_impulse(-jt, pwa)
                    if not self.bset.is_static(pr.b):
                        self.bset.bodies[pr.b].apply_impulse(jt, pwb)
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
        (the relative displacement already contains both velocities).

        Sphere/capsule still use their conservative `half` box (a superset of
        the real shape centred correctly on the body, so the sweep can only
        clamp too early, never wrongly): that is unchanged. Hull, trimesh
        and heightfield have no exact box TOI at all -- a hull's box is not
        its shape, and a static mesh's `half` is not even centred on the
        body (F3), so sweeping either as a box can freeze a body far from
        its real surface. Rather than build a per-kind sweep for three kinds
        that already get a discrete/speculative contact every substep, this
        sweep just skips any pair touching one of them (the conservative
        option the spec allows): CCD there falls back to whatever the
        ordinary contact path already provides, with the residual tunnelling
        risk that implies for genuinely fast movers against those three
        kinds specifically -- no worse than before CCD existed for them.
        `should_collide`/sensors are consulted too, so a filtered or sensor
        pair is never clamped here regardless of shape (17.0f / F4c)."""
        var n = len(self.bset.bodies)
        var frac = List[Real]()
        for _ in range(n):
            frac.append(1)
        for i in range(n):
            if self._inactive(i):
                continue
            var ki = self.colliders.shape[i]
            if ki == SHAPE_HULL or ki == SHAPE_TRIMESH or ki == SHAPE_HEIGHTFIELD:
                continue  # no exact box TOI for this kind (see docstring)
            var vi = self.bset.bodies[i].linear_velocity()
            if dot(vi, vi) * h * h < 1e-12:
                continue
            for j in range(n):
                if j == i:
                    continue
                if not self.colliders.should_collide(i, j):
                    continue
                if self.colliders.is_sensor(i) or self.colliders.is_sensor(j):
                    continue
                var kj = self.colliders.shape[j]
                if kj == SHAPE_HULL or kj == SHAPE_TRIMESH or kj == SHAPE_HEIGHTFIELD:
                    continue
                var vj = Vec3(0, 0, 0, 0)
                if not self._inactive(j):
                    vj = self.bset.bodies[j].linear_velocity()
                var rel = (vi - vj) * h
                var ha = self.colliders.half[i]
                var hb = self.colliders.half[j]
                var thin = min(
                    min(ha[0], min(ha[1], ha[2])),
                    min(hb[0], min(hb[1], hb[2])),
                )
                if dot(rel, rel) <= (thin * 0.5) * (thin * 0.5):
                    continue  # cannot jump the pair's thinnest feature
                var r = swept_box_toi(
                    self.bset.bodies[j].position(),
                    self._axes(j),
                    hb,
                    self.bset.bodies[i].position(),
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
            self.bset.bodies[i].integrate_pose(h * f)

    def _restitution_pass(
        mut self,
        mut pairs: List[_CPair],
        lo: Int,
        hi: Int,
        iters: Int,
        threshold: Real = 1.0,  # m/s approach speed to trigger (SolverConfig
        # .restitution_threshold; default matches the old comptime REST_THRESH)
    ):
        """Box2D v3 restitution: after the substeps have resolved penetration,
        push each point that arrived faster than the threshold back toward
        `vn = -e·vn0` (its own clamped accumulator, so sweeps can correct)."""
        for _ in range(iters):
            for c in range(lo, hi):
                var pr = pairs[c]
                var e = max(
                    self.bset.restitution[pr.a], self.bset.restitution[pr.b]
                )
                if e <= 0:
                    continue
                var n = pr.m.normal
                for k in range(pr.m.count):
                    if pr.vn0[k] >= -threshold:
                        continue
                    var pwa = self.bset.bodies[pr.a].act(pr.ra[k])
                    var pwb = self.bset.bodies[pr.b].act(pr.rb[k])
                    var va = Vec3(0, 0, 0, 0)
                    var ka = Real(0)
                    if not self.bset.is_static(pr.a):
                        va = self.bset.bodies[pr.a].velocity_at(pwa)
                        ka = self.bset.bodies[pr.a].inv_mass() + self.bset.bodies[
                            pr.a
                        ].angular_factor(pwa - self.bset.bodies[pr.a].position(), n)
                    var vb = Vec3(0, 0, 0, 0)
                    var kb = Real(0)
                    if not self.bset.is_static(pr.b):
                        vb = self.bset.bodies[pr.b].velocity_at(pwb)
                        kb = self.bset.bodies[pr.b].inv_mass() + self.bset.bodies[
                            pr.b
                        ].angular_factor(pwb - self.bset.bodies[pr.b].position(), n)
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
                        if not self.bset.is_static(pr.a):
                            self.bset.bodies[pr.a].apply_impulse(-j, pwa)
                        if not self.bset.is_static(pr.b):
                            self.bset.bodies[pr.b].apply_impulse(j, pwb)
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
        var vb = self.bset.bodies[b].velocity_at(nw)
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
            # particle vs every collider (bodies default to boxes in this
            # scene; hull/trimesh/heightfield route through `ColliderSet`
            # below, sphere/capsule keep their own exact closed forms here).
            for i in range(np):
                var p = self.softs[s].pts[i]
                for b in range(len(self.bset.bodies)):
                    var kind = self.colliders.shape[b]
                    if (
                        kind == SHAPE_HULL
                        or kind == SHAPE_TRIMESH
                        or kind == SHAPE_HEIGHTFIELD
                    ):
                        # Point-vs-shape closest point through the collider
                        # registry (17.0f / F4b): a hull's SAT over its own
                        # faces, a mesh's triangle candidates + closest point
                        # on triangle -- see `ColliderSet.soft_particle_contact`.
                        # These three kinds do not get the `ccd` sweep the
                        # box/sphere/capsule paths below have; a fast particle
                        # can still tunnel through one within a substep. That
                        # is the same conservative scope limit `_ccd_advance`
                        # documents for rigid bodies against these kinds.
                        var res = self.colliders.soft_particle_contact(
                            b, self._pose(b), p.x, r
                        )
                        if res[0]:
                            var nw3 = res[1]
                            if smu > 0:
                                nw3 = self._soft_fric(
                                    b, p.x,
                                    Vec3(
                                        prev[i * 3], prev[i * 3 + 1],
                                        prev[i * 3 + 2], 0,
                                    ),
                                    nw3, res[2], h, smu,
                                )
                            var dx3 = nw3 - p.x
                            p.x = nw3
                            if not self.bset.is_static(b):
                                var j3 = dx3 * (-(1 / p.w) / h)
                                self.bset.bodies[b].apply_impulse(j3, nw3)
                                if self.bset.sleeping[b]:
                                    self.bset.sleeping[b] = False
                                    self.bset.sleep_timer[b] = 0
                        continue
                    if kind != SHAPE_BOX:
                        # sphere / capsule: radial pushout from the closest
                        # interior point (capsule = sphere at the closest
                        # point of its world axis segment); same impulse
                        # coupling as the box path below
                        var hh2 = self.colliders.half[b]
                        var rad = hh2[0]
                        var cen = self.bset.bodies[b].position()
                        if self.colliders.shape[b] == 2:
                            var axw = self.bset.bodies[b].act(
                                Vec3(0, hh2[1], 0, 0)
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
                                0,
                            )
                            var s0 = pv2 + self.bset.bodies[
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
                                    0,
                                ),
                                nw2,
                                (nw2 - cen) * (1 / rr),
                                h,
                                smu,
                            )
                        if hit:
                            var dx2 = nw2 - p.x
                            p.x = nw2
                            if not self.bset.is_static(b):
                                var j2 = dx2 * (-(1 / p.w) / h)
                                self.bset.bodies[b].apply_impulse(j2, nw2)
                                if self.bset.sleeping[b]:
                                    self.bset.sleeping[b] = False
                                    self.bset.sleep_timer[b] = 0
                        continue
                    var lp = self.bset.bodies[b].to_local(p.x)
                    var hh = self.colliders.half[b]
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
                        , 0)
                        var lp0 = self.bset.bodies[b].to_local(
                            pv + self.bset.bodies[b].linear_velocity() * h
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
                    var nw = self.bset.bodies[b].act(lp)
                    if smu > 0:
                        # world face normal from a unit local offset
                        var lpo = lp
                        lpo[ax] = sgn * (hh[ax] + r + 1)
                        nw = self._soft_fric(
                            b,
                            p.x,
                            Vec3(
                                prev[i * 3], prev[i * 3 + 1], prev[i * 3 + 2]
                            , 0),
                            nw,
                            self.bset.bodies[b].act(lpo) - nw,
                            h,
                            smu,
                        )
                    var dx = nw - p.x
                    p.x = nw
                    if not self.bset.is_static(b):
                        # equal-and-opposite impulse into the dynamic body
                        var j = dx * (-(1 / p.w) / h)
                        self.bset.bodies[b].apply_impulse(j, nw)
                        if self.bset.sleeping[b]:
                            self.bset.sleeping[b] = False
                            self.bset.sleep_timer[b] = 0
                self.softs[s].pts[i] = p
            # velocities from positions
            for i in range(np):
                var p = self.softs[s].pts[i]
                var pv = Vec3(prev[i * 3], prev[i * 3 + 1], prev[i * 3 + 2], 0)
                p.v = (p.x - pv) * (damp / h)
                self.softs[s].pts[i] = p

    def _pair_island(self, pr: _CPair) -> Int:
        return self.bset.island[pr.a] if not self.bset.is_static(pr.a) else self.bset.island[pr.b]

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
        rest_threshold: Real = 1.0,
    ):
        """The full substep loop restricted to one island: its bodies, its
        contiguous pair range, its joints. Islands share nothing, so running
        these in parallel is bit-identical to running them in sequence."""
        for _ in range(substeps):
            for i in range(len(self.bset.bodies)):
                if self.bset.island[i] == label and not self._inactive(i):
                    var f = gravity / self.bset.bodies[i].inv_mass()
                    self.bset.bodies[i].integrate_force(h, f, Vec3(0, 0, 0, 0))
            self._warm_start(pairs, plo, phi)
            self._warm_start_joints(label)
            self._joint_sweep(
                h, bias_rate, mass_scale, impulse_scale, True, iters, label
            )
            self._soft_sweep(
                pairs, plo, phi, h, bias_rate, mass_scale,
                impulse_scale, True, iters, mu,
            )
            for i in range(len(self.bset.bodies)):
                if self.bset.island[i] == label and not self._inactive(i):
                    self.bset.bodies[i].integrate_pose(h)
            self._joint_sweep(h, bias_rate, 1, 0, False, 2, label)
            self._soft_sweep(pairs, plo, phi, h, bias_rate, 1, 0, False, 2, mu)
        self._restitution_pass(pairs, plo, phi, 4, rest_threshold)

    def _emit_events(mut self, pairs: List[_CPair]):
        """Diff this step's contact set against last step's: began / stay /
        ended (`collision.contact_events.diff_events`).

        The set is derived, not tracked. The solver already knows exactly
        which contacts exist this step — it just built them — and the warm-
        start cache is last step's answer to the same question, so the
        events are a sorted merge of two key lists and nothing has to be
        maintained incrementally or invalidated when a body is removed.

        Sensor overlaps are included: a trigger volume that never receives an
        impulse still has to say when something entered it, and that is the
        whole reason sensors exist."""
        self.events = List[ContactEvent]()
        var cur = List[Int](capacity=len(pairs) + len(self.sensor_pairs))
        for c in range(len(pairs)):
            cur.append(pack_key(pairs[c].a, pairs[c].b, pairs[c].feat))
        for c in range(len(self.sensor_pairs)):
            ref sp = self.sensor_pairs[c]
            cur.append(pack_key(sp.a, sp.b, sp.feat))
        sort(cur)
        diff_events(cur, self._prev_keys, self.events)
        self._prev_keys = cur^

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
        """Thin forwarder (audit F19): builds a `SolverConfig` from these
        keyword arguments and calls `step`. Kept with its original keyword
        signature so every existing call site (~100 across tests/benchmarks/
        examples) keeps compiling and behaving identically -- `step(dt,
        gravity, cfg)` is the config-driven entry point new code should
        prefer."""
        var cfg = SolverConfig()
        cfg.substeps = substeps
        cfg.iters = iters
        cfg.hertz = hertz
        cfg.zeta = zeta
        cfg.default_friction = mu
        cfg.ccd = ccd
        cfg.parallel = parallel
        cfg.colored = colored
        cfg.broadphase = broadphase
        cfg.workers = workers
        self.step(dt, gravity, cfg)

    def step(mut self, dt: Real, gravity: Vec3, cfg: SolverConfig):
        """Sub-stepped soft-constraint step (Box2D v3 "Soft Step" scheme).

        Collide once, then per substep integrate velocities, solve with soft
        bias, integrate poses, and RELAX (bias-free sweep) so the bias energy
        never becomes bounce. (Overloaded with the legacy one-shot `step(dt,
        gravity, iters: Int = 8)` above -- the two are disambiguated by the
        3rd argument's type/arity, never both callable with the same args.)

        `cfg.parallel=True` solves ISLANDS on worker threads (scenes without
        soft bodies and without ccd): islands are disjoint by construction,
        so the result is bit-identical to the serial path
        (`test_islands_par`). When `cfg.parallel=True` but soft bodies, ccd,
        or colored solving are also requested, this silently falls back to
        the serial path below (audit F23) -- counted in
        `self.counters[PARALLEL_FALLBACK_SERIAL]` rather than staying
        invisible.

        `cfg.workers` pins the fan-out width (0 = let the runtime use every
        core). Because the partition — islands, or a color's pairs — is what
        makes the writes disjoint, the worker count changes only the
        SCHEDULE, never the result: any `workers` is bit-identical to serial.
        That invariance is what makes a core-scaling sweep (`bench_islands`,
        `bench_colored`) a fair measurement rather than a different
        computation per point."""
        var substeps = cfg.substeps
        var iters = cfg.iters
        var hertz = cfg.hertz
        var zeta = cfg.zeta
        var mu = cfg.default_friction
        var ccd = cfg.ccd
        var parallel = cfg.parallel
        var colored = cfg.colored
        var broadphase = cfg.broadphase
        var workers = cfg.workers
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
            for _ in range(len(self.bset.bodies)):
                mask.append(0)
            var pcol = List[Int]()
            for pc in range(len(pairs)):
                var used = 0
                if not self.bset.is_static(pairs[pc].a):
                    used |= mask[pairs[pc].a]
                if not self.bset.is_static(pairs[pc].b):
                    used |= mask[pairs[pc].b]
                var col = 0
                while (used >> col) & 1 == 1:
                    col += 1
                pcol.append(col)
                if col + 1 > n_colors:
                    n_colors = col + 1
                if not self.bset.is_static(pairs[pc].a):
                    mask[pairs[pc].a] |= 1 << col
                if not self.bset.is_static(pairs[pc].b):
                    mask[pairs[pc].b] |= 1 << col
            var pairs3 = List[_CPair]()
            for col in range(n_colors):
                clo.append(len(pairs3))
                for pc in range(len(pairs)):
                    if pcol[pc] == col:
                        pairs3.append(pairs[pc])
                chi.append(len(pairs3))
            pairs = pairs3^
        if parallel and (colored or len(self.softs) > 0 or ccd):
            # F23: the island-parallel path assumes no soft bodies, no ccd
            # and no colored solving; falling back is correct but used to be
            # silent -- count it so a caller relying on the parallel path
            # can notice it never actually ran in parallel.
            self.counters.incr(PARALLEL_FALLBACK_SERIAL)
        if parallel and not colored and len(self.softs) == 0 and not ccd:
            # partition: pairs reordered so each island is a contiguous range
            var labels = List[Int]()
            for i in range(len(self.bset.bodies)):
                if self.bset.island[i] < 0:
                    continue
                var known = False
                for k in range(len(labels)):
                    if labels[k] == self.bset.island[i]:
                        known = True
                        break
                if not known:
                    labels.append(self.bset.island[i])
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
                workers, cfg.restitution_threshold,
            )
            self._update_sleep(dt, cfg)
            if self.events_on:
                self._emit_events(pairs2)
            self.cache = pairs2^
            return
        for _ in range(substeps):
            for i in range(len(self.bset.bodies)):
                if not self._inactive(i):
                    var f = gravity / self.bset.bodies[i].inv_mass()
                    self.bset.bodies[i].integrate_force(h, f, Vec3(0, 0, 0, 0))
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
                for i in range(len(self.bset.bodies)):
                    if not self._inactive(i):
                        self.bset.bodies[i].integrate_pose(h)
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
        self._restitution_pass(pairs, 0, len(pairs), 4, cfg.restitution_threshold)
        self._update_sleep(dt, cfg)
        if self.events_on:
            self._emit_events(pairs)
        self.cache = pairs^  # impulses persist to the next frame


def _solve_islands_parallel[BB: Body6, PBP: BroadPhase](
    mut scene: ContactScene6[BB, PBP],
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
    rest_threshold: Real = 1.0,
):
    """Worker fan-out for `step(cfg.parallel=True)`. A free function so the
    closure captures `scene` as an ordinary argument (the scheduler's
    entity-actor precedent) — islands write disjoint bodies/pairs, so the
    parallel dispatch is race-free and bit-identical to serial."""

    def island_work(k: Int) {mut scene, mut pairs2, imm plo, imm phi, imm labels, imm gravity, imm h, imm substeps, imm iters, imm bias_rate, imm mass_scale, imm impulse_scale, imm mu, imm rest_threshold}:
        scene._solve_island(
            pairs2, plo[k], phi[k], labels[k], gravity, h,
            substeps, iters, bias_rate, mass_scale, impulse_scale, mu,
            rest_threshold,
        )

    # `workers <= 0` means "let the runtime pick" (all cores); a positive
    # value pins the fan-out width so the core-scaling curve can be measured.
    # Islands are disjoint, so the RESULT is worker-count-invariant either way
    # (`test_islands_par` gates this).
    if workers > 0:
        parallelize(island_work, len(labels), workers)
    else:
        parallelize(island_work, len(labels))


def _solve_color_parallel[BB: Body6, PBP: BroadPhase](
    mut scene: ContactScene6[BB, PBP],
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
    capture-list closure pattern as `_solve_islands_parallel`). Same-color
    pairs share no dynamic body, so the writes are disjoint and the result is
    bit-identical to solving the color serially."""

    def pair_work(k: Int) {mut scene, mut pairs2, imm lo, imm h, imm bias_rate, imm mass_scale, imm impulse_scale, imm use_bias, imm mu}:
        scene._solve_pair(
            pairs2, lo + k, h, bias_rate, mass_scale, impulse_scale,
            use_bias, mu,
        )

    if workers > 0:
        parallelize(pair_work, hi - lo, workers)
    else:
        parallelize(pair_work, hi - lo)


def write_state[W: StateWriter](sc: ContactScene6[QuatBody6], mut out: W):
    """Full snapshot of everything dynamical (audit F5/F20): rigid body
    state, the per-collider payload each shape kind needs to reconstruct
    (`ColliderSet`'s side tables), joints, soft bodies, the cross-frame
    warm-start cache, and -- new in this commit -- the contact-event
    stream's own state (`events_on`, `_prev_keys`). Previously omitted, so
    `_emit_events`'s `diff_events` compared this step's contacts against an
    EMPTY `_prev_keys` right after a load and reported a spurious `began`
    event for every contact that was already live before the save (F20).

    A free function, not a `ContactScene6` method: the wire format reads
    QuatBody6-specific raw fields (`q`, `omega`, `inertia`) that the
    representation-agnostic `Body6` trait deliberately does not expose (a
    `ScrewBody6` has no quaternion), so this is scoped to
    `ContactScene6[QuatBody6]` exactly the way `physics/serialize.mojo`'s
    public API already was before this commit. `out: StateWriter` decides
    HOW each field is encoded; this function decides only WHICH fields and
    in what order (`physics/state_io.mojo`'s docstring)."""
    out.wi(len(sc.bset.bodies))
    for i in range(len(sc.bset.bodies)):
        var b = sc.bset.bodies[i]
        out.wv(b.pos)
        out.wf(b.q.x)
        out.wf(b.q.y)
        out.wf(b.q.z)
        out.wf(b.q.w)
        out.wv(b.vel)
        out.wv(b.omega)
        out.wf(b.inertia.mass)
        out.wf(b.inertia.ix)
        out.wf(b.inertia.iy)
        out.wf(b.inertia.iz)
        out.wv(sc.colliders.half[i])
        out.wi(1 if sc.bset.is_static(i) else 0)
        out.wi(sc.colliders.shape[i])
        out.wf(sc.bset.restitution[i])
        out.wi(1 if sc.bset.sleeping[i] else 0)
        out.wf(sc.bset.sleep_timer[i])
        out.wi(Int(sc.colliders.category[i]))
        out.wi(Int(sc.colliders.mask[i]))
        out.wi(1 if sc.colliders.sensor[i] else 0)
        # Shape payload for the kinds that keep their geometry in a side
        # table -- a snapshot that restored a hull body without its
        # vertices would load cleanly and then index an empty table on the
        # next contact, so the geometry travels with the body even though a
        # level mesh can be large: this format is a full state snapshot,
        # not an asset reference.
        if sc.colliders.shape[i] == SHAPE_HULL:
            ref hl = sc.colliders.hulls[sc.colliders.hull_id[i]]
            out.wi(len(hl.v))
            for k in range(len(hl.v)):
                out.wf(hl.v[k])
        elif sc.colliders.shape[i] == SHAPE_TRIMESH:
            ref ms = sc.colliders.meshes[sc.colliders.mesh_id[i]]
            out.wi(len(ms.v))
            for k in range(len(ms.v)):
                out.wf(ms.v[k])
            out.wi(len(ms.idx))
            for k in range(len(ms.idx)):
                out.wi(ms.idx[k])
        elif sc.colliders.shape[i] == SHAPE_HEIGHTFIELD:
            ref hf = sc.colliders.fields[sc.colliders.mesh_id[i]]
            out.wi(hf.nx)
            out.wi(hf.nz)
            out.wf(hf.cell)
            out.wf(hf.ox)
            out.wf(hf.oz)
            out.wi(len(hf.h))
            for k in range(len(hf.h)):
                out.wf(hf.h[k])
    out.wi(len(sc.joints))
    for j in range(len(sc.joints)):
        var jt = sc.joints[j]
        out.wi(jt.kind)
        out.wi(jt.a)
        out.wi(jt.b)
        out.wv(jt.la)
        out.wv(jt.lb)
        out.wf(jt.rest)
        out.wv(jt.axis_a)
        out.wv(jt.axis_b)
        out.wv(jt.acc)
        out.wv(jt.acc_ang)
    out.wi(len(sc.softs))
    for k in range(len(sc.softs)):
        out.wf(sc.softs[k].alpha)
        out.wf(sc.softs[k].radius)
        out.wf(sc.softs[k].damp)
        out.wf(sc.softs[k].mu)
        out.wi(len(sc.softs[k].pts))
        for p in range(len(sc.softs[k].pts)):
            var pt = sc.softs[k].pts[p]
            out.wv(pt.x)
            out.wv(pt.v)
            out.wf(pt.w)
        out.wi(len(sc.softs[k].edges))
        for e in range(len(sc.softs[k].edges)):
            var ed = sc.softs[k].edges[e]
            out.wi(ed.a)
            out.wi(ed.b)
            out.wf(ed.rest)
            out.wf(ed.lam)
    out.wi(len(sc.cache))
    for c in range(len(sc.cache)):
        var pr = sc.cache[c]
        out.wi(pr.a)
        out.wi(pr.b)
        out.wi(pr.feat)  # triangle index for mesh contacts, 0 otherwise
        out.wi(1 if pr.m.hit else 0)
        out.wv(pr.m.normal)
        out.wi(pr.m.count)
        for p in range(4):
            out.wv(pr.m.points[p])
            out.wf(pr.m.depths[p])
            out.wf(pr.acc[p])
            out.wf(pr.acc_t1[p])
            out.wf(pr.acc_t2[p])
            out.wv(pr.ra[p])
            out.wv(pr.rb[p])
            out.wf(pr.vn0[p])
            out.wf(pr.racc[p])
    # F20: the event stream's own state, so a resumed scene's events
    # continue identically instead of restarting from an empty history.
    out.wi(1 if sc.events_on else 0)
    out.wi(len(sc._prev_keys))
    for k in range(len(sc._prev_keys)):
        out.wi(sc._prev_keys[k])


def read_state[R: StateReader](mut sc: ContactScene6[QuatBody6], mut r: R) raises:
    """The `write_state` counterpart -- see its docstring for the field
    order and why this is a free function scoped to `ContactScene6
    [QuatBody6]` rather than a generic method. `sc` must be a freshly
    constructed, empty scene (`ContactScene6[QuatBody6]()`); this only
    appends, through `BodySet.push` (F5's one append site) for the body
    lists and directly for `ColliderSet`'s side tables (unchanged from
    before this commit -- `ColliderSet` has no `push`-style single entry
    point of its own yet, and adding one is out of this commit's scope).

    Every count and every body/joint index read from `r` is validated
    before use: a negative count or an out-of-range index means the input
    is truncated or corrupt (an environment-class failure, not a programmer
    error -- docs/ARCHITECTURE.md S2), so this raises rather than indexing
    out of bounds the way the pre-F20 reader could (F20/E20)."""
    var nb = r.ri()
    if nb < 0:
        raise Error("physics.serialize: corrupt snapshot (negative body count)")
    for _ in range(nb):
        var pos = r.rv()
        var qx = r.rf()
        var qy = r.rf()
        var qz = r.rf()
        var qw = r.rf()
        var vel = r.rv()
        var omega = r.rv()
        var im = r.rf()
        var ix = r.rf()
        var iy = r.rf()
        var iz = r.rf()
        var half = r.rv()
        var is_static = r.ri() == 1
        var kind = r.ri()
        var restitution = r.rf()
        var sleeping = r.ri() == 1
        var sleep_timer = r.rf()
        var category = UInt32(r.ri())
        var mask = UInt32(r.ri())
        var sensor = r.ri() == 1
        var motion = MOTION_STATIC if is_static else MOTION_DYNAMIC
        var id = sc.bset.push(
            QuatBody6(
                pos, Quat(qx, qy, qz, qw), vel, omega,
                Inertia3(im, ix, iy, iz),
            ),
            motion,
        )
        var bi = id.index()
        if bi != len(sc.colliders.shape):
            raise Error(
                "physics.serialize: body/collider index desync on load"
            )
        sc.bset.restitution[bi] = restitution
        sc.bset.sleeping[bi] = sleeping
        sc.bset.sleep_timer[bi] = sleep_timer
        sc.colliders.shape.append(kind)
        sc.colliders.half.append(half)
        sc.colliders.category.append(category)
        sc.colliders.mask.append(mask)
        sc.colliders.sensor.append(sensor)
        sc.colliders.hull_id.append(-1)
        sc.colliders.mesh_id.append(-1)
        sc.colliders.world_aabb.append(
            AABB[3](Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))
        )
        if kind == SHAPE_HULL:
            var nv = r.ri()
            if nv < 0:
                raise Error("physics.serialize: corrupt snapshot (negative hull vertex count)")
            var hv = List[Real](capacity=nv)
            for _ in range(nv):
                hv.append(r.rf())
            sc.colliders.hull_id[bi] = len(sc.colliders.hulls)
            sc.colliders.hulls.append(HullShape(hv))
        elif kind == SHAPE_TRIMESH:
            var nv = r.ri()
            if nv < 0:
                raise Error("physics.serialize: corrupt snapshot (negative mesh vertex count)")
            var mv = List[Real](capacity=nv)
            for _ in range(nv):
                mv.append(r.rf())
            var ni = r.ri()
            if ni < 0:
                raise Error("physics.serialize: corrupt snapshot (negative mesh index count)")
            var mi = List[Int](capacity=ni)
            for _ in range(ni):
                mi.append(r.ri())
            sc.colliders.mesh_id[bi] = len(sc.colliders.meshes)
            var tm = TriMesh(mv, mi)
            sc.colliders.world_aabb[bi] = tm.bounds()
            sc.colliders.meshes.append(tm^)
        elif kind == SHAPE_HEIGHTFIELD:
            var nx = r.ri()
            var nz = r.ri()
            var cell = r.rf()
            var ox = r.rf()
            var oz = r.rf()
            var nh = r.ri()
            if nh < 0:
                raise Error("physics.serialize: corrupt snapshot (negative heightfield sample count)")
            var hh = List[Real](capacity=nh)
            for _ in range(nh):
                hh.append(r.rf())
            sc.colliders.mesh_id[bi] = len(sc.colliders.fields)
            var hfld = HeightField(hh, nx, nz, cell, ox, oz)
            sc.colliders.world_aabb[bi] = hfld.bounds()
            sc.colliders.fields.append(hfld^)
    var nj = r.ri()
    if nj < 0:
        raise Error("physics.serialize: corrupt snapshot (negative joint count)")
    for _ in range(nj):
        var kind = r.ri()
        var a = r.ri()
        var b = r.ri()
        var la = r.rv()
        var lb = r.rv()
        var rest = r.rf()
        var axa = r.rv()
        var axb = r.rv()
        var acc = r.rv()
        var acca = r.rv()
        if a < 0 or a >= len(sc.bset.bodies) or b < 0 or b >= len(sc.bset.bodies):
            raise Error("physics.serialize: corrupt snapshot (joint body index out of range)")
        sc.joints.append(Joint6(kind, a, b, la, lb, rest, axa, axb, acc, acca))
    var ns = r.ri()
    if ns < 0:
        raise Error("physics.serialize: corrupt snapshot (negative soft-body count)")
    for _ in range(ns):
        var sb = SoftBody()
        sb.alpha = r.rf()
        sb.radius = r.rf()
        sb.damp = r.rf()
        sb.mu = r.rf()
        var np = r.ri()
        if np < 0:
            raise Error("physics.serialize: corrupt snapshot (negative particle count)")
        for _ in range(np):
            var x = r.rv()
            var v = r.rv()
            var w = r.rf()
            sb.pts.append(SP(x, v, w))
        var ne = r.ri()
        if ne < 0:
            raise Error("physics.serialize: corrupt snapshot (negative edge count)")
        for _ in range(ne):
            var ea = r.ri()
            var eb = r.ri()
            var er = r.rf()
            var el = r.rf()
            sb.edges.append(SEdge(ea, eb, er, el))
        _ = sc.add_soft(sb^)
    var nc = r.ri()
    if nc < 0:
        raise Error("physics.serialize: corrupt snapshot (negative cache-pair count)")
    for _ in range(nc):
        var a = r.ri()
        var b = r.ri()
        var feat = r.ri()
        if a < 0 or a >= len(sc.bset.bodies) or b < 0 or b >= len(sc.bset.bodies):
            raise Error("physics.serialize: corrupt snapshot (cache-pair body index out of range)")
        var m = ContactManifold[3]()
        m.hit = r.ri() == 1
        m.normal = r.rv()
        m.count = r.ri()
        var pr = _CPair(
            a, b, feat, m,
            Array[Real, 4](fill=0), Array[Real, 4](fill=0),
            Array[Real, 4](fill=0),
            Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
            Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
            Array[Real, 4](fill=0), Array[Real, 4](fill=0),
        )
        for p in range(4):
            pr.m.points[p] = r.rv()
            pr.m.depths[p] = r.rf()
            pr.acc[p] = r.rf()
            pr.acc_t1[p] = r.rf()
            pr.acc_t2[p] = r.rf()
            pr.ra[p] = r.rv()
            pr.rb[p] = r.rv()
            pr.vn0[p] = r.rf()
            pr.racc[p] = r.rf()
        sc.cache.append(pr)
    # F20: restore the event stream's own state.
    sc.events_on = r.ri() == 1
    var nk = r.ri()
    if nk < 0:
        raise Error("physics.serialize: corrupt snapshot (negative event-key count)")
    sc._prev_keys = List[Int](capacity=nk)
    for _ in range(nk):
        sc._prev_keys.append(r.ri())
