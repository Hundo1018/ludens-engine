"""Body identity (audit finding F5): `BodyId`, `MotionType`, and `BodySet`.

Before this, a body was a raw `Int` index into 6 parallel `List`s living
directly on `ContactScene6` (`bodies`, `statics`, `sleeping`, `sleep_timer`,
`island`, `restitution` -- the other 7 of the original 13 moved to
`collision/collider_set.mojo` in 17.0e). Nothing stopped a new per-body list
from being appended in one call site and forgotten in another --
`physics/serialize.mojo` used to re-implement registration by appending to
each list by hand, which is exactly that failure mode. `BodySet.push` is the
ONE append site every per-body attribute grows through, so a forgotten list
is a compile error (a missing field access), not a silent misalignment.

`BodyId` (slot + generation) is a stable handle: gameplay code (character
controller ground/platform refs, interpolation buffers, kinematic platform
handles -- ROADMAP 17.1/17.7/17.24) can hold one across frames. A `remove`
bumps the slot's generation, so a `BodyId` captured before the remove reads
as invalid (`is_valid`) afterwards instead of silently aliasing whatever
`push` later reuses that slot for -- the same stale-handle contract
`ecs.entity.Entity`/`ecs.world.World` already use (audit F14's precedent).

`ContactScene6` does not yet expose body removal through its own `add*`/
`step_soft` API in this commit (17.0g-1 is a behaviour-preserving refactor:
every existing `add*` call still just appends, so `collision.collider_set
.ColliderSet`'s "collider `i` == body `i`" index invariant, which has no
matching `remove`, is never put at risk). `BodySet.remove`/`is_valid` are
still fully implemented and tested here, ready for the gameplay layer (or a
future `ContactScene6.remove_body`, once `ColliderSet` grows a matching
removal path) to build on.
"""

from geometry.vec import Real, Vec3
from collision.manifold import Axes3
from collision.collider_set import Pose3
from .rigid6 import Body6
from .material import COMBINE_AVERAGE, COMBINE_MAX

# Motion type (replaces `statics: List[Bool]`, 54 references before this
# commit). The values below are stable ABI for `physics/serialize.mojo`'s
# on-disk format -- appended, never inserted, never renumbered.
comptime MOTION_STATIC = 0
comptime MOTION_DYNAMIC = 1
comptime MOTION_REMOVED = 2
"""A tombstoned slot: `BodySet.remove` sets this so the body is not
integrated, not collided, and not placed in an island -- the removal
equivalent of "static", but also excluded from `is_valid`."""
comptime MOTION_KINEMATIC = 3
"""ROADMAP 17.24: infinite mass for impulses (never receives one, never
gets gravity), but its pose still integrates every substep from a velocity
the CALLER sets (`ContactScene6.set_velocity`/`move_to`) rather than one
the solver derives -- an elevator or moving platform. Appended after
`MOTION_REMOVED` (17.0g-1's stable-ABI promise): a saved-before-this-commit
snapshot's `MOTION_STATIC`/`MOTION_DYNAMIC`/`MOTION_REMOVED` values are
untouched."""


@fieldwise_init
struct BodyId(Copyable, ImplicitlyCopyable, Movable, Equatable, Writable):
    """A stable handle into a `BodySet`: the slot plus the generation the
    slot had when this id was issued. `index()` gives the raw slot for
    callers that still need a plain `Int` (e.g. `ColliderSet`, whose index
    space is defined to track body slots 1:1 -- see `collision/collider_set
    .mojo`'s docstring)."""

    var slot: Int
    var gen: UInt32

    def index(self) -> Int:
        return self.slot

    def __eq__(self, other: Self) -> Bool:
        return self.slot == other.slot and self.gen == other.gen

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

    def write_to[W: Writer](self, mut w: W):
        w.write("BodyId(", self.slot, ",", self.gen, ")")


