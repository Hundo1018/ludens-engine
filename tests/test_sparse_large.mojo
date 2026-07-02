"""Large-N test: proves the sparse index has no fixed cap after WS1.

Before WS1 every backend's `SparseSet` held its index as `InlineArray[Int, 4096]`
by value, so spawning past ~4096 entities was impossible (and large `cap` blew up
codegen). Now the index grows on the heap, so hundreds of thousands / millions of
entities work. This test spawns well past the old ceiling and checks counts,
queries, and a high-id component read.
"""

from harness.runner import Suite
from ecs.world import World
from ecs.storage import StorageBackend
from ecs.entity import Entity
from ecs.sparse_backend import SparseSetBackend
from ecs.archetype import ArchetypeBackend
from ecs.component import ComponentType
from geometry.vec import Vec2, Real


@fieldwise_init
struct Pos(ComponentType):
    comptime ID: Int = 0
    var p: Vec2


@fieldwise_init
struct Vel(ComponentType):
    comptime ID: Int = 1
    var v: Vec2


def check_backend[B: StorageBackend](mut s: Suite, name: String, n: Int):
    var w = World[B]()
    for i in range(n):
        _ = w.spawn2(Pos(Vec2(Real(i), 0)), Vel(Vec2(1, 1)))
    s.eqi(w.entity_count(), n, name + ": count == n (past old 4096 cap)")
    s.eqi(len(w.query2[Pos, Vel]()), n, name + ": query2 finds all n")
    # high-id component read (id = n-1, freshly spawned -> gen 0)
    var e = Entity(n - 1, 0)
    s.eqi(Int(w.get[Pos](e).p[0]), n - 1, name + ": high-id Pos preserved")


def main() raises:
    var s = Suite("sparse_large")
    check_backend[SparseSetBackend[Pos, Vel]](s, "sparse", 1_000_000)
    check_backend[ArchetypeBackend[Pos, Vel]](s, "archetype", 200_000)
    s.finish()
