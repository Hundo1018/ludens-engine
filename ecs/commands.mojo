"""Command buffer: deferred structural changes (the DOTS/Bevy sync-point idea).

Despawning or re-relating entities WHILE iterating query results invalidates
the iteration (and, on the archetype backend, relocates rows under your feet).
A `CommandBuffer` records the structural intent during iteration and `apply`
executes everything at a safe sync point, in recording order — deterministic
by construction.

Covered: despawn (with relation cleanup) and relation add/remove. Deferred
component set/remove needs type-erased storage and is future work (noted in
ROADMAP 3.3).
"""

from .entity import Entity
from .world import World
from .storage import StorageBackend
from .relations import RelationStore


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
