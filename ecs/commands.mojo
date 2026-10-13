"""Command buffer: deferred structural changes (the DOTS/Bevy sync-point idea).

Despawning or re-relating entities WHILE iterating query results invalidates
the iteration (and, on the archetype backend, relocates rows under your feet).
A `CommandBuffer` records the structural intent during iteration and `apply`
executes everything at a safe sync point, in recording order — deterministic
by construction.

Covered: despawn (with relation cleanup), relation add/remove, and DEFERRED
COMPONENT SET (`SetBuffer`, ROADMAP 4.4): per-component-type queues behind
type-erased heap slots (the backends' `Slot` idiom — this nightly cannot store
a heterogeneous `List[C]` directly), plus a global order log so `apply`
replays writes in EXACT recording order across types. Writes to entities that
died before the sync point are dropped (Bevy semantics), not resurrected.
"""

from std.memory import alloc, Layout
from .entity import Entity
from .component import ComponentType
from .world import World
from .storage import StorageBackend
from .relations import RelationStore

comptime Slot = type_of(alloc[NoneType](Layout[NoneType](count=1)).unsafe_leak())


@fieldwise_init
struct _RelCmd(Copyable, ImplicitlyCopyable, Movable):
    var add: Bool
    var rel: Int
    var src: Entity
    var dst: Entity


struct CommandBuffer(Movable, Deinitable):
    var despawns: List[Entity]
    var rel_cmds: List[_RelCmd]

    def __init__(out self):
        self.despawns = List[Entity]()
        self.rel_cmds = List[_RelCmd]()

    def despawn(mut self, e: Entity):
        self.despawns.append(e)

    def relate(mut self, rel: Int, src: Entity, dst: Entity):
        self.rel_cmds.append(_RelCmd(True, rel, src, dst))

    def unrelate(mut self, rel: Int, src: Entity, dst: Entity):
        self.rel_cmds.append(_RelCmd(False, rel, src, dst))

    def apply[B: StorageBackend](
        mut self, mut w: World[B], mut rels: RelationStore
    ) raises:
        """Execute at the sync point: relation edits in recording order, then
        despawns (each scrubbing its relations first). Buffers reset."""
        for i in range(len(self.rel_cmds)):
            var c = self.rel_cmds[i]
            if c.add:
                rels.relate(c.rel, c.src, c.dst)
            else:
                rels.unrelate(c.rel, c.src, c.dst)
        for i in range(len(self.despawns)):
            rels.clear_entity(self.despawns[i])
            w.despawn(self.despawns[i])
        self.despawns = List[Entity]()
        self.rel_cmds = List[_RelCmd]()


@fieldwise_init
struct _SetRec[C: ComponentType](Copyable, ImplicitlyCopyable, Movable):
    var e: Entity
    var v: Self.C


comptime _OP_DESPAWN = -1000000
comptime _OP_SPAWN = -2000000


struct SetBuffer[*CTs: ComponentType](Movable, Deinitable):
    """Deferred structural changes for a world with component pack `CTs`:
    `set`, and (ROADMAP 17.77) `remove[C]`, `despawn` and `spawn`, replayed
    by `apply` in exact recording order. Values are held in per-type queues
    (type-erased heap slots); `order` remembers which queue / operation each
    record went to.

    `spawn` returns a placeholder `Entity` (negative id) usable in later
    `set` / `remove` / `despawn` calls of the same buffer; `apply` creates the
    real entity at that point in the order and returns the real handles in
    spawn order. Records for entities dead by then are dropped."""

    comptime N: Int = len(Self.CTs)
    var slots: List[Slot]  # slot i -> heap List[_SetRec[CTs[i]]]
    # recording order: slot index per write; -(slot + 1) per remove;
    # _OP_DESPAWN / _OP_SPAWN
    var order: List[Int]
    var targets: List[Entity]  # entity per remove / despawn record, in order
    var n_spawn: Int

    def __init__(out self):
        self.slots = List[Slot](capacity=Self.N)
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            var p = alloc[List[_SetRec[T]]](Layout[List[_SetRec[T]]](count=1)).unsafe_leak()
            p.unsafe_write(List[_SetRec[T]]())
            self.slots.append(p.unsafe_bitcast[NoneType]())
        self.order = List[Int]()
        self.targets = List[Entity]()
        self.n_spawn = 0

    def __deinit__(deinit self):
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            var p = self.slots[i].unsafe_bitcast[List[_SetRec[T]]]()
            p.unsafe_deinit_pointee()
            p.unsafe_free()

    @staticmethod
    def _slot_of[C: ComponentType]() -> Int:
        comptime for i in range(Self.N):
            comptime if Self.CTs[i].ID == C.ID:
                return i
        return -1

    def set[C: ComponentType](mut self, e: Entity, var v: C):
        var si = Self._slot_of[C]()
        var q = self.slots[si].unsafe_bitcast[List[_SetRec[C]]]()
        q[].append(_SetRec[C](e, v^))
        self.order.append(si)

    def remove[C: ComponentType](mut self, e: Entity):
        self.order.append(-(Self._slot_of[C]() + 1))
        self.targets.append(e)

    def despawn(mut self, e: Entity):
        self.order.append(_OP_DESPAWN)
        self.targets.append(e)

    def spawn(mut self) -> Entity:
        """A placeholder for an entity `apply` will create (17.77)."""
        self.order.append(_OP_SPAWN)
        self.n_spawn += 1
        return Entity(-self.n_spawn, -1)

    def pending(self) -> Int:
        return len(self.order)

    def apply[B: StorageBackend](mut self, mut w: World[B]) -> List[Entity]:
        """Replay every deferred record in recording order at the sync
        point; returns the entities created by `spawn`, in spawn order.
        Records for entities that died in the meantime are dropped. Queues
        reset afterwards."""
        var cursors = List[Int]()
        for _ in range(Self.N):
            cursors.append(0)
        var spawned = List[Entity]()
        var tcur = 0
        for k in range(len(self.order)):
            var s = self.order[k]
            if s == _OP_SPAWN:
                spawned.append(w.spawn())
                continue
            if s < 0:
                var e = self.targets[tcur]
                tcur += 1
                if e.id < 0:
                    e = spawned[-e.id - 1]
                if not w.is_alive(e):
                    continue
                if s == _OP_DESPAWN:
                    w.despawn(e)
                else:
                    comptime for i in range(Self.N):
                        if i == -s - 1:
                            w.remove[Self.CTs[i]](e)
                continue
            comptime for i in range(Self.N):
                if i == s:
                    comptime T = Self.CTs[i]
                    var q = self.slots[i].unsafe_bitcast[List[_SetRec[T]]]()
                    var rec = q[][cursors[i]]
                    cursors[i] += 1
                    var e = rec.e
                    if e.id < 0:
                        e = spawned[-e.id - 1]
                    if w.is_alive(e):
                        w.set(e, rec.v)
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            var q = self.slots[i].unsafe_bitcast[List[_SetRec[T]]]()
            q[] = List[_SetRec[T]]()
        self.order = List[Int]()
        self.targets = List[Entity]()
        self.n_spawn = 0
        return spawned^
