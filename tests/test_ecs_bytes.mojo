# tier: component
"""ECS storage accounting (ROADMAP 17.79, `World.storage_bytes`).

  1. Ordinary: on all six backends, 1000 entities with A (16 bytes) of
     which every other one also has B (8 bytes): each backend reports at
     least the component payload, 1000 x 16 + 500 x 8 = 20000 bytes.
  2. Integration: growth is linear: 2000 entities cost twice the bytes of
     1000 (within 2 %, so "bytes per entity" predicts the next thousand);
     the backends' layouts differ and the table shows by how much.
  3. Extreme: an empty world reports a small constant; despawning every
     entity of a sparse-set world shrinks its component stores to zero.
"""

from harness.runner import Suite
from ecs.world import World
from ecs.storage import StorageBackend
from ecs.sparse_backend import SparseSetBackend
from ecs.archetype import ArchetypeBackend
from ecs.bitset_backend import BitsetBackend
from ecs.reactive_backend import ReactiveBackend
from ecs.naive_backend import NaiveBackend
from ecs.chunked_backend import ChunkedBackend
from ecs.component import ComponentType
from ecs.entity import Entity


@fieldwise_init
struct A(ComponentType):
    comptime ID: Int = 0
    var x: Int
    var y: Int


@fieldwise_init
struct B(ComponentType):
    comptime ID: Int = 1
    var v: Int


def _fill[Bk: StorageBackend](mut w: World[Bk], n: Int) -> List[Entity]:
    var es = List[Entity]()
    for i in range(n):
        var e = w.spawn1(A(i, i))
        if i % 2 == 0:
            w.set(e, B(i))
        es.append(e)
    return es^


def _row[Bk: StorageBackend](name: String, mut s: Suite) raises:
    var w0 = World[Bk]()
    var empty = w0.storage_bytes()
    var w1 = World[Bk]()
    _ = _fill(w1, 1000)
    var b1 = w1.storage_bytes()
    var w2 = World[Bk]()
    _ = _fill(w2, 2000)
    var b2 = w2.storage_bytes()
    var ratio = Float64(b2 - empty) / Float64(b1 - empty)
    print("  " + name + ": empty", empty, " 1000 entities", b1, "bytes (", (b1 - empty) // 1000, "per entity )  2000:", b2, " ratio", ratio)
    s.check(b1 - empty >= 20000, name + ": at least the component payload (20000 bytes)")
    s.check(abs(ratio - 2) < 0.04, name + ": 2000 entities cost twice 1000 (2 %)")


def main() raises:
    var s = Suite("ecs_bytes")
    _row[SparseSetBackend[A, B]]("sparse-set", s)
    _row[ArchetypeBackend[A, B]]("archetype", s)
    _row[BitsetBackend[A, B]]("bitset", s)
    _row[ReactiveBackend[A, B]]("reactive", s)
    _row[NaiveBackend[A, B]]("naive", s)
    _row[ChunkedBackend[A, B]]("chunked", s)

    var w = World[SparseSetBackend[A, B]]()
    var es = _fill(w, 1000)
    var before = w.storage_bytes()
    for e in es:
        w.despawn(e)
    var after = w.storage_bytes()
    print("  sparse-set, all 1000 despawned:", before, "->", after, "bytes")
    s.check(after < before - 20000, "despawning every entity frees the component stores (the sparse index stays)")
    s.finish()
