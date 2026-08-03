"""Reactive ECS backend (Entitas-style groups).

Component values live in per-type `SparseSet`s (as in the sparse-set backend),
but queries are not recomputed on demand: each distinct query signature owns a
**group** — a cached set of matching entities. Every mutation (`set` / `remove` /
`despawn`) re-evaluates the touched entity against all registered groups and
incrementally adds/removes it. A query then just reads its group's cached set, so
after warm-up queries are O(result) with no scanning; the cost moves onto writes
(O(#groups) per mutation). This is the reactive trade-off.

Groups are created lazily the first time a signature is queried. Because the
`StorageBackend` query methods take `self` immutably, the group registry lives on
the heap behind a pointer (interior mutability) so a query can register and
populate a new group without a `mut self`.

PUSH-BASED OBSERVERS (ROADMAP 4.4): `observe1`/`observe2` register a filter
(event-kind mask × component set); every mutation then delivers a compact
`ObsEvent` into each matching observer's inbox AT THE MUTATION SITE — the poll
moves from O(world) scanning to O(inbox) draining. Semantics follow flecs:
`EV_ADD` fires when the component was absent, `EV_SET` on every write
(including the first), `EV_REMOVE` on remove and on despawn (despawn scrubs
components in slot order, so the event order is deterministic). Trigger order
is mutation order — replaying a scenario yields a bit-identical event list
(`test_observers`).
"""

from std.memory import UnsafePointer, alloc
from .component import ComponentType
from .entity import Entity
from .sparse_set import SparseSet
from .storage import StorageBackend

comptime Slot = type_of(alloc[NoneType](1))


struct _Group(Movable, ImplicitlyDeletable):
    """A cached query result: the entity ids matching `mask`."""

    var mask: Int  # OR of (1 << slot) for each required component
    var members: SparseSet[Int]  # member id -> 0 (dense keys = members)

    def __init__(out self, mask: Int):
        self.mask = mask
        self.members = SparseSet[Int]()


comptime EV_ADD = 0  # component appeared on the entity
comptime EV_SET = 1  # component written (every set, including the first)
comptime EV_REMOVE = 2  # component removed (explicitly or by despawn)


@fieldwise_init
struct ObsEvent(Copyable, ImplicitlyCopyable, Movable):
    """One delivered component event (inbox order = trigger order)."""

    var kind: Int  # EV_ADD / EV_SET / EV_REMOVE
    var slot: Int  # component slot index in the backend's CTs pack
    var id: Int  # entity id


struct _Observer(Movable, ImplicitlyDeletable):
    """A push subscription: kind/component filter plus the event inbox."""

    var kind_mask: Int  # OR of (1 << EV_*)
    var comp_mask: Int  # OR of (1 << slot)
    var inbox: List[ObsEvent]

    def __init__(out self, kind_mask: Int, comp_mask: Int):
        self.kind_mask = kind_mask
        self.comp_mask = comp_mask
        self.inbox = List[ObsEvent]()


