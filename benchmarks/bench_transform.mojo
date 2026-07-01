"""Transform propagation benchmark: full recompute vs dirty-incremental.

The same hierarchy (a binary tree of N entities) is driven for F frames; some
entities are moved each frame, then world matrices are propagated. Two regimes
show the crossover:
  - "all": every node moves (including the root) -> both paths rebuild everything,
    so dirty only pays its bookkeeping overhead and full is competitive.
  - "leaves": only leaf nodes (the upper half of a binary tree) move -> each dirty
    node is a subtree of one, so dirty rebuilds ~half and pulls ahead of full.
Only the propagation call is timed (hierarchy build + dirtying are excluded).
Run with: `mojo run -I build benchmarks/bench_transform.mojo`.
"""

from std.benchmark import keep
from harness.bench import BenchTable, now
from ecs.world import World
from ecs.storage import StorageBackend
from ecs.sparse_backend import SparseSetBackend
from ecs.entity import Entity
from ecs.transform import Transform, Parent
from ecs.hierarchy import Hierarchy
from ecs.transform_systems import propagate_full, propagate_dirty
from geometry.vec import Vec3, Real


def build_forest[B: StorageBackend](mut w: World[B], n: Int) -> List[Entity]:
    var es = List[Entity]()
    for i in range(n):
        var e = w.spawn()
        w.set(e, Transform.at(Vec3(Real(i % 10), 0, 0)))
        if i > 0:
            w.set(e, Parent(es[(i - 1) // 2].id))
        es.append(e)
    return es^


def bench_one[B: StorageBackend, use_dirty: Bool](
    mut w: World[B], es: List[Entity], frames: Int, dirty_first: Int
) -> Int:
    var total = 0
    for _f in range(frames):
        for i in range(dirty_first, len(es)):
            var t = w.get[Transform](es[i])
            w.set(es[i], t.with_translation(Vec3(Real(i), Real(_f), 0)))
        var h = Hierarchy.build(w)
        var t0 = now()
        comptime if use_dirty:
            propagate_dirty(w, h)
        else:
            propagate_full(w, h)
        var t1 = now()
        total += t1 - t0
        keep(w.get[Transform](es[0]).world.get(0, 0))
    return total


def main() raises:
    var table = BenchTable("Transform propagation — full vs dirty")
    comptime N = 4000
    var frames = 30
    var ops = N * frames

    # "all": every node moves (root included) -> both rebuild the whole tree
    var w1 = World[SparseSetBackend[Transform, Parent]]()
    var e1 = build_forest(w1, N)
    table.add("full", N, "move-all", bench_one[use_dirty=False](w1, e1, frames, 0), ops)

    var w2 = World[SparseSetBackend[Transform, Parent]]()
    var e2 = build_forest(w2, N)
    table.add("dirty", N, "move-all", bench_one[use_dirty=True](w2, e2, frames, 0), ops)

    # "leaves": only the upper half (leaf nodes) move -> dirty rebuilds ~half
    var w3 = World[SparseSetBackend[Transform, Parent]]()
    var e3 = build_forest(w3, N)
    table.add("full", N, "move-leaves", bench_one[use_dirty=False](w3, e3, frames, N // 2), ops)

    var w4 = World[SparseSetBackend[Transform, Parent]]()
    var e4 = build_forest(w4, N)
    table.add("dirty", N, "move-leaves", bench_one[use_dirty=True](w4, e4, frames, N // 2), ops)

    table.print_report()
