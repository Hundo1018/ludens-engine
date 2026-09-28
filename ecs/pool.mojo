"""Entity pools (ROADMAP 17.37): reuse pre-built entities instead of paying
full spawn/despawn + archetype migration on every churn cycle.

## The shape of the problem

High-churn gameplay entities (projectiles, effect proxies, AI waves) are
created and destroyed at a much higher rate than the rest of the world. A
plain `World.spawn()` + N `set()` calls followed later by `World.despawn()`
pays, every single cycle: an id allocation/recycle, N component writes (each
one an archetype relocation on `ArchetypeBackend`, a sparse-set insert on
`SparseSetBackend`/`ReactiveBackend`, a bitset word update on `BitsetBackend`,
...), and on despawn the mirror-image teardown of all of that. A `Pool`
amortises this: it pre-spawns N entities ONCE with the template component set,
then cycles them between "acquired" (in play) and "released" (idle, waiting
to be reused) without ever calling `despawn`/`spawn` again.

## Why `release` cannot use `Entity.gen` for stale-handle detection

`release(e)` deliberately never despawns (that is the entire benefit: no id
churn, no archetype migration on the hot acquire/release path). But
`Entity.gen` is bumped ONLY by a backend's own `despawn` -- so an id that is
never despawned keeps the exact same `Entity.gen` for its entire life inside
the pool. That means two different acquisitions of the SAME pool slot hand
back a bit-identical `Entity{id, gen}` -- the one piece of staleness
information the base ECS provides cannot distinguish "the handle I acquired
just now" from "a handle to this slot I was holding three acquisitions ago".

So a bare `ecs.entity.Entity` is structurally the wrong return type for
`acquire()` if "stale handle after release" is to be detectable at all (see
ROADMAP 17.37's extreme-case list) without reintroducing the despawn cost
pooling exists to avoid. `PooledEntity` adds exactly the one bit a bare
`Entity` cannot carry here: a pool-private `epoch`, bumped on every `release`
of that slot. `PooledEntity.entity` is still a completely ordinary, immediately
usable `ecs.entity.Entity` -- ordinary `World.get`/`set`/`has`/`remove` and
every query work on it unmodified, satisfying "acquire() returns a live entity
with the template values". `epoch` is the pool's own add-on, checked only by
`Pool.release`/`Pool.is_valid`, not by `World`.

## The disabled-entity mechanism: a marker component, filtered at the pool's
## query wrapper -- picked because it needs zero changes to `StorageBackend` or
## any of the six backends

`StorageBackend.matching1/2/3`/`for_each2` are pure AND-of-presence queries;
none of the six backends (archetype/sparse-set/bitset/reactive/chunked/naive)
expose an exclusion filter, and adding one to the trait would be a much bigger
change than one Wave-A service module owns. So a released (disabled) entity
CANNOT be made invisible to a raw `World.query2[...]()` call without touching
every backend. Instead: `release`/`acquire` toggle a `Disabled[DID]` marker
component (an ordinary component, added/removed through the SAME `set`/`remove`
that every other component already uses -- correct by construction on all six
backends with zero bespoke per-backend logic), and `Pool.active_query1/2/3`
wrap `World.query1/2/3` with a `has[Disabled[DID]]` filter. The filtering cost
still differs "per backend" exactly the way every other `has[C]` call already
does (bitset: one bit test; archetype: one mask test; sparse-set/reactive: a
dense-index probe; chunked/naive: a page/`Optional` read) -- the mechanism is
written once, generically, and each backend's own native `has` gives it its
per-backend cost shape. Game code that wants pool-aware queries goes through
`Pool.active_query*`; a raw `World.query*` call still sees disabled entities,
which is a documented, known limitation of building this on top of a trait
with no exclusion filter (not a bug in `Pool`).

Toggling `Disabled[DID]` is itself one component add/remove, so it is not
literally free on `ArchetypeBackend` (which relocates a row on any component
add/remove) -- but it is ONE component's relocation on a graph-cached edge
("on a cache hit the transition costs one array read", archetype.mojo), not
the whole template signature's. That is the honest trade `Pool` makes: not
zero migration, but O(1) bounded migration instead of O(template size) churn
on `spawn`+`despawn`.

## Capacity policy (error-policy table, ARCHITECTURE.md §2: "capacity /
## budget overflow" -> the container grows or refuses, and every refusal is
## counted, never silent)

`Pool(cap=0)` is unbounded: `acquire()` on an empty free list grows by one
(spawns + applies the template) and counts it (`diag.counters.POOL_GROWN`).
`Pool(cap=N)` refuses once `N` slots exist and the free list is empty:
`acquire()` returns `Optional[PooledEntity]()` (None) and counts it
(`diag.counters.POOL_EXHAUSTED`) -- never a silent drop, never a `raise`
(capacity overflow is explicitly a "No" in the propagates column: the world
must keep running, the caller decides what None means for it).

## Programmer errors (double release / foreign entity): `debug_assert`, not
## a return value

Releasing a handle that is not one of this pool's ids, or releasing a handle
whose `epoch` does not match the slot's CURRENT epoch (a double release, or a
handle held across an intervening release/re-acquire cycle), is a broken
invariant in the caller, not caller input to validate -- ARCHITECTURE.md §2
puts it squarely in the `debug_assert`/terminate row, exactly like F14's
stale-`World`-handle fix above it in this same package.
"""