struct BodySet[B: Body6](Movable, Deinitable, Sized):
    """Per-body SoA: `bodies`, `motion` (`MOTION_STATIC`/`MOTION_DYNAMIC`/
    `MOTION_REMOVED`), `sleeping`, `sleep_timer`, `island`, `restitution`,
    plus the generation counter and free list backing `BodyId`.

    Dense index == slot: `remove` tombstones and frees the slot for the next
    `push` to reuse, rather than compacting the lists. Compaction would
    renumber every OTHER body's index on every removal, which is exactly the
    instability `BodyId` exists to avoid for every per-body side table keyed
    by slot (today `ColliderSet`; more arrive with gameplay code), so it
    isn't done here -- a `BodySet` grows without bound only in slot count,
    not in the lists' live length, since removed slots are reused."""

    var bodies: List[Self.B]
    var motion: List[Int]
    var sleeping: List[Bool]
    var sleep_timer: List[Real]
    var island: List[Int]  # island label per body (last step; -1 = static)
    var restitution: List[Real]  # per-body coefficient (default combine: max)
    var can_sleep: List[Bool]  # ROADMAP 17.25: false = never auto-sleeps
    # ROADMAP 17.23 per-body materials. `friction < 0` is the "unset" sentinel
    # (never negative once explicitly set -- `eff_friction` substitutes the
    # step's `cfg.default_friction` for it), so a body that never calls
    # `set_friction` behaves EXACTLY like today's single shared `mu`, not
    # like an explicit friction of 0.
    var friction: List[Real]
    var friction_combine: List[Int]
    var restitution_combine: List[Int]
    var generation: List[UInt32]
    # ROADMAP 17.27: a per-body gravity replacing the step's global one
    # (gravity zones). `grav_on` false = use the global gravity; the solver
    # only looks at `grav` when `any_grav` is set, so scenes without zones
    # take exactly the old path.
    var grav_on: List[Bool]
    var grav: List[Vec3]
    var any_grav: Bool
    # ROADMAP 17.31: a frozen body is temporarily MOTION_STATIC; this keeps
    # the motion type it had (-1 = not frozen). Its velocity fields are
    # untouched while frozen, so unfreezing resumes exactly where it was.
    var frozen_motion: List[Int]
    var free: List[Int]

    def __init__(out self):
        self.bodies = List[Self.B]()
        self.motion = List[Int]()
        self.sleeping = List[Bool]()
        self.sleep_timer = List[Real]()
        self.island = List[Int]()
        self.restitution = List[Real]()
        self.can_sleep = List[Bool]()
        self.friction = List[Real]()
        self.friction_combine = List[Int]()
        self.restitution_combine = List[Int]()
        self.generation = List[UInt32]()
        self.grav_on = List[Bool]()
        self.grav = List[Vec3]()
        self.any_grav = False
        self.frozen_motion = List[Int]()
        self.free = List[Int]()

    def __len__(self) -> Int:
        return len(self.bodies)

    def _take_free_slot(mut self) -> Int:
        """Pop the LOWEST free slot (not just any -- deterministic reuse
        order, so slot-reuse tests aren't flaky and a saved scene's body
        indices don't depend on removal order)."""
        var best = 0
        for i in range(1, len(self.free)):
            if self.free[i] < self.free[best]:
                best = i
        var slot = self.free[best]
        var last = len(self.free) - 1
        self.free[best] = self.free[last]
        _ = self.free.pop()
        return slot

    def push(mut self, var b: Self.B, motion: Int) -> BodyId:
        """The ONE append site: every per-body list grows here, in lockstep,
        so a per-body attribute added later cannot be forgotten by a call
        site the way `physics/serialize.mojo` used to be able to (F5)."""
        if len(self.free) > 0:
            var slot = self._take_free_slot()
            self.bodies[slot] = b^
            self.motion[slot] = motion
            self.sleeping[slot] = False
            self.sleep_timer[slot] = 0
            self.island[slot] = -1
            self.restitution[slot] = 0
            self.can_sleep[slot] = True
            self.friction[slot] = -1
            self.friction_combine[slot] = COMBINE_AVERAGE
            self.restitution_combine[slot] = COMBINE_MAX
            self.grav_on[slot] = False
            self.grav[slot] = Vec3(0, 0, 0, 0)
            self.frozen_motion[slot] = -1
            return BodyId(slot, self.generation[slot])
        var slot = len(self.bodies)
        self.bodies.append(b^)
        self.motion.append(motion)
        self.sleeping.append(False)
        self.sleep_timer.append(0)
        self.island.append(-1)
        self.restitution.append(0)
        self.can_sleep.append(True)
        self.friction.append(-1)
        self.friction_combine.append(COMBINE_AVERAGE)
        self.restitution_combine.append(COMBINE_MAX)
        self.grav_on.append(False)
        self.grav.append(Vec3(0, 0, 0, 0))
        self.frozen_motion.append(-1)
        self.generation.append(0)
        return BodyId(slot, 0)

    def remove(mut self, id: BodyId):
        """Tombstone the slot (`MOTION_REMOVED`) and bump its generation, so
        a `BodyId` captured before this call reads `is_valid() == False`
        afterwards instead of silently aliasing whatever `push` later
        reuses the slot for. A stale `id` is a programmer error (the caller
        held a handle past its body's lifetime), so it terminates loudly
        under `-D ASSERT=all` rather than corrupting a live body's state
        (docs/ARCHITECTURE.md S2)."""
        debug_assert(self.is_valid(id), "BodySet.remove: stale BodyId")
        var slot = id.slot
        self.motion[slot] = MOTION_REMOVED
        self.sleeping[slot] = False
        self.sleep_timer[slot] = 0
        self.island[slot] = -1
        self.generation[slot] += 1
        self.free.append(slot)

    def is_valid(self, id: BodyId) -> Bool:
        """False for an out-of-range slot, a stale generation, or a
        tombstoned (already-removed) slot -- the one check gameplay code
        should run before trusting a `BodyId` it has held across frames."""
        if id.slot < 0 or id.slot >= len(self.generation):
            return False
        if self.generation[id.slot] != id.gen:
            return False
        return self.motion[id.slot] != MOTION_REMOVED

    def is_static(self, i: Int) -> Bool:
        return self.motion[i] == MOTION_STATIC

    def is_dynamic(self, i: Int) -> Bool:
        """True only for `MOTION_DYNAMIC` -- the gate for everything that
        needs a FINITE mass: gravity, receiving an impulse, contributing an
        inverse-mass term to a Gauss-Seidel denominator, joining a dynamic
        island. `MOTION_KINEMATIC` (infinite mass, ROADMAP 17.24) reads
        `False` here even though it moves -- see `moves`."""
        return self.motion[i] == MOTION_DYNAMIC

    def is_kinematic(self, i: Int) -> Bool:
        return self.motion[i] == MOTION_KINEMATIC

    def is_removed(self, i: Int) -> Bool:
        return self.motion[i] == MOTION_REMOVED

    def moves(self, i: Int) -> Bool:
        """True for `MOTION_DYNAMIC` OR `MOTION_KINEMATIC` -- the gate for
        everything that needs the body's CURRENT velocity/pose read (contact
        relative-velocity, `velocity_at`, pose integration) regardless of
        whether it has finite mass. A kinematic body reads `True` here (its
        velocity carries into contacts, its pose advances every substep) and
        `False` from `is_dynamic` (it never receives the impulse response)
        -- that split is the whole of 17.24's solver-side behaviour."""
        return self.motion[i] == MOTION_DYNAMIC or self.motion[i] == MOTION_KINEMATIC

    def eff_friction(self, i: Int, default_mu: Real) -> Real:
        """Body `i`'s friction coefficient, or `default_mu` (the step's
        `cfg.default_friction`) if it never called `set_friction` -- the
        substitution that makes the unset case bit-identical to today's
        single shared `mu` (`combine`'s docstring has the exact identity)."""
        return self.friction[i] if self.friction[i] >= 0 else default_mu

    def id_of(self, i: Int) -> BodyId:
        """The current `BodyId` for live slot `i` -- for a caller that only
        has the raw index (e.g. a loop over `range(len(bset))`) and wants a
        handle it can hold past this step."""
        return BodyId(i, self.generation[i])

    # -- solver-facing predicates and the collision seam value (F11 split) --
    # These used to be private methods on `ContactScene6`; the constraint
    # modules (`contact6`, `joints6`, `islands`, `ccd6`, `soft_couple`) are
    # free functions over a `BodySet`, so the predicates live with the data.

    def inactive(self, i: Int) -> Bool:
        """Does this body need its VELOCITY/POSE handled? Static bodies never
        move, sleeping bodies are frozen. A kinematic body reads `False` here
        even at zero velocity -- its pose integrates on the same `not
        inactive(i)` gate a dynamic body's does. A removed body (17.0i) reads
        `True`: `remove` clears `sleeping`, and without this the pose loop
        would keep advancing a despawned body along its last velocity."""
        return self.is_static(i) or self.is_removed(i) or self.sleeping[i]

    def impulse_inert(self, i: Int) -> Bool:
        """Does body `i` never receive an impulse this step -- static,
        kinematic (17.24: infinite mass), or a still-sleeping dynamic body.
        Differs from `inactive` only for kinematic, so `impulse_inert(a) and
        impulse_inert(b)` is the right "skip this pair entirely" test even
        with a kinematic side: a stationary kinematic next to a sleeping
        dynamic body must behave exactly like a static one (the 17.24 parity
        test). For dynamic or static bodies it equals `inactive`."""
        return not self.is_dynamic(i) or self.sleeping[i]

    def axes(self, i: Int) -> Axes3:
        """World-frame box axes of body `i` (via `act`, representation-free)."""
        var o = self.bodies[i].act(Vec3(0, 0, 0, 0))
        var out = Array[Vec3, 3](fill=Vec3(0, 0, 0, 0))
        out[0] = self.bodies[i].act(Vec3(1, 0, 0, 0)) - o
        out[1] = self.bodies[i].act(Vec3(0, 1, 0, 0)) - o
        out[2] = self.bodies[i].act(Vec3(0, 0, 1, 0)) - o
        return out^

    def pose3(self, i: Int) -> Pose3:
        """The seam value: everything `ColliderSet` needs from body `i`'s
        transform, and nothing else -- collision never sees a `Body6`."""
        return Pose3(self.bodies[i].position(), self.axes(i))

    def gravity_for(self, i: Int, g: Vec3) -> Vec3:
        """The gravity body `i` feels: its override, or the step's `g`."""
        if self.any_grav and self.grav_on[i]:
            return self.grav[i]
        return g
