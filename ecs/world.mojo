"""The world: entities + components over a swappable storage backend.

`World[B: StorageBackend]` is the only type game code touches. Pick the backend
at instantiation:

    var w = World[SparseSetBackend[Position, Velocity]]()
    # ...identical code...
    var w = World[ArchetypeBackend[Position, Velocity]]()

All methods forward to the backend, so swapping `B` changes the storage strategy
without touching any logic. Queries return the matching entities; iterate them
and read/write components with `get`/`set`.

Architecture audit F14 (docs/audits/2026-09-27-architecture.md): every backend's
`get`/`set`/`has`/`remove` indexes storage by `Entity.id` alone and never checks
`Entity.gen`, so a stale handle (an old copy of an `Entity` whose id has since
been despawned and recycled) silently aliases whatever now occupies that id --
contradicting entity.mojo's own contract that "a stale copy can be detected as
dead". `ecs.pool` makes stale handles routine (an entity cycles between
acquired and pool-released many times over its life), so the four accessors
below now `debug_assert(is_alive(e))` before forwarding: a stale handle
terminates loudly under `-D ASSERT=all` (`pixi run test`) instead of silently
reading/writing the wrong entity's data, at zero cost in a release build.
`try_get` is the raising counterpart for a call site where a stale handle is
caller input to validate (ARCHITECTURE.md §2's "invalid input" row) rather than
an engine-internal invariant to assert.
"""

from .storage import StorageBackend
from .entity import Entity
from .component import ComponentType


struct World[B: StorageBackend](Movable, Deinitable):
    var backend: Self.B

    def __init__(out self):
        self.backend = Self.B()

    # --- lifecycle ---
    def spawn(mut self) -> Entity:
        return self.backend.spawn()

    def despawn(mut self, e: Entity):
        self.backend.despawn(e)

    def is_alive(self, e: Entity) -> Bool:
        return self.backend.is_alive(e)

    def entity_count(self) -> Int:
        return self.backend.entity_count()

    # --- components ---
    def set[C: ComponentType](mut self, e: Entity, var value: C):
        debug_assert(self.backend.is_alive(e), "World.set: stale or dead entity handle")
        self.backend.set[C](e, value^)

    def has[C: ComponentType](self, e: Entity) -> Bool:
        debug_assert(self.backend.is_alive(e), "World.has: stale or dead entity handle")
        return self.backend.has[C](e)

    def get[C: ComponentType](self, e: Entity) -> C:
        debug_assert(self.backend.is_alive(e), "World.get: stale or dead entity handle")
        return self.backend.get[C](e)

    def remove[C: ComponentType](mut self, e: Entity):
        debug_assert(self.backend.is_alive(e), "World.remove: stale or dead entity handle")
        self.backend.remove[C](e)

    def try_get[C: ComponentType](self, e: Entity) raises -> C:
        """Raising counterpart to `get` (F14): a stale/dead handle at a public
        API boundary is caller input, not an engine invariant, so this raises
        instead of terminating -- for callers (like `ecs.pool`) that want to
        recover rather than crash."""
        if not self.backend.is_alive(e):
            raise Error("World.try_get: stale or dead entity handle")
        return self.backend.get[C](e)

    # --- spawn helpers ---
    def spawn1[A: ComponentType](mut self, a: A) -> Entity:
        var e = self.spawn()
        self.set[A](e, a)
        return e

    def spawn2[A: ComponentType, B2: ComponentType](mut self, a: A, b: B2) -> Entity:
        var e = self.spawn()
        self.set[A](e, a)
        self.set[B2](e, b)
        return e

    # --- queries ---
    def query1[A: ComponentType](self) -> List[Entity]:
        return self.backend.matching1[A]()

    def query2[A: ComponentType, B2: ComponentType](self) -> List[Entity]:
        return self.backend.matching2[A, B2]()

    def query3[
        A: ComponentType, B2: ComponentType, C: ComponentType
    ](self) -> List[Entity]:
        return self.backend.matching3[A, B2, C]()

    # --- zero-allocation iteration ---
    def for_each2[
        A: ComponentType,
        B2: ComponentType,
        F: def (mut A, B2) -> None,
    ](mut self, func: F):
        """Run `func(mut a, b)` over every entity with both A and B — no per-frame
        `List[Entity]`, no per-access lookup. The fast replacement for the
        `query2` + `get`/`set` handle loop; works on every backend."""
        self.backend.for_each2[A, B2](func)
