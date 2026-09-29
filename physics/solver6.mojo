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

from std.math import sqrt, isfinite
from std.os import abort
from max.algorithm import parallelize
from geometry.vec import Real, Vec3, WorldType, dot, cross, tangent_basis
from geometry.aabb import AABB
from geometry.quat import Quat
from collision.manifold import ContactManifold, Axes3
from collision.world_query import (
    QueryFilter,
    Hit,
    Probe,
    Penetration,
    ray_cast as wq_ray_cast,
    sphere_cast as wq_sphere_cast,
    capsule_cast as wq_capsule_cast,
    overlap_sphere as wq_overlap_sphere,
    capsule_penetrations as wq_capsule_penetrations,
    point_distance as wq_point_distance,
)
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
from diag.counters import Counters, PARALLEL_FALLBACK_SERIAL, COLOR_OVERFLOW, NAN_QUARANTINED
from diag.log import LogRing, log
from diag.level import Level, DEBUG_DRAW_ON
from diag.trace import TraceBuffer
from diag.draw import DrawQueue
from .rigid6 import Body6, QuatBody6, Inertia3, Pose6
from .body_set import BodySet, BodyId, MOTION_STATIC, MOTION_DYNAMIC, MOTION_KINEMATIC
from .solver_config import SolverConfig
from .state_io import StateWriter, StateReader
from .softbody import SoftBody, SP, SEdge
from .contact6 import (
    ContactConstraint,
    contact_island,
    make_contact,
    cache_index,
    make_sensor_contact,
    warm_start_contacts,
    solve_point,
    soft_sweep,
    sweep_colored,
    restitution_pass,
    ContactRule,
    apply_rules,
)
from .joints6 import (
    Joint6,
    JOINT_BALL,
    JOINT_DISTANCE,
    JOINT_HINGE,
    warm_start_joints,
    joint_sweep,
    JOINT_BROKEN,
    check_breaks,
    sample_loads,
    AngularDrive,
    warm_start_drives,
    drive_sweep,
)
from .islands import (
    island_count as count_islands,
    island_labels,
    refresh_islands,
    update_sleep,
    wake_island,
)
from .ccd6 import ccd_advance
from .soft_couple import softbody_pass


# The `_Pt` / `_LV` / `_Half` wrappers that used to sit here existed for one
# stated reason: a bare `List[SIMD[_, 3]]` corrupted on realloc. Width 3 was
# never a supported SIMD width; `Vec3` is four lanes now and the claim was
# retested before removal -- a list grown from capacity 0 to 10,000 elements
# reads back with zero wrong entries.


