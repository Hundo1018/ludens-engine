"""Chunked (paged) columns vs one growable column.

`ChunkedBackend` and `NaiveBackend` are deliberately the same design apart from
ONE thing: how a component column grows. Naive keeps a single `List` that is
reallocated and copied when it outgrows capacity; chunked appends a fixed-size
page and never moves existing rows. Everything else — dense id indexing, the
`Optional` cell, the generational lifecycle, the query shape — is identical, so
the difference between these two rows isolates the storage layout and nothing
else. The archetype and sparse rows are context, not the comparison.

Three axes, because chunking is a trade rather than a win:

  growth    — spawn N entities from empty. This is where a reallocating column
              pays: it copies everything it has, repeatedly, on the way up.
  iterate   — for_each2 over the whole world. This is where chunking pays:
              every access goes through a page lookup, and the walk cannot be
              one flat pointer run.
  churn     — despawn and respawn a slice every frame, the structural workload
              the crossover study calls W4.

The page count is printed alongside: it is the quantity the chunking argument
is really about, and it is bounded by N/CHUNK_ROWS by construction rather than
by an allocator's doubling schedule.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from harness.bench import BenchTable
from ecs.world import World
from ecs.storage import StorageBackend
from ecs.component import ComponentType
from ecs.entity import Entity
from ecs.naive_backend import NaiveBackend
from ecs.chunked_backend import ChunkedBackend
from ecs.archetype import ArchetypeBackend
from ecs.sparse_backend import SparseSetBackend

comptime REPS = 3


@fieldwise_init
struct Pos(ComponentType):
    comptime ID: Int = 0
    var x: Int
    var y: Int


@fieldwise_init
struct Vel(ComponentType):
    comptime ID: Int = 1
    var dx: Int
    var dy: Int


def bench_growth[B: StorageBackend](mut t: BenchTable, name: String, n: Int) raises:
    var best = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        var w = World[B]()
        for i in range(n):
            var e = w.spawn2(Pos(i, i), Vel(1, 1))
            keep(e.id)
        var dt = Int(perf_counter_ns()) - t0
        if dt < best:
            best = dt
    t.add(name + " growth", n, "spawn", best, n)


def bench_iterate[B: StorageBackend](mut t: BenchTable, name: String, n: Int, frames: Int) raises:
    var w = World[B]()
    for i in range(n):
        _ = w.spawn2(Pos(i, i), Vel(1, 1))

    @parameter
    def move(mut p: Pos, v: Vel):
        p.x += v.dx
        p.y += v.dy

    var best = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        for _ in range(frames):
            w.for_each2[Pos, Vel, move]()
        var dt = Int(perf_counter_ns()) - t0
        if dt < best:
            best = dt
    t.add(name + " iterate", n, "entity", best, n * frames)


def bench_churn[B: StorageBackend](mut t: BenchTable, name: String, n: Int, frames: Int) raises:
    var best = Int.MAX
    for _ in range(REPS):
        var w = World[B]()
        var ents = List[Entity]()
        for i in range(n):
            ents.append(w.spawn2(Pos(i, i), Vel(1, 1)))
        var t0 = Int(perf_counter_ns())
        for f in range(frames):
            # despawn a rotating tenth, then refill it
            var lo = (f * (n // 10)) % n
            for k in range(n // 10):
                w.despawn(ents[(lo + k) % n])
            for k in range(n // 10):
                ents[(lo + k) % n] = w.spawn2(Pos(k, k), Vel(1, 1))
        var dt = Int(perf_counter_ns()) - t0
        if dt < best:
            best = dt
    t.add(name + " churn", n, "op", best, frames * (n // 10) * 2)


def main() raises:
    var t = BenchTable("Chunked (paged) columns vs one growable column")
    comptime N = 60000
    comptime FRAMES = 10

    bench_growth[NaiveBackend[Pos, Vel]](t, "naive (growable)", N)
    bench_growth[ChunkedBackend[Pos, Vel]](t, "chunked (paged)", N)
    bench_growth[ArchetypeBackend[Pos, Vel]](t, "archetype", N)
    bench_growth[SparseSetBackend[Pos, Vel]](t, "sparse", N)

    bench_iterate[NaiveBackend[Pos, Vel]](t, "naive (growable)", N, FRAMES)
    bench_iterate[ChunkedBackend[Pos, Vel]](t, "chunked (paged)", N, FRAMES)
    bench_iterate[ArchetypeBackend[Pos, Vel]](t, "archetype", N, FRAMES)

    bench_churn[NaiveBackend[Pos, Vel]](t, "naive (growable)", N, FRAMES)
    bench_churn[ChunkedBackend[Pos, Vel]](t, "chunked (paged)", N, FRAMES)
    bench_churn[ArchetypeBackend[Pos, Vel]](t, "archetype", N, FRAMES)

    t.print_report()

    # Page accounting: bounded by N/CHUNK_ROWS per column, by construction.
    var cw = ChunkedBackend[Pos, Vel]()
    for i in range(N):
        var e = cw.spawn()
        cw.set(e, Pos(i, i))
        cw.set(e, Vel(1, 1))
    print("  chunked pages allocated for N=" + String(N) + ":", cw.page_allocs())
