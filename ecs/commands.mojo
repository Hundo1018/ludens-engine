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

from std.memory import alloc
from .entity import Entity
from .component import ComponentType
from .world import World
from .storage import StorageBackend
from .relations import RelationStore

comptime Slot = type_of(alloc[NoneType](1))


@fieldwise_init
struct _RelCmd(Copyable, ImplicitlyCopyable, Movable):
    var add: Bool
    var rel: Int
    var src: Entity
    var dst: Entity


struct CommandBuffer(Movable, ImplicitlyDeletable):
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


struct SetBuffer[*CTs: ComponentType](Movable, ImplicitlyDeletable):
    """Deferred component writes for a world with component pack `CTs`.
    Values are held in per-type queues (type-erased heap slots); `order`
    remembers which queue each recorded write went to, so `apply` replays the
    exact interleaving of the original `set` calls."""

    comptime N: Int = len(Self.CTs)
    var slots: List[Slot]  # slot i -> heap List[_SetRec[CTs[i]]]
    var order: List[Int]  # recording order: slot index per write

    def __init__(out self):
        self.slots = List[Slot](capacity=Self.N)
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            var p = alloc[List[_SetRec[T]]](1)
            p.init_pointee_move(List[_SetRec[T]]())
            self.slots.append(p.bitcast[NoneType]())
        self.order = List[Int]()

    def __del__(deinit self):
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            var p = self.slots[i].bitcast[List[_SetRec[T]]]()
            p.destroy_pointee()
            p.free()

    @staticmethod
    def _slot_of[C: ComponentType]() -> Int:
        comptime for i in range(Self.N):
            comptime if Self.CTs[i].ID == C.ID:
                return i
        return -1

    def set[C: ComponentType](mut self, e: Entity, var v: C):
        var si = Self._slot_of[C]()
        var q = self.slots[si].bitcast[List[_SetRec[C]]]()
        q[].append(_SetRec[C](e, v^))
        self.order.append(si)

    def pending(self) -> Int:
        return len(self.order)

    def apply[B: StorageBackend](mut self, mut w: World[B]):
        """Replay every deferred write in recording order at the sync point.
        Writes to entities that died in the meantime are dropped. Queues
        reset afterwards."""
        var cursors = List[Int]()
        for _ in range(Self.N):
            cursors.append(0)
        for k in range(len(self.order)):
            var s = self.order[k]
            comptime for i in range(Self.N):
                if i == s:
                    comptime T = Self.CTs[i]
                    var q = self.slots[i].bitcast[List[_SetRec[T]]]()
                    var rec = q[][cursors[i]]
                    cursors[i] += 1
                    if w.is_alive(rec.e):
                        w.set(rec.e, rec.v)
        comptime for i in range(Self.N):
            comptime T = Self.CTs[i]
            var q = self.slots[i].bitcast[List[_SetRec[T]]]()
            q[] = List[_SetRec[T]]()
        self.order = List[Int]()