struct ContactScene6[B: Body6, BP: BroadPhase = BVHBroadPhase[3]](Movable, Deinitable):
    """Boxes (dynamic or static) under gravity with contact impulses."""

    var bset: BodySet[Self.B]  # body identity + per-body SoA (F5): bodies,
    # motion (static/dynamic), sleeping, sleep_timer, island, restitution --
    # see `physics/body_set.mojo`.
    var cache: List[ContactConstraint]  # last frame's pairs (cross-frame warm starting)
    var joints: List[Joint6]
    var drives: List[AngularDrive]  # ROADMAP 17.2: soft angular motors
    # ROADMAP 17.29: per-joint break thresholds (parallel to `joints`,
    # +inf = unbreakable) and the joints released by the last step.
    var break_force: List[Real]
    var break_torque: List[Real]
    var broken_joints: List[Int]
    var peak_force: List[Real]  # per-substep load peaks of the current step
    var peak_torque: List[Real]
    var any_break: Bool  # some joint has a finite threshold: sample loads
    var rules: List[ContactRule]  # ROADMAP 17.26: per-contact modification
    var softs: List[SoftBody]
    var colliders: ColliderSet  # shape kinds, hull/mesh tables, filters (F1)
    var counters: Counters  # diag counters (F23: parallel fallback to serial)
    # ROADMAP 17.0h: `diag` wired into the production solver path.
    # `trace`/`log` are solver-owned, mirroring `counters` above (a caller
    # reads `sc.trace`/`sc.log` directly, the same shape as `sc.counters`);
    # `trace` costs nothing when `-D LUDENS_TRACE` is off (`begin`/`end` are
    # `comptime if`-eliminated -- see `diag/trace.mojo`) and `log` costs
    # nothing to construct-and-never-push. `draw` likewise costs nothing
    # unless `-D LUDENS_DEBUG_DRAW` is defined; kept on the scene rather than
    # threaded through `step`/`step_soft` as a new parameter because both are
    # ~100-call-site APIs (same reasoning as `SolverConfig.validated()`) --
    # "the caller passes/owns" the spec asks for means the caller drains
    # `sc.draw`/calls `sc.draw.tick()` every frame, not that it lives on
    # their stack.
    var trace: TraceBuffer
    var log: LogRing[256]
    var draw: DrawQueue[WorldType]
    var bp: Self.BP  # persistent broadphase, used when `step_soft(broadphase=True)`
    # A sensor reports overlap and never receives an impulse. Its pairs are
    # collected separately rather than flagged in `pairs`, so that not one of
    # the solve, warm-start, island or restitution loops needs to learn about
    # them.
    var sensor_pairs: List[ContactConstraint]
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
        self.cache = List[ContactConstraint]()
        self.joints = List[Joint6]()
        self.drives = List[AngularDrive]()
        self.break_force = List[Real]()
        self.break_torque = List[Real]()
        self.broken_joints = List[Int]()
        self.peak_force = List[Real]()
        self.peak_torque = List[Real]()
        self.any_break = False
        self.rules = List[ContactRule]()
        self.softs = List[SoftBody]()
        self.colliders = ColliderSet()
        self.counters = Counters()
        self.trace = TraceBuffer(capacity=512)
        self.log = LogRing[256]()
        self.draw = DrawQueue[WorldType](capacity=1024)
        self.bp = Self.BP()
        self.sensor_pairs = List[ContactConstraint]()
        self.events_on = False
        self.events = List[ContactEvent]()
        self._prev_keys = List[Int]()

    def add_soft(mut self, var sb: SoftBody) -> Int:
        self.softs.append(sb^)
        return len(self.softs) - 1

    def add_joint(mut self, j: Joint6) raises -> Int:
        """Audit E12: a joint whose `a`/`b` body index is out of range would
        be an out-of-bounds write the first time the solver walks `joints`
        (`_joint_sweep`/`_warm_start_joints` index `self.bset.bodies`
        directly) -- caught here, once, at the public boundary, rather than
        left as UB in a release build."""
        var n = len(self.bset.bodies)
        if j.a < 0 or j.a >= n or j.b < 0 or j.b >= n:
            raise Error("ContactScene6.add_joint: body index out of range")
        self.joints.append(j)
        self.break_force.append(Real.MAX)
        self.break_torque.append(Real.MAX)
        self.peak_force.append(0)
        self.peak_torque.append(0)
        return len(self.joints) - 1

    def set_joint_break(mut self, j: Int, force: Real, torque: Real) raises:
        """Joint `j` releases once its constraint force exceeds `force` (N)
        or its torque exceeds `torque` (N·m) -- ROADMAP 17.29. Released
        joints are listed in `broken_joints` after the step that broke
        them and are never solved again."""
        if j < 0 or j >= len(self.joints):
            raise Error("ContactScene6.set_joint_break: joint index out of range")
        if not (force > 0 and torque > 0):
            raise Error("ContactScene6.set_joint_break: thresholds must be > 0")
        self.break_force[j] = force
        self.break_torque[j] = torque
        self.any_break = True

    def add_contact_rule(mut self, r: ContactRule) raises -> Int:
        """Register a per-contact rule (one-way platform, conveyor, friction
        override -- `physics.contact6.ContactRule`)."""
        if r.body < 0 or r.body >= len(self.bset.bodies):
            raise Error("ContactScene6.add_contact_rule: body index out of range")
        self.rules.append(r)
        return len(self.rules) - 1

    def add_drive(mut self, d: AngularDrive) raises -> Int:
        """Register a soft angular motor between bodies `d.a` and `d.b`
        (ROADMAP 17.2). Same boundary check as `add_joint`."""
        var n = len(self.bset.bodies)
        if d.a < 0 or d.a >= n or d.b < 0 or d.b >= n:
            raise Error("ContactScene6.add_drive: body index out of range")
        self.drives.append(d)
        return len(self.drives) - 1

    def island_count(self) -> Int:
        """Number of distinct dynamic islands from the last `step_soft`."""
        return count_islands(self.bset)


    def _push_body(mut self, var b: Self.B, is_static: Bool) -> BodyId:
        """The body-list half of registration, shared by every `add*`
        variant -- always called exactly once per body, through
        `BodySet.push` (the one append site, F5), in lockstep with exactly
        one `self.colliders.add*` call, so the two index spaces stay
        aligned (collider `i` <-> body `i`; `add` below asserts it)."""
        return self.bset.push(b^, MOTION_STATIC if is_static else MOTION_DYNAMIC)

    def _debug_assert_dynamic_inertia(self, b: Self.B, is_static: Bool):
        """audit E1/E2: a DYNAMIC body with `mass <= 0` or a zero/negative
        principal moment turns into a NaN pose within one integration step
        (`inv_mass()` -> `inf`, or `apply_inv` dividing by zero). Every
        `add*` constructor is a ~100-call-site API (see `SolverConfig
        .validated()`'s docstring for the same trade-off), so this is a
        `debug_assert`, not a `raise`: a caller that wants a raising check
        at ITS OWN boundary can call `Inertia3.validated()` before handing
        the body here. Static/kinematic bodies are exempt -- the solver
        never dereferences their `Inertia3` (`BodySet.is_dynamic`'s gate)."""
        if is_static:
            return
        var inertia = b.get_inertia()
        debug_assert(
            inertia.mass > 0, "ContactScene6.add*: dynamic body mass must be > 0"
        )
        debug_assert(
            inertia.ix > 0 and inertia.iy > 0 and inertia.iz > 0,
            "ContactScene6.add*: dynamic body principal inertia must be > 0",
        )

    def add(mut self, var b: Self.B, half: Vec3, is_static: Bool) -> BodyId:
        self._debug_assert_dynamic_inertia(b, is_static)
        var id = self._push_body(b^, is_static)
        var ci = self.colliders.add(half, id.index())
        debug_assert(
            ci == id.index(), "ContactScene6.add: body/collider index desync"
        )
        return id

    def add_sphere(mut self, var b: Self.B, r: Real, is_static: Bool) -> BodyId:
        self._debug_assert_dynamic_inertia(b, is_static)
        var id = self._push_body(b^, is_static)
        var ci = self.colliders.add_sphere(r, id.index())
        debug_assert(
            ci == id.index(),
            "ContactScene6.add_sphere: body/collider index desync",
        )
        return id

    def add_capsule(
        mut self, var b: Self.B, r: Real, half_len: Real, is_static: Bool
    ) -> BodyId:
        self._debug_assert_dynamic_inertia(b, is_static)
        var id = self._push_body(b^, is_static)
        var ci = self.colliders.add_capsule(r, half_len, id.index())
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
        self._debug_assert_dynamic_inertia(b, is_static)
        var id = self._push_body(b^, is_static)
        var ci = self.colliders.add_hull(verts^, id.index())
        debug_assert(
            ci == id.index(), "ContactScene6.add_hull: body/collider index desync"
        )
        return id

    def add_trimesh(
        mut self, var b: Self.B, verts: List[Real], indices: List[Int]
    ) raises -> BodyId:
        """Static triangle soup. `verts` is flat (x, y, z per vertex) in WORLD
        space, `indices` three per triangle.

        Always static. A mesh has no useful inertia tensor and no closed
        volume, so a dynamic one would be resolved against by contacts that
        cannot conserve anything; refusing it here is cheaper than discovering
        it as drift."""
        var id = self._push_body(b^, True)
        var ci = self.colliders.add_trimesh(verts, indices, id.index())
        debug_assert(
            ci == id.index(),
            "ContactScene6.add_trimesh: body/collider index desync",
        )
        return id

    def add_heightfield(
        mut self, var b: Self.B, heights: List[Real], nx: Int, nz: Int,
        cell: Real, ox: Real = 0, oz: Real = 0,
    ) raises -> BodyId:
        """Static heightfield: the same surface as a mesh, with the triangles
        left implicit and the midphase reduced to arithmetic. Static for the
        same reason as `add_trimesh`."""
        var id = self._push_body(b^, True)
        var ci = self.colliders.add_heightfield(
            heights, nx, nz, cell, ox, oz, id.index()
        )
        debug_assert(
            ci == id.index(),
            "ContactScene6.add_heightfield: body/collider index desync",
        )
        return id

    def deform_heightfield(
        mut self, id: BodyId, cx: Real, cz: Real, radius: Real, delta: Real
    ) raises -> Int:
        """Dig or raise the heightfield `id` around world (cx, cz) --
        ROADMAP 17.30 -- and wake every sleeping body whose box reaches the
        edited disc (a crater under a resting crate must drop it, 17.25)."""
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.deform_heightfield: invalid BodyId")
        var edited = self.colliders.deform_heightfield(id.index(), cx, cz, radius, delta)
        if edited == 0:
            return 0
        for i in range(len(self.bset.bodies)):
            if not self.bset.is_dynamic(i) or not self.bset.sleeping[i]:
                continue
            var p = self.bset.bodies[i].position()
            var hh = self.colliders.half[i]
            var reach = radius + max(hh[0], hh[2])
            var dx = p[0] - cx
            var dz = p[2] - cz
            if dx * dx + dz * dz <= reach * reach:
                wake_island(self.bset, i)
        return edited

    def remove_body(mut self, id: BodyId) raises:
        """ROADMAP 17.0i: full body removal -- the 17.0g-1 deferral
        `physics/body_set.mojo`'s module docstring flagged (`BodySet.remove`/
        `is_valid` existed and were tested, but nothing on `ContactScene6`
        called them). Tombstones the slot (`BodySet.remove`: bumps the
        generation, so a captured `BodyId` reads `is_valid() == False`
        afterwards) and drops every cached warm-start pair referencing it
        (`_quarantine_nonfinite`'s cache-prune has the identical shape) --
        the NEXT `step`'s `_collect_pairs` never re-generates a pair
        touching a removed body (the `is_removed` checks added alongside
        this method), so a stale cache entry would otherwise just sit
        unused; pruning it now is a courtesy, not a correctness requirement.

        Raises if a joint still references `id`: `_joint_sweep`/
        `_warm_start_joints` index `self.bset.bodies` directly with no
        removed-body check of their own (mirroring `add_joint`'s own
        bounds-check -- ARCHITECTURE.md S2, "invalid caller input"), so a
        dangling joint would be a live out-of-bounds-meaning read, not just
        stale data. The caller removes/replaces the joint first.

        `ColliderSet` keeps collider `i`'s shape data in place -- it has no
        free list of its own (unlike `BodySet`), so a reused slot's `add*`
        call OVERWRITES it via the `at` parameter (`ColliderSet.add`'s
        docstring) rather than the two index spaces drifting apart. Until
        that reuse happens, the stale row is simply never read again: every
        candidate-pair loop in `_collect_pairs` now skips `is_removed`
        bodies before touching `self.colliders` at that index."""
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.remove_body: invalid BodyId")
        var i = id.index()
        for c in range(len(self.drives)):
            if self.drives[c].a == i or self.drives[c].b == i:
                raise Error(
                    "ContactScene6.remove_body: body is referenced by a"
                    " drive; remove the drive first"
                )
        for c in range(len(self.joints)):
            if self.joints[c].a == i or self.joints[c].b == i:
                raise Error(
                    "ContactScene6.remove_body: body is referenced by a"
                    " joint; remove the joint first"
                )
        self.bset.remove(id)
        var kept = List[ContactConstraint]()
        for c in range(len(self.cache)):
            if self.cache[c].a != i and self.cache[c].b != i:
                kept.append(self.cache[c])
        self.cache = kept^

    def _check_body_index(self, i: Int, who: String) raises:
        """audit E12: `i` is a raw `Int` (not a `BodyId`) on every `set_*`
        below -- unlike `set_kinematic`/`set_velocity`/etc, which predate
        this and already take `BodyId` (`bset.is_valid`'s generation check).
        Converting these to `BodyId` too would be a signature change on an
        API with call sites across ~10 test/benchmark files for a check that
        doesn't need generation tracking (an out-of-range `i` is exactly as
        wrong as a stale one here), so this only bounds-checks the slot."""
        if i < 0 or i >= len(self.bset.bodies):
            raise Error("ContactScene6." + who + ": body index out of range")

    def set_filter(mut self, i: Int, category: UInt32, mask: UInt32) raises:
        """Which layer body `i` is on, and which layers it collides with."""
        self._check_body_index(i, "set_filter")
        self.colliders.set_filter(i, category, mask)

    def set_sensor(mut self, i: Int, on: Bool) raises:
        """A sensor overlaps but never pushes: it reports contact events and is
        skipped by every solve pass. Trigger volumes are the point."""
        self._check_body_index(i, "set_sensor")
        self.colliders.set_sensor(i, on)

    def set_restitution(mut self, i: Int, e: Real) raises:
        self._check_body_index(i, "set_restitution")
        if e < 0 or e > 1:
            raise Error("ContactScene6.set_restitution: e must be in [0, 1]")
        self.bset.restitution[i] = e

    def set_restitution_combine(mut self, i: Int, mode: Int):
        """ROADMAP 17.23: which formula a pair touching body `i` uses when
        the two bodies' restitution combine modes disagree (`physics
        .material.combine`'s docstring has the PhysX "higher mode wins"
        rule). Default `COMBINE_MAX` reproduces today's hardcoded
        `max(a, b)`."""
        self.bset.restitution_combine[i] = mode

    def set_friction(mut self, i: Int, mu: Real) raises:
        """ROADMAP 17.23: body `i`'s own friction coefficient, replacing the
        step-wide `cfg.default_friction` fallback for every pair touching
        it (`BodySet.eff_friction`). `mu` must be >= 0 -- the sentinel for
        "never set" is negative (`BodySet.friction`'s docstring), so a
        negative call here would silently un-set it; that is caller error,
        not environment failure (docs/ARCHITECTURE.md S2), hence a
        `debug_assert` rather than a `raise` for `mu` specifically. `i` out
        of range (audit E12) does raise -- unlike a bad `mu`, it is not this
        function's own contract, it is an out-of-bounds write waiting to
        happen the next time `i` is read."""
        self._check_body_index(i, "set_friction")
        debug_assert(mu >= 0, "ContactScene6.set_friction: mu must be >= 0")
        self.bset.friction[i] = mu

    def set_friction_combine(mut self, i: Int, mode: Int):
        """Same pair-priority rule as `set_restitution_combine`, for
        friction. Default `COMBINE_AVERAGE` reproduces today's single
        shared `mu` bit-exactly (`physics.material.combine`'s docstring)."""
        self.bset.friction_combine[i] = mode

    def set_kinematic(mut self, id: BodyId) raises:
        """ROADMAP 17.24: promote an already-added body (static or dynamic)
        to KINEMATIC -- infinite mass for impulses, pose still integrated
        every substep from a velocity the caller sets (`set_velocity`/
        `move_to`), never affected by gravity, never merged into a dynamic
        island, never put to sleep. Deliberately NOT a new `add_kinematic`
        constructor: every existing `add*` call site keeps its
        `is_static: Bool` signature unchanged -- a 7-method/~100-call-site
        signature sweep is exactly the compile-cost-cliff risk 17.0g-2 was
        warned to avoid ("land in small steps")."""
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.set_kinematic: invalid BodyId")
        var i = id.index()
        self.bset.motion[i] = MOTION_KINEMATIC
        self.bset.sleeping[i] = False
        self.bset.sleep_timer[i] = 0
        self.bset.island[i] = -1  # recomputed by the next `_refresh_islands`

    def set_velocity(mut self, id: BodyId, v: Vec3, w: Vec3) raises:
        """Directly set body `id`'s linear/angular velocity (world frame) --
        the primitive a constant-speed kinematic platform drives itself
        with (once is enough: nothing else ever changes it again the way
        gravity/impulses would for a dynamic body, so it keeps moving at
        this velocity every substep until called again)."""
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.set_velocity: invalid BodyId")
        self.bset.bodies[id.index()].set_velocity(v, w)

    def move_to(mut self, id: BodyId, pose: Pose6, dt: Real) raises:
        """Compute the velocity that would carry body `id` from its CURRENT
        pose to `pose` over `dt`, and set it (`set_velocity`) -- an
        elevator or door scripted by target pose rather than by velocity.
        Angular velocity uses the small-angle quaternion-derivative
        approximation (`w = 2*Im(q_delta)/dt`, shorter-path corrected) the
        rest of this file already leans on for joint angular error
        (`_joint_sweep`'s hinge `er = cross(oa, ob)`) -- exact for a single
        substep's rotation, and bounded (never NaN/Inf) for any finite
        `pose`/`dt`, including a huge-displacement jump (extreme test)."""
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.move_to: invalid BodyId")
        debug_assert(dt > 0, "ContactScene6.move_to: dt must be > 0")
        var i = id.index()
        var cur_pos = self.bset.bodies[i].position()
        var cur_rot = self.bset.bodies[i].rotation()
        var v = (pose.pos - cur_pos) / dt
        var qd = pose.rot * cur_rot.conjugate()
        if qd.w < 0:
            qd = Quat(-qd.x, -qd.y, -qd.z, -qd.w)  # shorter angular path
        var w = Vec3(qd.x, qd.y, qd.z, 0) * (2 / dt)
        self.bset.bodies[i].set_velocity(v, w)

    def is_sleeping(self, id: BodyId) raises -> Bool:
        """ROADMAP 17.25: e.g. so a character controller (17.2) knows
        whether the platform it's standing on is still simulated or has
        handed off to an idle pose."""
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.is_sleeping: invalid BodyId")
        return self.bset.sleeping[id.index()]

    def wake(mut self, id: BodyId) raises:
        """Manually wake body `id`'s island (ROADMAP 17.25) -- e.g. a
        distant explosion's damage query decides a sleeping stack should
        react NOW rather than at its next contact impulse. Waking a STATIC
        or KINEMATIC id is a no-op (`_wake_island`'s `is_dynamic` gate); an
        invalid/removed id raises (docs/ARCHITECTURE.md S2: invalid caller
        input at the public API)."""
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.wake: invalid BodyId")
        wake_island(self.bset, id.index())

    def set_can_sleep(mut self, id: BodyId, on: Bool) raises:
        """`on=False` keeps body `id`'s whole island awake forever: its own
        `sleep_timer` never advances (`_update_sleep`'s gate), which starves
        the island-wide `all_still` check with no second gate needed there.
        Turning it back off ALSO wakes the body immediately, so a body
        just marked "never sleep" is never left asleep from before this
        call."""
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.set_can_sleep: invalid BodyId")
        var i = id.index()
        self.bset.can_sleep[i] = on
        if not on:
            wake_island(self.bset, i)

    def teleport(mut self, id: BodyId, pose: Pose6) raises:
        """Instantly move body `id` to `pose` (velocity untouched), wake it
        (ROADMAP 17.25's "post-teleport auto-wake"), and drop any warm-start
        cache entries that reference it -- an impulse accumulator anchored
        to the OLD position must never be re-applied at the new one next
        frame (it would inject a spurious impulse at a contact point that
        no longer describes real overlap)."""
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.teleport: invalid BodyId")
        var i = id.index()
        self.bset.bodies[i].set_pose(pose)
        self.bset.sleeping[i] = False
        self.bset.sleep_timer[i] = 0
        wake_island(self.bset, i)
        var kept = List[ContactConstraint]()
        for c in range(len(self.cache)):
            if self.cache[c].a != i and self.cache[c].b != i:
                kept.append(self.cache[c])
        self.cache = kept^

    def _pose(self, i: Int) -> Pose3:
        """The seam value: everything `ColliderSet` needs from body `i`'s
        transform, and nothing else -- collision never sees a `Body6`."""
        return self.bset.pose3(i)


    # ------------------------------------------------ world queries (17.13)
    # Thin wrappers over `collision.world_query`: this is the only place that
    # knows how to turn bodies into the `Pose3`s the collision layer takes.

    def query_poses(self) -> List[Pose3]:
        var out = List[Pose3](capacity=len(self.bset.bodies))
        for i in range(len(self.bset.bodies)):
            out.append(self._pose(i))
        return out^

    def ray_cast(self, origin: Vec3, dir: Vec3, max_t: Real, f: QueryFilter) -> Hit:
        return wq_ray_cast(self.colliders, self.query_poses(), origin, dir, max_t, f)

    def sphere_cast(
        self, c: Vec3, r: Real, dir: Vec3, max_t: Real, f: QueryFilter
    ) -> Hit:
        return wq_sphere_cast(self.colliders, self.query_poses(), c, r, dir, max_t, f)

    def capsule_cast(
        self, a: Vec3, b: Vec3, r: Real, dir: Vec3, max_t: Real, f: QueryFilter
    ) -> Hit:
        return wq_capsule_cast(
            self.colliders, self.query_poses(), a, b, r, dir, max_t, f
        )

    def overlap_sphere(self, c: Vec3, r: Real, f: QueryFilter) -> List[Int]:
        return wq_overlap_sphere(self.colliders, self.query_poses(), c, r, f)

    def capsule_penetrations(
        self, a: Vec3, b: Vec3, r: Real, f: QueryFilter
    ) -> List[Penetration]:
        return wq_capsule_penetrations(self.colliders, self.query_poses(), a, b, r, f)

    def closest_point(self, i: Int, p: Vec3) -> Probe:
        return wq_point_distance(self.colliders, i, self._pose(i), p)

    def _constraint_edges(self, pairs: List[ContactConstraint]) -> List[Int]:
        """The flat `(a, b)` edge list `islands.refresh_islands` takes:
        this step's contacts first, then the joints -- the order the island
        union-find has always merged them in."""
        var edges = List[Int](capacity=2 * (len(pairs) + len(self.joints) + len(self.drives)))
        for c in range(len(pairs)):
            edges.append(pairs[c].a)
            edges.append(pairs[c].b)
        for c in range(len(self.joints)):
            if self.joints[c].kind == JOINT_BROKEN:
                continue
            edges.append(self.joints[c].a)
            edges.append(self.joints[c].b)
        for c in range(len(self.drives)):
            edges.append(self.drives[c].a)
            edges.append(self.drives[c].b)
        return edges^

    def _collect_pairs(
        mut self, warm: Bool, spec_dt: Real, use_bp: Bool = False
    ) -> List[ContactConstraint]:
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
            # `collect_bp_pairs` drops a pair when BOTH entries read `True`
            # here -- passing "is dynamic? no" (rather than literally
            # `is_static`) makes it drop kinematic-static AND
            # kinematic-kinematic pairs too (ROADMAP 17.24: neither produces
            # a contact), with no change needed in `collision.contact_gen`
            # itself, which only ever sees this bool, never a motion type.
            var is_static_bool = List[Bool](capacity=n)
            for i in range(n):
                is_static_bool.append(not self.bset.is_dynamic(i))
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
                # ROADMAP 17.0i: a removed body keeps its stale collider row
                # in place (`ColliderSet` has no free list of its own -- see
                # `remove_body`'s docstring), so it must be excluded here,
                # not just from the `is_dynamic` gate above (a removed body
                # reads `is_dynamic == False`, same as static, so a pair
                # against a still-dynamic neighbor is NOT dropped by
                # `is_static_bool` alone).
                if self.bset.is_removed(i) or self.bset.is_removed(j):
                    continue
                try_pair(
                    self.colliders, i, j, self._pose(i), self._pose(j),
                    self.bset.bodies[i].linear_velocity(),
                    self.bset.bodies[j].linear_velocity(),
                    spec_dt, raws, sraws,
                )
        else:
            for i in range(n):
                for j in range(i + 1, n):
                    # ROADMAP 17.0i: a removed body's collider row is stale
                    # (see the broadphase branch's matching comment above).
                    if self.bset.is_removed(i) or self.bset.is_removed(j):
                        continue
                    # same rule as the broadphase branch above: skip only
                    # when NEITHER side is dynamic (static-static,
                    # static-kinematic, kinematic-kinematic all produce no
                    # contact -- ROADMAP 17.24).
                    if not self.bset.is_dynamic(i) and not self.bset.is_dynamic(j):
                        continue
                    try_pair(
                        self.colliders, i, j, self._pose(i), self._pose(j),
                        self.bset.bodies[i].linear_velocity(),
                        self.bset.bodies[j].linear_velocity(),
                        spec_dt, raws, sraws,
                    )
        self.sensor_pairs = List[ContactConstraint]()  # rebuilt with the solved pairs
        for c in range(len(sraws)):
            self.sensor_pairs.append(make_sensor_contact(sraws[c]))
        var pairs = List[ContactConstraint]()
        var cidx = cache_index(self.cache)
        for c in range(len(raws)):
            pairs.append(make_contact(self.bset, self.cache, cidx, raws[c], warm))
        apply_rules(self.bset, self.rules, pairs)
        return pairs^

    def step(mut self, dt: Real, gravity: Vec3, iters: Int = 8):
        # 1. Gravity on dynamic bodies only (velocity level) -- kinematic
        # bodies (ROADMAP 17.24) are unaffected by gravity, their velocity is
        # entirely caller-set.
        for i in range(len(self.bset.bodies)):
            if self.bset.is_dynamic(i):
                var f = self.bset.gravity_for(i, gravity) / self.bset.bodies[i].inv_mass()  # force = m·g
                self.bset.bodies[i].integrate_force(dt, f, Vec3(0, 0, 0, 0))
        # 2. Contact manifolds at the pre-solve poses.
        var pairs = self._collect_pairs(False, 0)
        # 3. Gauss-Seidel sweeps of accumulated per-point normal impulses.
        for _ in range(iters):
            for c in range(len(pairs)):
                var pr = pairs[c]
                for k in range(pr.m.count):
                    pr.acc[k] = solve_point(
                        self.bset,
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

    def _solve_island(
        mut self,
        mut pairs: List[ContactConstraint],
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
            # gravity: DYNAMIC members of this island only. A kinematic body
            # gets its OWN singleton island (`_refresh_islands`'s docstring),
            # so it reaches this loop too, with `is_dynamic == False` --
            # skipped here, same as it would be in the serial `step` path.
            for i in range(len(self.bset.bodies)):
                if self.bset.island[i] == label and self.bset.is_dynamic(i) and not self.bset.sleeping[i]:
                    var f = self.bset.gravity_for(i, gravity) / self.bset.bodies[i].inv_mass()
                    self.bset.bodies[i].integrate_force(h, f, Vec3(0, 0, 0, 0))
            warm_start_contacts(self.bset, pairs, plo, phi)
            warm_start_joints(self.bset, self.joints, label)
            joint_sweep(
                self.bset, self.joints, h, bias_rate, mass_scale, impulse_scale, True, iters, label
            )
            soft_sweep(
                self.bset, pairs, plo, phi, h, bias_rate, mass_scale,
                impulse_scale, True, iters, mu,
            )
            # pose: dynamic (if awake) OR kinematic -- `not _inactive` is
            # exactly `moves(i) and not sleeping[i]` here since `_inactive`
            # is `is_static or sleeping` and this loop never sees a static
            # body's label (`_refresh_islands` never assigns one).
            for i in range(len(self.bset.bodies)):
                if self.bset.island[i] == label and not self.bset.inactive(i):
                    self.bset.bodies[i].integrate_pose(h)
            joint_sweep(self.bset, self.joints, h, bias_rate, 1, 0, False, 2, label)
            soft_sweep(self.bset, pairs, plo, phi, h, bias_rate, 1, 0, False, 2, mu)
        restitution_pass(self.bset, pairs, plo, phi, 4, rest_threshold)

    def _emit_events(mut self, pairs: List[ContactConstraint]):
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

    def _quarantine_nonfinite(mut self):
        """End-of-step NaN/Inf scan (audit E3/E22-adjacent; the `docs
        /ARCHITECTURE.md` S2 "Numerical failure" row): ONE pass over dynamic
        bodies, run once per `step` call, never per substep/iteration --
        catching a non-finite body an iteration late costs nothing extra
        (it is already quarantined for the REST of this step's substeps and
        every step after), and scanning every substep would multiply the
        cost by `substeps` for no benefit.

        A non-finite body (NaN/Inf position, linear velocity, or angular
        velocity) is quarantined: velocity zeroed, force-slept so it stops
        integrating, and dropped from the warm-start cache so a stale
        accumulated impulse anchored to its last (possibly NaN) contact
        point is never re-applied next step. Its pose is reset to the
        origin/identity rather than "the last finite pose" (docs
        /design/17.0h-error-wiring.md's phrasing allows this: "if kept") --
        keeping a per-body pose history would turn this one pass into two
        (capture, then compare) every step, which is exactly the per-step
        fixed cost `bench_solver_scale`'s NaN-scan-overhead row exists to
        keep small; a reset-to-origin quarantined body is still FINITE and
        inert (force-slept), which is what every other body's broadphase/
        narrowphase queries against it actually need.

        A world must keep stepping (the table's "Propagates?" column for
        this row is "No exception") -- this never raises, only counts
        (`NAN_QUARANTINED`) and logs (WARN, via `self.log`)."""
        for i in range(len(self.bset.bodies)):
            if not self.bset.is_dynamic(i):
                continue
            var pos = self.bset.bodies[i].position()
            var vel = self.bset.bodies[i].linear_velocity()
            var w = self.bset.bodies[i].omega_world()
            if (
                Bool(isfinite(pos).reduce_and())
                and Bool(isfinite(vel).reduce_and())
                and Bool(isfinite(w).reduce_and())
            ):
                continue
            self.bset.bodies[i].set_pose(Pose6(Vec3(0, 0, 0, 0), Quat.identity()))
            self.bset.bodies[i].set_velocity(Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))
            self.bset.sleeping[i] = True
            self.bset.sleep_timer[i] = 0
            self.counters.incr(NAN_QUARANTINED)
            log[Level.WARN](
                self.log, i, "solver",
                "body quarantined: non-finite pose/velocity", Float64(i), 0,
            )
            var kept = List[ContactConstraint]()
            for c in range(len(self.cache)):
                if self.cache[c].a != i and self.cache[c].b != i:
                    kept.append(self.cache[c])
            self.cache = kept^

    def _emit_debug_draw(mut self, pairs: List[ContactConstraint]):
        """Debug-draw (ROADMAP 17.0h; only compiled to a real call site when
        `-D LUDENS_DEBUG_DRAW` is defined -- `step`'s caller is a `comptime
        if DEBUG_DRAW_ON`). One `DrawCommand` per contact POINT (an arrow
        from the point along the contact normal), coloured by the pair's
        island -- so `sc.draw.count()` equals the step's total contact-point
        count exactly (the test this backs asserts that equality on a known
        stack), with island membership encoded as colour rather than as
        separate per-island commands that would break that count."""
        comptime scale = Real(0.15)  # arrow length, world units
        for pc in range(len(pairs)):
            ref pr = pairs[pc]
            var island = contact_island(self.bset, pr)
            # a small deterministic palette keyed by island label, wrapping
            # at 6 -- debug-draw is for a human to look at, not a contract.
            var lbl = island % 6 if island >= 0 else 5
            var color: SIMD[DType.float32, 4]
            if lbl == 0:
                color = SIMD[DType.float32, 4](1, 0, 0, 1)
            elif lbl == 1:
                color = SIMD[DType.float32, 4](0, 1, 0, 1)
            elif lbl == 2:
                color = SIMD[DType.float32, 4](0, 0, 1, 1)
            elif lbl == 3:
                color = SIMD[DType.float32, 4](1, 1, 0, 1)
            elif lbl == 4:
                color = SIMD[DType.float32, 4](0, 1, 1, 1)
            else:
                color = SIMD[DType.float32, 4](1, 1, 1, 1)
            for k in range(pr.m.count):
                var p0 = pr.m.points[k]
                var p1 = p0 + pr.m.normal * scale
                self.draw.arrow(p0, p1, color)

    def _color_pairs(
        mut self,
        mut pairs: List[ContactConstraint],
        mut clo: List[Int],
        mut chi: List[Int],
    ) -> Bool:
        """Greedy smallest-free-colour over the DYNAMIC-body adjacency (a
        shared static must not chain colours, or one ground plane serialises
        the whole scene); `pairs` reordered into contiguous per-colour ranges
        `[clo[c], chi[c])`. <= 64 colours (bit masks): on overflow `pairs` is
        left in its original order, `COLOR_OVERFLOW` counted, and False
        returned (the caller falls back to the uncoloured sweep)."""
        var n_colors = 0
        var mask = List[Int]()
        for _ in range(len(self.bset.bodies)):
            mask.append(0)
        var pcol = List[Int]()
        var overflow = False
        for pc in range(len(pairs)):
            var used = 0
            # DYNAMIC-body adjacency only (was `not is_static`): a
            # kinematic body, like a static one, is never WRITTEN by the
            # colored solve (`_solve_pair`'s impulse application is now
            # `is_dynamic`-gated too), so it must not force a color
            # conflict between two of its dynamic contacts either --
            # ROADMAP 17.24's "kinematic platform pushing N boxes"
            # benchmark would otherwise serialise through one platform
            # the same way a shared static ground plane is documented
            # NOT to below.
            if self.bset.is_dynamic(pairs[pc].a):
                used |= mask[pairs[pc].a]
            if self.bset.is_dynamic(pairs[pc].b):
                used |= mask[pairs[pc].b]
            var col = 0
            # `col < 64` must gate the loop itself, not just be checked
            # after it: found live (this loop used to be unbounded) --
            # once `used` has all 64 bits set (a body already touched by
            # 64 differently-coloured pairs), `used >> col` for `col >=
            # 64` does NOT read as zero the way a mathematical shift
            # would. Mojo's `>>` on `Int` bottoms out at the hardware
            # shift instruction, which masks the shift amount to the
            # register width (`col mod 64` on this target) -- so
            # `used >> 64` re-reads the SAME bits as `used >> 0`, the
            # condition never goes false, and `col` counts up forever.
            # This was a genuine infinite hang, not just "wrong colours
            # past 64" as first filed -- caught by this commit's own
            # extreme test (65 dynamic pairs sharing one body), which
            # hung indefinitely before this bound was added.
            while col < 64 and (used >> col) & 1 == 1:
                col += 1
            if col >= 64:
                # audit E7: a body touched by 64 differently-coloured
                # pairs -- `1 << col` on an `Int` is no longer a single
                # bit past width 63 (wraps/UB), which would corrupt the
                # mask and let two same-colour pairs share a body (a
                # data race under colored+parallel). Bail out of the
                # WHOLE partition rather than continue with a corrupt
                # one: `colored` false below falls through to the
                # existing serial `_soft_sweep(pairs, 0, len(pairs))`
                # path with `pairs` still in its original (uncoloured)
                # order, so this is "fall back to serial", not a crash.
                overflow = True
                break
            pcol.append(col)
            if col + 1 > n_colors:
                n_colors = col + 1
            if self.bset.is_dynamic(pairs[pc].a):
                mask[pairs[pc].a] |= 1 << col
            if self.bset.is_dynamic(pairs[pc].b):
                mask[pairs[pc].b] |= 1 << col
        if overflow:
            self.counters.incr(COLOR_OVERFLOW)
            return False
        else:
            var pairs3 = List[ContactConstraint]()
            for col in range(n_colors):
                clo.append(len(pairs3))
                for pc in range(len(pairs)):
                    if pcol[pc] == col:
                        pairs3.append(pairs[pc])
                chi.append(len(pairs3))
            pairs = pairs3^
        return True

    def _release_overloaded(mut self):
        self.broken_joints = List[Int]()
        if self.any_break:
            check_breaks(
                self.joints, self.break_force, self.break_torque,
                self.peak_force, self.peak_torque, self.broken_joints,
            )

    def begin_external_solve(
        mut self,
        dt: Real,
        cfg: SolverConfig,
        mut clo: List[Int],
        mut chi: List[Int],
    ) -> List[ContactConstraint]:
        """The first half of a colored `step` for a solver that runs the
        substep loop elsewhere (`physics.gpu_contact`, ROADMAP 17.17):
        collect this frame's contacts, refresh islands, colour. On a colour
        overflow `clo`/`chi` come back empty and the pairs uncoloured; a
        colour-parallel solver must then refuse the frame."""
        var pairs = self._collect_pairs(True, dt, cfg.broadphase)
        refresh_islands(self.bset, self._constraint_edges(pairs), len(pairs))
        _ = self._color_pairs(pairs, clo, chi)
        return pairs^

    def end_external_solve(
        mut self, var pairs: List[ContactConstraint], dt: Real, cfg: SolverConfig
    ):
        """The second half: restitution, sleep, NaN quarantine, debug draw,
        events, warm-start cache -- the serial `step`'s tail, unchanged."""
        restitution_pass(self.bset, pairs, 0, len(pairs), 4, cfg.restitution_threshold)
        update_sleep(self.bset, dt, cfg)
        self._quarantine_nonfinite()
        comptime if DEBUG_DRAW_ON:
            self._emit_debug_draw(pairs)
        if self.events_on:
            self._emit_events(pairs)
        self.cache = pairs^

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
        computation per point.

        `step`/`step_soft` stay non-raising (ROADMAP 17.0h / audit E5): with
        ~100 call sites, making either `raises` would force every caller (and
        every caller of those) to become `raises` too. Instead this
        `debug_assert`s the same invariants `SolverConfig.validated()`
        checks -- zero cost in a release build, terminates loudly under
        `-D ASSERT=all` (every test run) if a config or `dt` slipped through
        with a value that would otherwise divide out to `inf`/`NaN` below."""
        debug_assert(cfg.substeps >= 1, "ContactScene6.step: cfg.substeps must be >= 1")
        debug_assert(cfg.iters >= 1, "ContactScene6.step: cfg.iters must be >= 1")
        debug_assert(cfg.hertz > 0, "ContactScene6.step: cfg.hertz must be > 0")
        debug_assert(cfg.zeta >= 0, "ContactScene6.step: cfg.zeta must be >= 0")
        debug_assert(dt > 0, "ContactScene6.step: dt must be > 0")
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
        # "collect_pairs" covers both broadphase candidate enumeration and
        # narrowphase manifold generation -- `_collect_pairs` (collision
        # .contact_gen) does both in one pass, so there is no seam to split
        # a separate "narrowphase" span at without restructuring that
        # function; the spec's phase list treats them as one unit here.
        self.trace.begin("collect_pairs")
        var pairs = self._collect_pairs(True, dt, broadphase)
        self.trace.end()
        refresh_islands(self.bset, self._constraint_edges(pairs), len(pairs))
        # graph coloring (colored=True): greedy smallest-free-color over the
        # DYNAMIC-body adjacency (a shared static must not chain colors, or
        # one ground plane serialises the whole scene); pairs reordered into
        # contiguous per-color ranges. <= 64 colors (bit masks).
        var clo = List[Int]()
        var chi = List[Int]()
        if colored:
            colored = self._color_pairs(pairs, clo, chi)
        if parallel and (colored or len(self.softs) > 0 or ccd or len(self.drives) > 0 or self.any_break):
            # F23: the island-parallel path assumes no soft bodies, no ccd
            # and no colored solving; falling back is correct but used to be
            # silent -- count it so a caller relying on the parallel path
            # can notice it never actually ran in parallel.
            self.counters.incr(PARALLEL_FALLBACK_SERIAL)
        if parallel and not colored and len(self.softs) == 0 and not ccd and len(self.drives) == 0 and not self.any_break:
            # partition: pairs reordered so each island is a contiguous range
            var labels = island_labels(self.bset)
            var pairs2 = List[ContactConstraint]()
            var plo = List[Int]()
            var phi = List[Int]()
            for k in range(len(labels)):
                plo.append(len(pairs2))
                for pc in range(len(pairs)):
                    if contact_island(self.bset, pairs[pc]) == labels[k]:
                        pairs2.append(pairs[pc])
                phi.append(len(pairs2))

            self.trace.begin("solve")
            _solve_islands_parallel(
                self, pairs2, plo, phi, labels, gravity, h,
                substeps, iters, bias_rate, mass_scale, impulse_scale, mu,
                workers, cfg.restitution_threshold,
            )
            self.trace.end()
            self.trace.begin("sleep")
            update_sleep(self.bset, dt, cfg)
            self.trace.end()
            self.trace.begin("nan_scan")
            self._quarantine_nonfinite()
            self.trace.end()
            comptime if DEBUG_DRAW_ON:
                self._emit_debug_draw(pairs2)
            if self.events_on:
                self._emit_events(pairs2)
            self._release_overloaded()
            self.cache = pairs2^
            return
        # ROADMAP 17.0i: ONE "solve" span for the WHOLE substep loop, not one
        # begin/end pair per phase per substep. Measured overhead was ~20% at
        # N=512 (bench_solver_scale table 4) from ~23 span pairs/step (5
        # phases -- warm_start/solve/integrate-or-ccd/soft_pass/relax-solve
        # -- times the default 4 substeps, plus collect_pairs/sleep/
        # nan_scan); `TraceBuffer.begin`/`end` each pay a `perf_counter_ns`
        # call, a `List` push/pop, and a `String` copy of the span name even
        # though `-D LUDENS_TRACE` compiles the CALL away when off (the cost
        # measured is the traced-build cost) -- coarsening to one span per
        # phase per STEP amortizes that fixed cost over the whole step
        # instead of over each substep, without losing what a caller can
        # still ask `sc.trace.stats()` for (`test_error_wiring.mojo` and
        # `bench_solver_scale`'s table 4 only ever check for "solve",
        # "collect_pairs", "sleep", "nan_scan" by name -- never
        # "warm_start"/"integrate"/"soft_pass", which were never part of
        # either's contract). The five phases below stay in their original
        # per-substep INTERLEAVED order (warm start -> solve -> integrate ->
        # soft pass -> relax, repeated `substeps` times) -- only the tracing
        # granularity changes, not the algorithm.
        self.trace.begin("solve")
        for _ in range(substeps):
            # gravity: dynamic + awake only. `not _inactive(i)` alone would
            # also admit a kinematic body (never static, never sleeping) --
            # ROADMAP 17.24 says gravity must NOT reach it, so this gate is
            # tighter than the pose-integration one just below.
            for i in range(len(self.bset.bodies)):
                if self.bset.is_dynamic(i) and not self.bset.sleeping[i]:
                    var f = self.bset.gravity_for(i, gravity) / self.bset.bodies[i].inv_mass()
                    self.bset.bodies[i].integrate_force(h, f, Vec3(0, 0, 0, 0))
            # Warm start: re-apply accumulated impulses; the soft solve's
            # -impulseScale·acc decay is the matching counter-term.
            warm_start_contacts(self.bset, pairs, 0, len(pairs))
            warm_start_joints(self.bset, self.joints, -2)
            if len(self.drives) > 0:
                warm_start_drives(self.bset, self.drives)
            joint_sweep(
                self.bset, self.joints, h, bias_rate, mass_scale, impulse_scale, True, iters, -2
            )
            if len(self.drives) > 0:
                drive_sweep(self.bset, self.drives, h, iters)
            if colored:
                sweep_colored(
                    self.bset, pairs, clo, chi, h, bias_rate, mass_scale,
                    impulse_scale, True, iters, mu, parallel, workers,
                )
            else:
                soft_sweep(
                self.bset, pairs, 0, len(pairs), h, bias_rate, mass_scale,
                    impulse_scale, True, iters, mu,
                )
            if ccd:
                ccd_advance(self.bset, self.colliders, h)
            else:
                for i in range(len(self.bset.bodies)):
                    if not self.bset.inactive(i):
                        self.bset.bodies[i].integrate_pose(h)
            # soft bodies: XPBD lattice + particle-vs-body coupling, at the
            # substep's POST-integration poses (rigid impulses land next substep)
            softbody_pass(self.softs, self.bset, self.colliders, h, gravity, iters, ccd)
            # relax: remove the bias energy (velocity-only, no bias)
            joint_sweep(self.bset, self.joints, h, bias_rate, 1, 0, False, 2, -2)
            if colored:
                sweep_colored(
                    self.bset, pairs, clo, chi, h, bias_rate, 1, 0, False, 2, mu,
                    parallel, workers,
                )
            else:
                soft_sweep(
                self.bset, pairs, 0, len(pairs), h, bias_rate, 1, 0, False, 2, mu
                )
            if self.any_break:
                sample_loads(self.joints, h, self.peak_force, self.peak_torque)
        self.trace.end()
        restitution_pass(self.bset, pairs, 0, len(pairs), 4, cfg.restitution_threshold)
        self.trace.begin("sleep")
        update_sleep(self.bset, dt, cfg)
        self.trace.end()
        self.trace.begin("nan_scan")
        self._quarantine_nonfinite()
        self.trace.end()
        comptime if DEBUG_DRAW_ON:
            self._emit_debug_draw(pairs)
        if self.events_on:
            self._emit_events(pairs)
        self._release_overloaded()
        self.cache = pairs^  # impulses persist to the next frame


def _solve_islands_parallel[BB: Body6, PBP: BroadPhase](
    mut scene: ContactScene6[BB, PBP],
    mut pairs2: List[ContactConstraint],
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
        # ROADMAP 17.0g-2 additions (17.23 materials, 17.24 kinematic, 17.25
        # can-sleep): appended here, AFTER the pre-existing `is_static` bit
        # above rather than replacing it, so a pre-17.0g-2 field's ENCODED
        # VALUE for every existing body is untouched -- only the blob grows
        # (the identity gate's explicitly allowed exception). `motion` is
        # the field `read_state` actually reconstructs from now on (the old
        # `is_static` bit alone cannot distinguish DYNAMIC from KINEMATIC);
        # it is kept in the stream for its position's own stability, not
        # read back.
        out.wi(sc.bset.motion[i])
        out.wf(sc.bset.friction[i])
        out.wi(sc.bset.friction_combine[i])
        out.wi(sc.bset.restitution_combine[i])
        out.wi(1 if sc.bset.can_sleep[i] else 0)
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
        # Pre-17.0g-2 `is_static` bit: still written (`write_state`), kept
        # here only for the token stream's position -- superseded by the
        # authoritative `motion` field read below, which is what
        # distinguishes KINEMATIC from DYNAMIC (a single bit cannot).
        # Discarded to `_` rather than bound, per the unused-binding lint
        # (mojo_1.1_migration.md Gotcha #5).
        _ = r.ri()
        var kind = r.ri()
        var restitution = r.rf()
        var sleeping = r.ri() == 1
        var sleep_timer = r.rf()
        var category = UInt32(r.ri())
        var mask = UInt32(r.ri())
        var sensor = r.ri() == 1
        # ROADMAP 17.0g-2 additions (`write_state`'s docstring has the exact
        # field order/rationale).
        var motion = r.ri()
        if motion < MOTION_STATIC or motion > MOTION_KINEMATIC:
            raise Error(
                "physics.serialize: corrupt snapshot (invalid motion type)"
            )
        var friction = r.rf()
        var friction_combine = r.ri()
        var restitution_combine = r.ri()
        var can_sleep = r.ri() == 1
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
        sc.bset.friction[bi] = friction
        sc.bset.friction_combine[bi] = friction_combine
        sc.bset.restitution_combine[bi] = restitution_combine
        sc.bset.can_sleep[bi] = can_sleep
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
        # break thresholds are not in the snapshot format (yet): a restored
        # joint is unbreakable until `set_joint_break` is called again
        sc.break_force.append(Real.MAX)
        sc.break_torque.append(Real.MAX)
        sc.peak_force.append(0)
        sc.peak_torque.append(0)
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
        var pr = ContactConstraint(
            a, b, feat, m,
            Array[Real, 4](fill=0), Array[Real, 4](fill=0),
            Array[Real, 4](fill=0),
            Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
            Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
            Array[Real, 4](fill=0), Array[Real, 4](fill=0),
            Vec3(0, 0, 0, 0), Real(-1),
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