struct ReactiveBackend[*CTs: ComponentType](StorageBackend):
    comptime N: Int = len(Self.CTs)
    var slots: List[Slot]  # slot i -> heap SparseSet[CTs[i], cap]
    var alive: SparseSet[Int]  # entity id -> generation
    var counter: Int
    # Generational recycling (see ArchetypeBackend): `gens[id]` outlives
    # `alive`, so a reused id returns with a higher generation and stale
    # handles stay dead. Gated per backend in `test_backend_parity`.
    var free_ids: List[Int]
    var gens: List[Int]
    var groups: type_of(alloc[List[_Group]](1))  # registry (heap)
    var observers: type_of(alloc[List[_Observer]](1))  # push subscriptions

    def __init__(out self):
        self.slots = List[Slot](capacity=Self.N)
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            var p = alloc[SparseSet[T]](1)
            p.unsafe_write(SparseSet[T]())
            self.slots.append(p.bitcast[NoneType]())
        self.alive = SparseSet[Int]()
        self.counter = 0
        self.free_ids = List[Int]()
        self.gens = List[Int]()
        self.groups = alloc[List[_Group]](1)
        self.groups.unsafe_write(List[_Group]())
        self.observers = alloc[List[_Observer]](1)
        self.observers.unsafe_write(List[_Observer]())

    def __del__(deinit self):
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            var p = self.slots[i].bitcast[SparseSet[T]]()
            p.unsafe_deinit_pointee()
            p.free()
        self.groups.unsafe_deinit_pointee()
        self.groups.free()
        self.observers.unsafe_deinit_pointee()
        self.observers.free()

    # --- push-based observers ---
    def observe1[C: ComponentType](mut self, kind_mask: Int) -> Int:
        """Subscribe to `kind_mask` events (OR of 1 << EV_*) on component C;
        returns the observer handle for `drain`."""
        self.observers[].append(
            _Observer(kind_mask, 1 << Self._slot_of[C]())
        )
        return len(self.observers[]) - 1

    def observe2[A: ComponentType, B: ComponentType](
        mut self, kind_mask: Int
    ) -> Int:
        self.observers[].append(
            _Observer(
                kind_mask,
                (1 << Self._slot_of[A]()) | (1 << Self._slot_of[B]()),
            )
        )
        return len(self.observers[]) - 1

    def drain(mut self, h: Int) -> List[ObsEvent]:
        """Take the observer's inbox (trigger order); the inbox resets."""
        var out = self.observers[][h].inbox.copy()
        self.observers[][h].inbox = List[ObsEvent]()
        return out^

    def _emit(self, kind: Int, slot: Int, id: Int):
        var obs = self.observers
        for oi in range(len(obs[])):
            if (
                obs[][oi].kind_mask & (1 << kind) != 0
                and obs[][oi].comp_mask & (1 << slot) != 0
            ):
                obs[][oi].inbox.append(ObsEvent(kind, slot, id))

    @staticmethod
    def _slot_of[C: ComponentType]() -> Int:
        comptime for i in range(Self.N):
            comptime if Self.CTs[i].ID == C.ID:
                return i
        return -1

    def _store[C: ComponentType](self) -> type_of(alloc[SparseSet[C]](1)):
        return self.slots[Self._slot_of[C]()].bitcast[SparseSet[C]]()

    # --- reactive group maintenance ---
    def _entity_mask(self, id: Int) -> Int:
        var m = 0
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            if self._store[T]()[].contains(id):
                m |= 1 << i
        return m

    def _update_groups(self, id: Int):
        """Re-evaluate entity `id` against every registered group (interior mut)."""
        var m = self._entity_mask(id)
        var gs = self.groups
        for gi in range(len(gs[])):
            var want = gs[][gi].mask
            var satisfies = (m & want) == want
            var member = gs[][gi].members.contains(id)
            if satisfies and not member:
                gs[][gi].members.set(id, 0)
            elif not satisfies and member:
                gs[][gi].members.remove(id)

    def _group_for(self, mask: Int) -> Int:
        var gs = self.groups
        for gi in range(len(gs[])):
            if gs[][gi].mask == mask:
                return gi
        # First query for this signature: register and populate from live entities.
        var g = _Group(mask)
        for i in range(self.alive.dense_len()):
            var id = self.alive.key_at(i)
            if (self._entity_mask(id) & mask) == mask:
                g.members.set(id, 0)
        gs[].append(g^)
        return len(gs[]) - 1

    def _collect(self, gi: Int) -> List[Entity]:
        var out = List[Entity]()
        var gs = self.groups
        var n = gs[][gi].members.dense_len()
        for i in range(n):
            var id = gs[][gi].members.key_at(i)
            out.append(Entity(id, self.alive.get(id)))
        return out^

    # --- lifecycle ---
    def _ensure_gen(mut self, id: Int):
        while len(self.gens) <= id:
            self.gens.append(0)

    def spawn(mut self) -> Entity:
        var id: Int
        if len(self.free_ids) > 0:
            id = self.free_ids.pop()
        else:
            id = self.counter
            self.counter += 1
        self._ensure_gen(id)
        var gen = self.gens[id]
        self.alive.set(id, gen)
        return Entity(id, gen)  # no components yet -> matches no (nonzero) group

    def despawn(mut self, e: Entity):
        if not self.is_alive(e):
            return
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            if self._store[T]()[].contains(e.id):
                self._emit(EV_REMOVE, i, e.id)  # slot order: deterministic
            self._store[T]()[].remove(e.id)
        self._update_groups(e.id)  # mask now 0 -> drops from all groups
        self.alive.remove(e.id)
        self._ensure_gen(e.id)
        self.gens[e.id] = e.gen + 1
        self.free_ids.append(e.id)

    def is_alive(self, e: Entity) -> Bool:
        return self.alive.contains(e.id) and self.alive.get(e.id) == e.gen

    def entity_count(self) -> Int:
        return len(self.alive)

    # --- typed component access ---
    def set[C: ComponentType](mut self, e: Entity, var value: C):
        var existed = self._store[C]()[].contains(e.id)
        self._store[C]()[].set(e.id, value)
        self._update_groups(e.id)
        if not existed:
            self._emit(EV_ADD, Self._slot_of[C](), e.id)
        self._emit(EV_SET, Self._slot_of[C](), e.id)

    def has[C: ComponentType](self, e: Entity) -> Bool:
        return self._store[C]()[].contains(e.id)

    def get[C: ComponentType](self, e: Entity) -> C:
        return self._store[C]()[].get(e.id)

    def remove[C: ComponentType](mut self, e: Entity):
        var existed = self._store[C]()[].contains(e.id)
        self._store[C]()[].remove(e.id)
        self._update_groups(e.id)
        if existed:
            self._emit(EV_REMOVE, Self._slot_of[C](), e.id)

    # --- queries: read cached groups ---
    def matching1[A: ComponentType](self) -> List[Entity]:
        return self._collect(self._group_for(1 << Self._slot_of[A]()))

    def matching2[A: ComponentType, B: ComponentType](self) -> List[Entity]:
        var mask = (1 << Self._slot_of[A]()) | (1 << Self._slot_of[B]())
        return self._collect(self._group_for(mask))

    def matching3[
        A: ComponentType, B: ComponentType, C: ComponentType
    ](self) -> List[Entity]:
        var mask = (
            (1 << Self._slot_of[A]())
            | (1 << Self._slot_of[B]())
            | (1 << Self._slot_of[C]())
        )
        return self._collect(self._group_for(mask))

    def for_each2[
        A: ComponentType,
        B: ComponentType,
        func: def (mut A, B) capturing [_] -> None,
    ](mut self):
        # Components live in per-type SparseSets (as in the sparse backend); iterate
        # the smaller, probe the larger. No List[Entity] allocation.
        var sa = self._store[A]()
        var sb = self._store[B]()
        if sa[].dense_len() <= sb[].dense_len():
            for i in range(sa[].dense_len()):
                var id = sa[].key_at(i)
                if sb[].contains(id):
                    var a = sa[].value_at(i)
                    func(a, sb[].get(id))
                    sa[].set(id, a)
        else:
            for i in range(sb[].dense_len()):
                var id = sb[].key_at(i)
                if sa[].contains(id):
                    var a = sa[].get(id)
                    func(a, sb[].value_at(i))
                    sa[].set(id, a)
