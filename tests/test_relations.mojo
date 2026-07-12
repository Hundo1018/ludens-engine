from harness.runner import Suite
from ecs.entity import Entity
from ecs.world import World
from ecs.sparse_backend import SparseSetBackend
from ecs.component import ComponentType
from ecs.relations import RelationStore
from ecs.commands import CommandBuffer

comptime CHILD_OF = 0
comptime LIKES = 1


@fieldwise_init
struct Tag(ComponentType, Copyable, ImplicitlyCopyable, Movable):
    comptime ID: Int = 0
    var v: Int


def main() raises:
    var s = Suite("relations")
    var w = World[SparseSetBackend[Tag]]()
    var rels = RelationStore()

    var parent = w.spawn()
    var kid1 = w.spawn()
    var kid2 = w.spawn()
    var toy = w.spawn()

    # basic edges + idempotence
    rels.relate(CHILD_OF, kid1, parent)
    rels.relate(CHILD_OF, kid2, parent)
    rels.relate(CHILD_OF, kid1, parent)  # duplicate: no-op
    rels.relate(LIKES, kid1, toy)
    rels.relate(LIKES, kid2, toy)
    s.check(rels.has(CHILD_OF, kid1, parent), "has (kid1 child-of parent)")
    s.check(not rels.has(CHILD_OF, parent, kid1), "direction matters")

    # forward / reverse queries, insertion order
    var kids = rels.sources(CHILD_OF, parent)
    s.check(len(kids) == 2, "parent has 2 children")
    s.check(kids[0] == kid1 and kids[1] == kid2, "deterministic order")
    var of1 = rels.targets(CHILD_OF, kid1)
    s.check(len(of1) == 1 and of1[0] == parent, "kid1's parent")

    # wildcard (rel, *, *)
    var all_child = rels.pairs(CHILD_OF)
    var all_likes = rels.pairs(LIKES)
    s.check(len(all_child) == 2, "wildcard child-of count")
    s.check(len(all_likes) == 2, "wildcard likes count")
    var gen_ok = True
    for i in range(len(all_child)):
        if all_child[i].dst != parent:
            gen_ok = False
    s.check(gen_ok, "wildcard preserves full entities (gen intact)")

    # unrelate
    rels.unrelate(LIKES, kid1, toy)
    s.check(not rels.has(LIKES, kid1, toy), "unrelate removes the edge")
    s.check(rels.has(LIKES, kid2, toy), "other edges untouched")
    s.check(len(rels.sources(LIKES, toy)) == 1, "reverse index updated")

    # despawn cleanup: clearing the toy removes edges from BOTH directions
    rels.clear_entity(toy)
    s.check(len(rels.targets(LIKES, kid2)) == 0, "clear_entity scrubs reverse edges")
    s.check(len(rels.pairs(LIKES)) == 0, "likes fully gone")
    s.check(len(rels.pairs(CHILD_OF)) == 2, "child-of untouched by toy cleanup")

    # command buffer: defer structural changes while "iterating"
    var cmd = CommandBuffer()
    var kids_now = rels.sources(CHILD_OF, parent)
    for i in range(len(kids_now)):
        cmd.despawn(kids_now[i])  # orphan the family during iteration
    cmd.relate(LIKES, parent, parent)  # and record a new edge
    s.check(w.is_alive(kid1), "despawn deferred until apply")
    cmd.apply(w, rels)
    s.check(not w.is_alive(kid1) and not w.is_alive(kid2), "applied despawns")
    s.check(len(rels.sources(CHILD_OF, parent)) == 0, "relations scrubbed on despawn")
    s.check(rels.has(LIKES, parent, parent), "deferred relate applied")

    # determinism: two identical scripted runs give identical wildcard order
    var ra = RelationStore()
    var rb = RelationStore()
    for i in range(10):
        var a = Entity(100 + i, 1)
        var b = Entity(200 + (i * 3) % 7, 1)
        ra.relate(LIKES, a, b)
        rb.relate(LIKES, a, b)
    var pa = ra.pairs(LIKES)
    var pb = rb.pairs(LIKES)
    var same = len(pa) == len(pb)
    if same:
        for i in range(len(pa)):
            if pa[i].src != pb[i].src or pa[i].dst != pb[i].dst:
                same = False
    s.check(same, "identical runs enumerate identically")

    s.finish()
