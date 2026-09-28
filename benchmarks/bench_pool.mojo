"""Entity pools (ROADMAP 17.37): churn throughput, `Pool.acquire`/`release`
vs plain `World.spawn`+set+`despawn`, across all six `ecs.StorageBackend`
implementations. N is the churn REPEAT count, not a live-entity count (each
cycle nets back to zero entities): N=1 is the "otherwise the wide rows are
suspect" control (docs/design/wave-a-services.md §17.37) -- the pool pays
per-call bookkeeping (a `SparseSet` id lookup, an epoch check, one `Disabled`
component toggle) that a single bare spawn/despawn for a 3-component template
does not, so it must read slightly SLOWER there; N=1e3..1e5 are the "wide"
rows where the pool amortizes ahead by skipping the archetype
migration/id-recycling `spawn`+`despawn` repeats on every single cycle.

Run under the shared benchmark lane (single-lane on this machine, per the
design note's preamble):

    flock /tmp/claude-1000/bench.lock pixi run mojo run -I build benchmarks/bench_pool.mojo
"""

from ecs.entity import Entity
from ecs.component import ComponentType
from ecs.world import World
from ecs.storage import StorageBackend
from ecs.sparse_backend import SparseSetBackend
from ecs.archetype import ArchetypeBackend
from ecs.bitset_backend import BitsetBackend
from ecs.reactive_backend import ReactiveBackend
from ecs.naive_backend import NaiveBackend
from ecs.chunked_backend import ChunkedBackend
from ecs.pool import Pool, PooledEntity, Disabled
from harness.bench import BenchTable, measure


@fieldwise_init
struct Position(ComponentType):
    comptime ID: Int = 0
    var x: Int
    var y: Int


@fieldwise_init
struct Velocity(ComponentType):
    comptime ID: Int = 1
    var dx: Int
    var dy: Int


@fieldwise_init
struct Payload(ComponentType):
    comptime ID: Int = 2
    var v: Int


comptime DID = 3
"""The `Disabled` marker's component id -- Position/Velocity/Payload claim 0-2."""


def apply_template[B: StorageBackend](mut w: World[B], e: Entity):
    w.set(e, Position(1, 1))
    w.set(e, Velocity(1, 1))
    w.set(e, Payload(1))


def bench_spawn_despawn[B: StorageBackend](mut table: BenchTable, variant: String, n: Int):
    """A fresh `World[B]` is built INSIDE the timed closure (paid on every
    warmup call and every rep, not hoisted out) so this is symmetric with
    `bench_pool` below, which must pay its one-time `prime()` the same way for
    the N=1 control to mean anything -- see that function's docstring."""

    def run_n() {imm n}:
        var w = World[B]()
        for _ in range(n):
            var e = w.spawn()
            w.set(e, Position(1, 1))
            w.set(e, Velocity(1, 1))
            w.set(e, Payload(1))
            w.despawn(e)

    var ns = measure(run_n, 3, 20)
    table.add(variant, n, "churn(spawn/despawn)", ns, n)


def bench_pool[B: StorageBackend](mut table: BenchTable, variant: String, n: Int):
    """The one-time `Pool.prime` cost is paid INSIDE the timed closure, same
    as `bench_spawn_despawn` pays `World()` construction inside its own timed
    closure -- so at N=1 the reported ns/op is "one prime + one acquire/
    release", not just the steady-state acquire/release cost. That is the
    whole point of the N=1 control (docs/design/wave-a-services.md §17.37):
    a pool used exactly once pays prime for nothing and should read slower
    than a bare spawn/despawn; only as N grows does prime's fixed cost get
    divided across enough cycles for the per-template-write savings
    (ecs/pool.mojo's `acquire` docstring: overwrite-in-place vs the archetype
    relocation a fresh `spawn`+set(...)+set(...)+set(...) pays every cycle)
    to outweigh it."""

    def run_n() {imm n}:
        var w = World[B]()
        var pool = Pool[B, DID](cap=0)
        pool.prime(w, 1, apply_template[B])
        for _ in range(n):
            var h = pool.acquire(w, apply_template[B]).value()
            pool.release(w, h)

    var ns = measure(run_n, 3, 20)
    table.add(variant + " (pool)", n, "churn(acquire/release, incl. 1x prime)", ns, n)


def bench_all[B: StorageBackend](mut table: BenchTable, variant: String):
    var ns = List[Int]()
    ns.append(1)
    ns.append(1_000)
    ns.append(10_000)
    ns.append(100_000)
    for i in range(len(ns)):
        bench_spawn_despawn[B](table, variant, ns[i])
        bench_pool[B](table, variant, ns[i])


def main() raises:
    var table = BenchTable("Entity pools -- acquire/release vs spawn/despawn churn (N=1..1e5)")
    bench_all[SparseSetBackend[Position, Velocity, Payload, Disabled[DID]]](table, "sparse")
    bench_all[ArchetypeBackend[Position, Velocity, Payload, Disabled[DID]]](table, "archetype")
    bench_all[BitsetBackend[Position, Velocity, Payload, Disabled[DID]]](table, "bitset")
    bench_all[ReactiveBackend[Position, Velocity, Payload, Disabled[DID]]](table, "reactive")
    bench_all[NaiveBackend[Position, Velocity, Payload, Disabled[DID]]](table, "naive")
    bench_all[ChunkedBackend[Position, Velocity, Payload, Disabled[DID]]](table, "chunked")
    table.print_report()
