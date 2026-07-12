"""Entity relationships as first-class data (the flecs-v4-style pair store).

A relation is a typed edge `(rel, source, target)` between two entities —
`ChildOf`, `Likes`, `Targets`, … Relation ids are plain comptime `Int`s, like
component ids. The store keeps three indexes so every query direction is a
lookup, not a scan:

  * forward: `(rel, source)` -> targets     — "whom does e point at?"
  * reverse: `(rel, target)` -> sources     — "who points at e?"
  * touch:   entity id -> every edge it participates in (either side), so
    `clear_entity` (despawn cleanup) is local.

List order is insertion order everywhere, so query results are deterministic.
Wildcard enumeration `(rel, *, *)` walks the forward index.
"""

from std.collections import Dict
from .entity import Entity

comptime _SHIFT: Int = 1 << 32


def _pack(rel: Int, id: Int) -> Int:
    return rel * _SHIFT + id


@fieldwise_init
struct RelPair(Copyable, ImplicitlyCopyable, Movable):
    var src: Entity
    var dst: Entity


def _drop(mut d: Dict[Int, List[Entity]], k: Int, ent_id: Int) raises:
    if k not in d:
        return
    var kept = List[Entity]()
    var old = d[k].copy()
    for i in range(len(old)):
        if old[i].id != ent_id:
            kept.append(old[i])
    d[k] = kept^


def _drop_touch(mut touch: Dict[Int, List[Int]], ent_id: Int, packed: Int) raises:
    if ent_id not in touch:
        return
    var kept = List[Int]()
    var old = touch[ent_id].copy()
    for i in range(len(old)):
        if old[i] != packed:
            kept.append(old[i])
    touch[ent_id] = kept^


struct RelationStore(Movable, ImplicitlyDeletable):
    var fwd: Dict[Int, List[Entity]]  # pack(rel, src.id) -> targets
    var rev: Dict[Int, List[Entity]]  # pack(rel, dst.id) -> sources
    var touch: Dict[Int, List[Int]]  # entity id -> pack(rel, other.id)*2+dir
    var rel_ids: List[Int]  # distinct relation ids, insertion order
    var known: Dict[Int, Entity]  # id -> full Entity (generation kept)

    def __init__(out self):
        self.fwd = Dict[Int, List[Entity]]()
        self.rev = Dict[Int, List[Entity]]()
        self.touch = Dict[Int, List[Int]]()
        self.rel_ids = List[Int]()
        self.known = Dict[Int, Entity]()

    def has(self, rel: Int, src: Entity, dst: Entity) raises -> Bool:
        var k = _pack(rel, src.id)
        if k not in self.fwd:
            return False
        var ts = self.fwd[k].copy()
        for i in range(len(ts)):
            if ts[i] == dst:
                return True
        return False

    def relate(mut self, rel: Int, src: Entity, dst: Entity) raises:
        """Add the edge (idempotent)."""
        if self.has(rel, src, dst):
            return
        var kf = _pack(rel, src.id)
        if kf not in self.fwd:
            self.fwd[kf] = List[Entity]()
        self.fwd[kf].append(dst)
        var kr = _pack(rel, dst.id)
        if kr not in self.rev:
            self.rev[kr] = List[Entity]()
        self.rev[kr].append(src)
        self.known[src.id] = src
        self.known[dst.id] = dst
        if src.id not in self.touch:
            self.touch[src.id] = List[Int]()
        self.touch[src.id].append(_pack(rel, dst.id) * 2)
        if dst.id not in self.touch:
            self.touch[dst.id] = List[Int]()
        self.touch[dst.id].append(_pack(rel, src.id) * 2 + 1)
        var known = False
        for i in range(len(self.rel_ids)):
            if self.rel_ids[i] == rel:
                known = True
                break
        if not known:
            self.rel_ids.append(rel)

    def unrelate(mut self, rel: Int, src: Entity, dst: Entity) raises:
        _drop(self.fwd, _pack(rel, src.id), dst.id)
        _drop(self.rev, _pack(rel, dst.id), src.id)
        _drop_touch(self.touch, src.id, _pack(rel, dst.id) * 2)
        _drop_touch(self.touch, dst.id, _pack(rel, src.id) * 2 + 1)

    def targets(self, rel: Int, src: Entity) raises -> List[Entity]:
        """(src, rel, ?) — insertion order."""
        var k = _pack(rel, src.id)
        if k not in self.fwd:
            return List[Entity]()
        return self.fwd[k].copy()

    def sources(self, rel: Int, dst: Entity) raises -> List[Entity]:
        """(?, rel, dst) — insertion order."""
        var k = _pack(rel, dst.id)
        if k not in self.rev:
            return List[Entity]()
        return self.rev[k].copy()

    def pairs(self, rel: Int) raises -> List[RelPair]:
        """Wildcard (rel, *, *): every edge of this relation."""
        var out = List[RelPair]()
        for entry in self.fwd.items():
            if entry.key // _SHIFT != rel:
                continue
            var src_id = entry.key % _SHIFT
            var src = self.known[src_id]
            for i in range(len(entry.value)):
                out.append(RelPair(src, entry.value[i]))
        return out^

    def clear_entity(mut self, e: Entity) raises:
        """Remove every edge touching `e` (despawn cleanup, both directions)."""
        if e.id not in self.touch:
            return
        var edges = self.touch[e.id].copy()
        for i in range(len(edges)):
            var dir = edges[i] % 2
            var packed = edges[i] // 2
            var rel = packed // _SHIFT
            var other = packed % _SHIFT
            if dir == 0:
                # e was the source; other is a target id
                _drop(self.fwd, _pack(rel, e.id), other)
                _drop(self.rev, _pack(rel, other), e.id)
                _drop_touch(self.touch, other, _pack(rel, e.id) * 2 + 1)
            else:
                # e was the target; other is a source id
                _drop(self.rev, _pack(rel, e.id), other)
                _drop(self.fwd, _pack(rel, other), e.id)
                _drop_touch(self.touch, other, _pack(rel, e.id) * 2)
        self.touch[e.id] = List[Int]()
