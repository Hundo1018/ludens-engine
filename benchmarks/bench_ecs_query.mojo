"""ROADMAP 17.77: native `Without` filter vs the old query + `has` filter,
and `changed[C]` vs a full scan over a hand-kept dirty flag.

N = 20000 entities with Position; a share s of them also carry Disabled
(the `Pool` marker). Per backend and s in {1 %, 50 %, 99 %}:
  * filter: `select(with Position, without Disabled)` vs `query1[Position]`
    followed by `has[Disabled]` on every match (the pre-17.77 `Pool` path);
  * change: 1 % of entities get a new Position this tick; `changed[Position]`
    vs scanning every Position for a `dirty` field set by hand.
Times are microseconds per query (median of 7).

Second table: `for_each3[Position, Vel, Mass]` (x += v * m) over N
entities that all carry the three, vs `query3` then get / set per entity.
"""

from std.time import perf_counter_ns
from ecs.world import World
from ecs.storage import StorageBackend, Filter
from ecs.sparse_backend import SparseSetBackend
from ecs.archetype import ArchetypeBackend
from ecs.bitset_backend import BitsetBackend
from ecs.reactive_backend import ReactiveBackend
from ecs.naive_backend import NaiveBackend
from ecs.chunked_backend import ChunkedBackend
from ecs.component import ComponentType
from ecs.entity import Entity

comptime N = 20000


@fieldwise_init
struct Position(ComponentType):
    comptime ID: Int = 0
    var x: Int
    var dirty: Int


@fieldwise_init
struct Disabled(ComponentType):
    comptime ID: Int = 1


@fieldwise_init
struct Vel(ComponentType):
    comptime ID: Int = 2
    var v: Int


@fieldwise_init
struct Mass(ComponentType):
    comptime ID: Int = 3
    var m: Int


def _push(mut p: Position, v: Vel, m: Mass):
    p.x += v.v * m.m


def _row3[Bk: StorageBackend](name: String) raises:
    var w = World[Bk]()
    var es = List[Entity]()
    for i in range(N):
        var e = w.spawn1(Position(i, 0))
        w.set(e, Vel(i % 5))
        w.set(e, Mass(1 + i % 3))
        es.append(e)
    var tf = List[Int]()
    var tq = List[Int]()
    for _ in range(7):
        var t0 = Int(perf_counter_ns())
        w.for_each3[Position, Vel, Mass](_push)
        var t1 = Int(perf_counter_ns())
        var q = w.query3[Position, Vel, Mass]()
        for e in q:
            var p = w.get[Position](e)
            p.x += w.get[Vel](e).v * w.get[Mass](e).m
            w.set(e, p)
        var t2 = Int(perf_counter_ns())
        tf.append(t1 - t0)
        tq.append(t2 - t1)
    var check = 0
    for e in es:
        check += w.get[Position](e).x
    print("|", name, "|", _median(tf^) // 1000, "|", _median(tq^) // 1000, "|", check, "|")


def _median(var xs: List[Int]) -> Int:
    sort(xs)
    return xs[len(xs) // 2]


def _row[Bk: StorageBackend](name: String) raises:
    for share in [1, 50, 99]:
        var w = World[Bk]()
        w.track_changes()
        var es = List[Entity]()
        for i in range(N):
            var e = w.spawn1(Position(i, 0))
            es.append(e)
            if (i * 100) // N < share:
                w.set(e, Disabled())
        var f = Filter().with_[Position]().without[Disabled]()
        var tn = List[Int]()
        var to = List[Int]()
        var cnt_n = 0
        var cnt_o = 0
        for _ in range(7):
            var t0 = Int(perf_counter_ns())
            cnt_n = len(w.select(f))
            var t1 = Int(perf_counter_ns())
            var raw = w.query1[Position]()
            var c = 0
            for k in range(len(raw)):
                if not w.has[Disabled](raw[k]):
                    c += 1
            cnt_o = c
            var t2 = Int(perf_counter_ns())
            tn.append(t1 - t0)
            to.append(t2 - t1)
        if cnt_n != cnt_o:
            raise Error("bench_ecs_query: filter results differ")
        # change detection: 1 % rewritten this tick
        var since = w.advance_tick()
        for i in range(0, N, 100):
            w.set(es[i], Position(-i, 1))
        var tc = List[Int]()
        var ts = List[Int]()
        var nc = 0
        var ns = 0
        for _ in range(7):
            var t0 = Int(perf_counter_ns())
            nc = len(w.changed[Position](since))
            var t1 = Int(perf_counter_ns())
            var all = w.query1[Position]()
            var d = 0
            for k in range(len(all)):
                if w.get[Position](all[k]).dirty == 1:
                    d += 1
            ns = d
            var t2 = Int(perf_counter_ns())
            tc.append(t1 - t0)
            ts.append(t2 - t1)
        if nc != ns:
            raise Error("bench_ecs_query: change counts differ")
        print("|", name, "|", share, "% |", cnt_n, "|", _median(tn^) // 1000, "|", _median(to^) // 1000, "|", nc, "|", _median(tc^) // 1000, "|", _median(ts^) // 1000, "|")


def main() raises:
    print("### ECS filters and change detection (17.77), N = 20000\n")
    print("| backend | disabled | matches | select without (us) | query + has (us) | changed | changed[C] (us) | scan dirty flag (us) |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|")
    _row[SparseSetBackend[Position, Disabled]]("sparse-set")
    _row[ArchetypeBackend[Position, Disabled]]("archetype")
    _row[BitsetBackend[Position, Disabled]]("bitset")
    _row[ReactiveBackend[Position, Disabled]]("reactive")
    _row[NaiveBackend[Position, Disabled]]("naive")
    _row[ChunkedBackend[Position, Disabled]]("chunked")
    print("")
    print("### for_each3 vs query3 + get / set (17.77), N = 20000\n")
    print("| backend | for_each3 (us) | query3 + get/set (us) | checksum |")
    print("|---|---:|---:|---:|")
    _row3[SparseSetBackend[Position, Disabled, Vel, Mass]]("sparse-set")
    _row3[ArchetypeBackend[Position, Disabled, Vel, Mass]]("archetype")
    _row3[BitsetBackend[Position, Disabled, Vel, Mass]]("bitset")
    _row3[ReactiveBackend[Position, Disabled, Vel, Mass]]("reactive")
    _row3[NaiveBackend[Position, Disabled, Vel, Mass]]("naive")
    _row3[ChunkedBackend[Position, Disabled, Vel, Mass]]("chunked")
    print("")
