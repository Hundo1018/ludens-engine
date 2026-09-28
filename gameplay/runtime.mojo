"""ROADMAP 17.0i: the runtime that owns a world.

Audit F15: nothing owned stateful runtime. A physics scene was neither a
system nor a component, nothing synced `ContactScene6` poses into ECS
transforms, and `scheduler.scheduler.System.apply[B](mut world)` is
stateless -- it cannot capture a `ContactScene6`, a gravity vector, or a
`SolverConfig` the way a real per-frame driver needs to. `Runtime[B, Body]`
is that missing home: it owns an ECS `World[B]`, a physics `ContactScene6
[Body]`, the fixed-step accumulator (`scheduler.gameloop.FixedLoop`'s
fields, driven inline rather than through `FixedLoop.advance[S: Scheduler]`
-- see `advance`'s docstring for why), a contact-event channel
(`scheduler.events.Channel`), and a tick-based timer queue
(`scheduler.timers.TimerHeap`). 17.1 (character controller), 17.7
(interpolation) and every later gameplay feature build on top of this.

`gameplay` is layer 5 (`docs/ARCHITECTURE.md` S1, `scripts/arch_layers.toml`):
it may import every lower package (physics, collision, ecs, scheduler,
diag, geometry, ...) and nothing may import IT (the arch check enforces this
-- a `Runtime` is the top of the engine-package stack, one hop below
tests/benchmarks/examples).

WIRING PER FIXED TICK (`advance`): `timers.advance(1, ...)` first (so a
timer scheduled to fire "this tick" is visible to code that reacts to it
before the physics step runs), then `scene.step(dt, gravity, cfg)`, then
`scene.events` (this step's contact began/stay/ended, rebuilt fresh every
step since `scene.events_on` is turned on by `Runtime.__init__`) is
forwarded onto `events` (`scheduler.events.Channel`, the SAME adapter shape
`tests/test_events_contacts.mojo`'s `publish_contact_events` already
proved against a real `ContactScene6` stack -- this is that adapter's
production-code home the test file's own docstring said would exist once
`gameplay` did), then `events.update()` ages the double buffer one tick (so
"two update() calls" tracks fixed ticks, the runtime's natural per-tick
unit, matching that test's own per-step `ch.update()` call), then poses
sync into ECS transforms (`_sync_transforms`, one `for_each2` pass: reads
`BodySet`, writes `ecs.transform.Transform` -- no `List[Entity]`
allocation, the same zero-allocation path every other ECS system in this
engine uses)."""

from ecs.world import World
from ecs.storage import StorageBackend
from ecs.component import ComponentType
from ecs.entity import Entity
from ecs.transform import Transform
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import Body6
from physics.body_set import BodyId
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from scheduler.gameloop import FixedLoop
from scheduler.events import Channel
from scheduler.timers import TimerHeap, TimerFire
from collision.contact_events import ContactEvent
from diag.counters import GAMELOOP_DEBT_DROPPED


@fieldwise_init
struct RigidBodyRef(ComponentType):
    """Links an entity to a scene body. `id` is a stable `BodyId` (slot +
    generation, `physics.body_set`): after `Runtime.despawn`, the id this
    component held reads `is_valid() == False` on `scene.bset` -- the same
    stale-handle contract `ecs.entity.Entity` already gives every other
    component."""

    comptime ID: Int = 2  # after ecs.transform's Transform=0 / Parent=1
    var id: BodyId