from .entity import Entity
from .component import ComponentType
from .storage import StorageBackend
from .world import World
from .sparse_set import SparseSet
from diag.counters import Counters, POOL_GROWN, POOL_EXHAUSTED


@fieldwise_init
struct Disabled[DID: Int](ComponentType):
    """Marker component: an entity carrying this is checked into a `Pool` and
    must be treated as absent by gameplay. `DID` is the component id the
    composing `World`'s backend assigns it -- chosen by the caller like any
    other component (`ecs/component.mojo`'s contract), not fixed by this
    module, since `Pool` does not own the world's component-id space."""

    comptime ID: Int = Self.DID


@fieldwise_init
struct PooledEntity(Copyable, ImplicitlyCopyable, Movable, Writable):
    """A pool-issued handle: `entity` is an ordinary, immediately usable
    `ecs.entity.Entity` (works with `World.get`/`set`/`has`/`remove` and every
    query unmodified); `epoch` is `Pool`'s own add-on, bumped on every
    `release` of this slot, and is what lets `Pool.release`/`Pool.is_valid`
    detect a handle held across a release/re-acquire cycle -- see the module
    docstring for why `Entity.gen` alone cannot do this here."""

    var entity: Entity
    var epoch: Int

    def write_to[W: Writer](self, mut w: W):
        w.write("PooledEntity(", self.entity, ", epoch=", self.epoch, ")")