struct Runtime[B: StorageBackend, Body: Body6](Movable, Deinitable):
    """Owns a world, a physics scene, and the fixed-step loop between them.

    Generic over the ECS storage backend (`B`, same swap-seam every other
    `World[B]` caller uses) and the `Body6` representation (`Body` --
    `QuatBody6` or `ScrewBody6`, ROADMAP 17.0h's parity pair); `B`'s
    component set must include `RigidBodyRef` and `ecs.transform.Transform`
    for `spawn_body`/`_sync_transforms` to compile against it."""

    var world: World[Self.B]
    var scene: ContactScene6[Self.Body]
    var loop: FixedLoop
    var cfg: SolverConfig
    var gravity: Vec3
    var events: Channel[ContactEvent]
    var timers: TimerHeap

    def __init__(out self, dt: Real, gravity: Vec3, max_steps: Int = 8):
        self.world = World[Self.B]()
        self.scene = ContactScene6[Self.Body]()
        # Contact events are off by default on a bare `ContactScene6` (the
        # diff sorts the contact set every step, real work a scene that
        # never reads it shouldn't pay for -- `solver6.mojo`'s field
        # docstring) but a `Runtime` exists specifically to publish them
        # onto `events`, so it always wants them on.
        self.scene.events_on = True
        self.loop = FixedLoop.new(Float64(dt), max_steps)
        self.cfg = SolverConfig()
        self.gravity = gravity
        self.events = Channel[ContactEvent]()
        self.timers = TimerHeap()

    # ------------------------------------------------------------ lifecycle

    def spawn_body(mut self, var b: Self.Body, half: Vec3, is_static: Bool) -> Entity:
        """Add a box body to the scene AND an entity carrying `RigidBodyRef`
        + `Transform` (initialized to the body's own pose) -- one call, the
        design note's requirement that a gameplay caller never has a scene
        body without a matching entity or vice versa."""
        var id = self.scene.add(b^, half, is_static)
        return self._spawn_entity(id)

    def spawn_sphere(mut self, var b: Self.Body, r: Real, is_static: Bool) -> Entity:
        """Same as `spawn_body`, for a sphere collider (`ContactScene6
        .add_sphere`)."""
        var id = self.scene.add_sphere(b^, r, is_static)
        return self._spawn_entity(id)

    def _spawn_entity(mut self, id: BodyId) -> Entity:
        var e = self.world.spawn()
        self.world.set(e, RigidBodyRef(id))
        var i = id.index()
        var t = Transform.at(self.scene.bset.bodies[i].position())
        t = t.with_rotation(self.scene.bset.bodies[i].rotation())
        self.world.set(e, t)
        return e

    def despawn(mut self, e: Entity) raises:
        """Remove both halves: the scene body (`ContactScene6.remove_body`,
        ROADMAP 17.0i -- tombstones the `BodySet` slot, drops it from the
        warm-start cache, raises if a joint still references it) and the
        entity (`World.despawn`). A `RigidBodyRef`-less entity (never
        spawned through `spawn_body`/`spawn_sphere`) just despawns from the
        world -- not every entity a gameplay `World` holds need be a rigid
        body."""
        if self.world.has[RigidBodyRef](e):
            var r = self.world.get[RigidBodyRef](e)
            if self.scene.bset.is_valid(r.id):
                self.scene.remove_body(r.id)
        self.world.despawn(e)

    # --------------------------------------------------------------- update

    def advance(mut self, frame_dt: Float64) raises -> Float64:
        """Accumulate `frame_dt`, run as many fixed ticks as owed (capped by
        `loop.max_steps`), return the leftover `alpha` in `[0, 1)` for
        render-time interpolation (ROADMAP 17.7).

        Deliberately does NOT call `FixedLoop.advance[S: Scheduler](...)`:
        that method drives a `scheduler.scheduler.Scheduler` over a SINGLE
        `World[S.B]`, with no way for a registered `System.apply[B](mut
        world)` (a stateless, backend-generic static method) to also reach a
        `ContactScene6`, a gravity vector, and a `SolverConfig` -- exactly
        the gap this whole design note exists to close (module docstring).
        This method instead runs `FixedLoop`'s own accumulate/clamp/alpha
        algorithm inline against `self.loop`'s fields, substituting "tick
        the scene, publish events, sync poses" for "tick the scheduler" --
        same contract (`GAMELOOP_DEBT_DROPPED` counted on the same clamp,
        `alpha` in the same range), different per-tick body."""
        debug_assert(self.loop.dt > 0, "Runtime.advance: loop.dt must be > 0")
        self.loop.accumulator += frame_dt
        # Age the event double buffer once per FRAME, not per fixed tick: a
        # frame that runs several ticks must still deliver the first tick's
        # events to readers that read once per frame.
        self.events.update()
        var steps = 0
        while self.loop.accumulator >= self.loop.dt and steps < self.loop.max_steps:
            var fired = List[TimerFire]()
            self.timers.advance(1, fired)
            self.scene.step(Real(self.loop.dt), self.gravity, self.cfg)
            for i in range(len(self.scene.events)):
                self.events.send(self.scene.events[i].copy())
            self._sync_transforms()
            self.loop.accumulator -= self.loop.dt
            steps += 1
        if self.loop.accumulator >= self.loop.dt:
            # audit E22/F16's drop, replicated (FixedLoop.advance's own
            # docstring has the full reasoning): a frame-rate spike clamped
            # by `max_steps` with time still owed drops the excess rather
            # than carrying it, so `alpha` stays in [0, 1) instead of
            # drifting unbounded.
            self.loop.counters.incr(GAMELOOP_DEBT_DROPPED)
            self.loop.accumulator = 0
        self.loop.alpha = self.loop.accumulator / self.loop.dt
        return self.loop.alpha

    def _sync_transforms(mut self):
        """One system: reads `BodySet` (through `scene.bset`), writes
        `ecs.transform.Transform` for every entity carrying both it and
        `RigidBodyRef` -- the zero-allocation `World.for_each2` path (no
        `List[Entity]`), same as every other per-frame ECS pass in this
        engine.

        `for_each2`'s closure cannot borrow `self.scene.bset` directly while
        `self.world.for_each2` also borrows `self.world` mutably (both
        derive from the same `mut self` receiver, so the compiler rejects it
        as aliasing even though the two fields are disjoint) -- so the pose
        data this tick needs (position, rotation, and enough of `BodySet
        .is_valid`'s check to skip a stale `RigidBodyRef`: the slot's own
        current generation, and whether it is live at all) is copied into
        three plain `List`s first, and the closure captures THOSE instead.
        Cost is O(bodies) positions/rotations copied once per tick, already
        paid for by `write_state`-style snapshots elsewhere in this engine."""
        var n = len(self.scene.bset.bodies)
        var pos = List[Vec3](capacity=n)
        var rot = List[Quat](capacity=n)
        var live = List[Bool](capacity=n)
        var gens = List[UInt32](capacity=n)
        for i in range(n):
            pos.append(self.scene.bset.bodies[i].position())
            rot.append(self.scene.bset.bodies[i].rotation())
            live.append(not self.scene.bset.is_removed(i))
            gens.append(self.scene.bset.generation[i])

        def sync_pose(mut t: Transform, r: RigidBodyRef) {imm pos, imm rot, imm live, imm gens}:
            var i = r.id.index()
            if i < 0 or i >= len(live) or gens[i] != r.id.gen or not live[i]:
                return  # stale RigidBodyRef (despawned/out of range): leave the transform alone
            t.translation = pos[i]
            t.rotation = rot[i]
            t.local_dirty = True
            t.world_dirty = True

        self.world.for_each2[Transform, RigidBodyRef](sync_pose)