struct Pool[B: StorageBackend, DID: Int](Movable, Deinitable):
    """A fixed- or growable-capacity pool of pre-built entities over storage
    backend `B`, with a `Disabled[DID]` marker distinguishing "released, idle"
    from "acquired, in play". `cap == 0` means unbounded (always grows on
    exhaustion); `cap > 0` refuses once that many slots exist and none are
    free (see the module docstring's capacity-policy section)."""

    var owned: SparseSet[Int]  # entity id -> slot index
    var slots: List[Entity]  # slot -> canonical (id, gen) — never changes
    var epoch: List[Int]  # slot -> current epoch (bumped on release)
    var free_slots: List[Int]  # stack of slot indices available to acquire
    var cap: Int  # 0 = unbounded
    var counters: Counters
    """Owned by the pool (ARCHITECTURE.md §2: capacity overflow is recorded by
    a `diag` counter; the capacity itself is a property of the caller, per
    `diag/counters.mojo`'s own docstring, so `diag` does not bundle one)."""

    def __init__(out self, cap: Int = 0):
        self.owned = SparseSet[Int]()
        self.slots = List[Entity]()
        self.epoch = List[Int]()
        self.free_slots = List[Int]()
        self.cap = cap
        self.counters = Counters()

    # --- introspection ---
    def capacity(self) -> Int:
        return self.cap

    def total_slots(self) -> Int:
        return len(self.slots)

    def free_count(self) -> Int:
        return len(self.free_slots)

    def owns(self, e: Entity) -> Bool:
        return self.owned.contains(e.id) and self.slots[self.owned.get(e.id)] == e

    def is_valid(self, h: PooledEntity) -> Bool:
        """Non-asserting version of the checks `release` enforces: true iff
        `h` is a currently-acquired handle from THIS pool (not a foreign
        entity, not a stale/double-released handle)."""
        if not self.owned.contains(h.entity.id):
            return False
        var slot = self.owned.get(h.entity.id)
        if self.slots[slot] != h.entity:
            return False
        return self.epoch[slot] == h.epoch

    # --- one new slot: spawn + apply the template ---
    def _new_slot[
        F: def (mut World[Self.B], Entity) -> None
    ](mut self, mut world: World[Self.B], apply_template: F) -> Int:
        var e = world.spawn()
        apply_template(world, e)
        var slot = len(self.slots)
        self.slots.append(e)
        self.epoch.append(0)
        self.owned.set(e.id, slot)
        return slot

    def prime[
        F: def (mut World[Self.B], Entity) -> None
    ](mut self, mut world: World[Self.B], n: Int, apply_template: F):
        """Pre-spawn `n` entities with the template applied, immediately
        disabled and pushed onto the free list. Call once at setup (or again
        to top up a fixed-capacity pool before it would otherwise refuse)."""
        for _ in range(n):
            var slot = self._new_slot[F](world, apply_template)
            world.set(self.slots[slot], Disabled[Self.DID]())
            self.free_slots.append(slot)

    # --- lifecycle ---
    def acquire[
        F: def (mut World[Self.B], Entity) -> None
    ](mut self, mut world: World[Self.B], apply_template: F) -> Optional[PooledEntity]:
        """Return a live, active entity with template values -- either a
        released slot pulled off the free list (no spawn, no archetype
        migration beyond removing `Disabled`), or, if unbounded and empty, a
        freshly grown one. Returns None (and counts it) if a fixed-capacity
        pool is exhausted. `apply_template` is only actually invoked when
        growing; it is the same closure `prime` was given."""
        var slot: Int
        if len(self.free_slots) > 0:
            slot = self.free_slots.pop()
            world.remove[Disabled[Self.DID]](self.slots[slot])
        else:
            if self.cap > 0 and len(self.slots) >= self.cap:
                self.counters.incr(POOL_EXHAUSTED)
                return Optional[PooledEntity]()
            slot = self._new_slot[F](world, apply_template)
            self.counters.incr(POOL_GROWN)
        return Optional[PooledEntity](PooledEntity(self.slots[slot], self.epoch[slot]))

    def release(mut self, mut world: World[Self.B], h: PooledEntity):
        """Return `h` to the pool without despawning (no archetype migration
        of the template set, no id churn). Programmer errors terminate
        (ARCHITECTURE.md §2): releasing a handle this pool never issued, or
        releasing one already released (a stale `epoch`, including a double
        release of the exact same handle)."""
        debug_assert(
            self.owned.contains(h.entity.id), "Pool.release: entity not owned by this pool"
        )
        var slot = self.owned.get(h.entity.id)
        debug_assert(
            self.slots[slot] == h.entity,
            "Pool.release: entity id belongs to this pool but the handle is foreign (id reused by a different pool generation)",
        )
        debug_assert(
            world.is_alive(h.entity), "Pool.release: entity was despawned outside the pool"
        )
        debug_assert(
            h.epoch == self.epoch[slot],
            "Pool.release: stale handle (already released, or held across a release/re-acquire cycle)",
        )
        self.epoch[slot] += 1
        world.set(h.entity, Disabled[Self.DID]())
        self.free_slots.append(slot)

    # --- pool-aware queries: World.query* filtered by Disabled[DID] ---
    def active_query1[A: ComponentType](self, world: World[Self.B]) -> List[Entity]:
        var out = List[Entity]()
        var raw = world.query1[A]()
        for i in range(len(raw)):
            if not world.has[Disabled[Self.DID]](raw[i]):
                out.append(raw[i])
        return out^

    def active_query2[
        A: ComponentType, B2: ComponentType
    ](self, world: World[Self.B]) -> List[Entity]:
        var out = List[Entity]()
        var raw = world.query2[A, B2]()
        for i in range(len(raw)):
            if not world.has[Disabled[Self.DID]](raw[i]):
                out.append(raw[i])
        return out^

    def active_query3[
        A: ComponentType, B2: ComponentType, C: ComponentType
    ](self, world: World[Self.B]) -> List[Entity]:
        var out = List[Entity]()
        var raw = world.query3[A, B2, C]()
        for i in range(len(raw)):
            if not world.has[Disabled[Self.DID]](raw[i]):
                out.append(raw[i])
        return out^
