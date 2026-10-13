# tier: integration
"""ECS expressiveness (ROADMAP 17.77): filters, change detection,
resources, deferred structural changes.

  1. Ordinary: on all six backends, after one build script (spawns,
     despawns, id reuse, removes), `select` for (With A, Without B),
     (With A, Any of C / D), four `with_` types, and `without` only returns
     the same sorted entity set as a brute-force `has` filter, and the six
     agree; `changed` / `added` report only this tick's writes; a resource
     round-trips; `SetBuffer.remove` / `despawn` / `spawn` replay in
     recording order.
  2. Integration: `Pool.active_query2` (now `Without[Disabled]`) equals the
     old `query2` + `has` filter; a recycled id is not reported as changed
     before its new owner writes; removal clears `added`.
  3. Extreme: an empty world; all match; none match; the same type in
     `with_` and `without` (empty); a `with_` type outside the pack (empty)
     and a `without` type outside it (ignored); 64+ entities so the bitset
     backend spans two words; nine types in 300 distinct archetype
     signatures. (Duplicate IDs and > 63 types are compile errors:
     `test_ecs_pack_guard`.)
"""

from harness.runner import Suite
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
from ecs.commands import SetBuffer
from ecs.pool import Pool, Disabled


@fieldwise_init
struct A(ComponentType):
    comptime ID: Int = 0
    var v: Int


@fieldwise_init
struct B(ComponentType):
    comptime ID: Int = 1
    var v: Int


@fieldwise_init
struct C(ComponentType):
    comptime ID: Int = 2
    var v: Int


@fieldwise_init
struct D(ComponentType):
    comptime ID: Int = 3
    var v: Int


@fieldwise_init
struct Gravity(ComponentType):
    comptime ID: Int = 4
    var g: Int


@fieldwise_init
struct E(ComponentType):
    comptime ID: Int = 6
    var v: Int


@fieldwise_init
struct F(ComponentType):
    comptime ID: Int = 7
    var v: Int


@fieldwise_init
struct G(ComponentType):
    comptime ID: Int = 8
    var v: Int


@fieldwise_init
struct NotInPack(ComponentType):
    comptime ID: Int = 9
    var v: Int




def _sorted_ids(es: List[Entity]) -> List[Int]:
    var ids = List[Int]()
    for e in es:
        ids.append(e.id * 1000 + e.gen)
    sort(ids)
    return ids^


def _build[Bk: StorageBackend](mut w: World[Bk], n: Int) -> List[Entity]:
    var es = List[Entity]()
    for i in range(n):
        var e = w.spawn()
        es.append(e)
        if i % 2 == 0:
            w.set(e, A(i))
        if i % 3 == 0:
            w.set(e, B(i))
        if i % 4 == 0:
            w.set(e, C(i))
        if i % 6 == 0:
            w.set(e, D(i))
    # despawn and recycle, remove a component
    for i in range(0, n, 11):
        w.despawn(es[i])
    for i in range(0, n, 11):
        var e = w.spawn()
        w.set(e, A(-i))
        w.set(e, D(-i))
    for i in range(1, n, 13):
        if w.is_alive(es[i]) and w.has[B](es[i]):
            w.remove[B](es[i])
    return es^


def _filters() -> List[Filter]:
    var fs = List[Filter]()
    fs.append(Filter().with_[A]().without[B]())
    fs.append(Filter().with_[A]().any[C]().any[D]())
    fs.append(Filter().with_[A]().with_[B]().with_[C]().with_[D]())
    fs.append(Filter().without[A]())
    fs.append(Filter().with_[A]().without[A]())
    fs.append(Filter().with_[A]().with_[NotInPack]())
    fs.append(Filter().with_[B]().without[NotInPack]())
    return fs^


def _brute[Bk: StorageBackend](w: World[Bk], all: List[Entity], f: Int) -> List[Entity]:
    var out = List[Entity]()
    for e in all:
        if not w.is_alive(e):
            continue
        var a = w.has[A](e)
        var b = w.has[B](e)
        var c = w.has[C](e)
        var d = w.has[D](e)
        var ok: Bool
        if f == 0:
            ok = a and not b
        elif f == 1:
            ok = a and (c or d)
        elif f == 2:
            ok = a and b and c and d
        elif f == 3:
            ok = not a
        elif f == 4 or f == 5:
            ok = False
        else:
            ok = b
        if ok:
            out.append(e)
    return out^


def _live[Bk: StorageBackend](w: World[Bk], n: Int) -> List[Entity]:
    """Every live entity, found by probing ids 0..n+16 with each generation."""
    var out = List[Entity]()
    for id in range(n + 16):
        for g in range(4):
            if w.is_alive(Entity(id, g)):
                out.append(Entity(id, g))
    return out^


def _run[Bk: StorageBackend](n: Int) -> List[List[Int]]:
    var w = World[Bk]()
    _ = _build(w, n)
    var live = _live(w, n)
    var fs = _filters()
    var out = List[List[Int]]()
    for k in range(len(fs)):
        var got = _sorted_ids(w.select(fs[k]))
        var want = _sorted_ids(_brute(w, live, k))
        if got != want:
            got.append(-999)  # marks a mismatch with the brute filter
        out.append(got^)
    return out^


def _same(a: List[List[Int]], b: List[List[Int]]) -> Bool:
    if len(a) != len(b):
        return False
    for k in range(len(a)):
        if a[k] != b[k]:
            return False
    return True


def _ok(r: List[List[Int]]) -> Bool:
    for k in range(len(r)):
        if len(r[k]) > 0 and r[k][len(r[k]) - 1] == -999:
            return False
    return True


def main() raises:
    var s = Suite("ecs_query")
    for n in [40, 130]:
        var r0 = _run[SparseSetBackend[A, B, C, D, Gravity, Disabled[5]]](n)
        var r1 = _run[ArchetypeBackend[A, B, C, D, Gravity, Disabled[5]]](n)
        var r2 = _run[BitsetBackend[A, B, C, D, Gravity, Disabled[5]]](n)
        var r3 = _run[ReactiveBackend[A, B, C, D, Gravity, Disabled[5]]](n)
        var r4 = _run[NaiveBackend[A, B, C, D, Gravity, Disabled[5]]](n)
        var r5 = _run[ChunkedBackend[A, B, C, D, Gravity, Disabled[5]]](n)
        print("  n", n, ": with A without B", len(r0[0]), " A and (C or D)", len(r0[1]), " A B C D", len(r0[2]), " without A", len(r0[3]))
        s.check(_ok(r0) and _ok(r1) and _ok(r2) and _ok(r3) and _ok(r4) and _ok(r5), "n " + String(n) + ": every backend's select equals the brute has-filter")
        s.check(_same(r0, r1) and _same(r0, r2) and _same(r0, r3) and _same(r0, r4) and _same(r0, r5), "n " + String(n) + ": six backends agree")
        s.check(len(r0[4]) == 0 and len(r0[5]) == 0, "n " + String(n) + ": with A and without A, or a with_ type outside the pack: empty")

    # ---- change detection ---------------------------------------------------
    var w = World[SparseSetBackend[A, B, C, D, Gravity, Disabled[5]]]()
    w.track_changes()
    var es = List[Entity]()
    for i in range(10):
        es.append(w.spawn1(A(i)))
    var t1 = w.advance_tick()
    w.set(es[2], A(20))
    w.set(es[5], A(50))
    w.set(es[7], B(7))
    var ch = _sorted_ids(w.changed[A](t1))
    var ad = _sorted_ids(w.added[B](t1))
    var ad_a = w.added[A](t1)
    print("  changed A since t1:", len(ch), " added B:", len(ad), " added A:", len(ad_a))
    s.check(ch == _sorted_ids([es[2], es[5]]), "changed[A] reports only this tick's sets")
    s.check(ad == _sorted_ids([es[7]]) and len(ad_a) == 0, "added[B] reports the new component, added[A] nothing")
    var t2 = w.advance_tick()
    s.check(len(w.changed[A](t2)) == 0, "next tick: nothing changed yet")
    w.despawn(es[5])
    var r = w.spawn()
    w.set(r, B(1))
    s.check(len(w.changed[A](t1)) == 1, "a recycled id is not reported for its previous owner's writes")
    w.set(r, A(9))
    s.check(len(w.changed[A](t2)) == 1 and len(w.added[A](t2)) == 1, "its own write is")
    w.remove[A](r)
    s.check(len(w.added[A](t2)) == 0, "removal clears added")
    # beyond the log window (8 ticks) the full-scan fallback gives the same answer
    var t3 = w.advance_tick()
    w.set(es[3], A(33))
    var recent = _sorted_ids(w.changed[A](t3))
    for _ in range(12):
        _ = w.advance_tick()
    var old_scan = _sorted_ids(w.changed[A](t3))
    s.check(recent == _sorted_ids([es[3]]) and old_scan == recent, "a since older than the log window falls back to the scan, same result")

    # ---- resources ------------------------------------------------------------
    var count0 = w.entity_count()
    s.check(not w.has_resource[Gravity](), "no resource before set")
    w.set_resource(Gravity(-10))
    w.set_resource(Gravity(-9))
    s.check(w.resource[Gravity]().g == -9 and w.entity_count() == count0 + 1, "resource round-trips; one reserved entity")
    var raised = False
    try:
        _ = w.resource[D]()
    except:
        raised = True
    s.check(raised, "missing resource raises")

    # ---- deferred structural changes ------------------------------------------
    var wb = World[ArchetypeBackend[A, B, C, D, Gravity, Disabled[5]]]()
    var xs = List[Entity]()
    for i in range(6):
        xs.append(wb.spawn2(A(i), B(i)))
    var buf = SetBuffer[A, B, C, D, Gravity, Disabled[5]]()
    var movers = wb.query2[A, B]()
    for e in movers:
        if wb.get[A](e).v % 2 == 0:
            buf.remove[B](e)  # during iteration: deferred
    buf.despawn(xs[5])
    var p = buf.spawn()
    buf.set(p, C(77))
    buf.set(p, A(78))
    buf.remove[A](p)
    buf.set(xs[5], C(1))  # dead by then: dropped
    s.check(len(wb.query2[A, B]()) == 6, "nothing applied before the sync point")
    var made = buf.apply(wb)
    var has_b = len(wb.query2[A, B]())
    print("  after apply: A+B", has_b, " spawned", len(made), " spawned has C", wb.has[C](made[0]), " has A", wb.has[A](made[0]))
    s.check(has_b == 2, "deferred remove[B] applied to the even ones (0, 2, 4), despawn removed 5")
    s.check(len(made) == 1 and wb.get[C](made[0]).v == 77 and not wb.has[A](made[0]), "deferred spawn + set + remove in recording order")
    s.check(not wb.is_alive(xs[5]), "deferred despawn applied; the later set on it dropped")

    # ---- pool ---------------------------------------------------------------------
    var wp = World[BitsetBackend[A, B, C, D, Gravity, Disabled[5]]]()
    var pool = Pool[BitsetBackend[A, B, C, D, Gravity, Disabled[5]], 5]()
    var hs = List[Entity]()
    for i in range(70):
        var e = wp.spawn2(A(i), B(i))
        hs.append(e)
        if i % 4 == 0:
            wp.set(e, Disabled[5]())
    var old = List[Entity]()
    var raw = wp.query2[A, B]()
    for e in raw:
        if not wp.has[Disabled[5]](e):
            old.append(e)
    var act = pool.active_query2[A, B](wp)
    print("  pool: active", len(act), "of", len(raw))
    s.check(_sorted_ids(act) == _sorted_ids(old), "Pool.active_query2 via Without == the old has filter (64+ entities, two bitset words)")

    # ---- extremes -------------------------------------------------------------------
    # nine types, 300 distinct signatures (more than the old 256 archetype-table hint)
    var wa = World[ArchetypeBackend[A, B, C, D, Gravity, Disabled[5], E, F, G]]()
    var want_a = 0
    var want_ab = 0
    for m in range(1, 301):
        var e = wa.spawn()
        if m & 1: wa.set(e, A(m))
        if m & 2: wa.set(e, B(m))
        if m & 4: wa.set(e, C(m))
        if m & 8: wa.set(e, D(m))
        if m & 16: wa.set(e, Gravity(m))
        if m & 32: wa.set(e, Disabled[5]())
        if m & 64: wa.set(e, E(m))
        if m & 128: wa.set(e, F(m))
        if m & 256: wa.set(e, G(m))
        if m & 1:
            want_a += 1
            if not (m & 2):
                want_ab += 1
    var got_a = len(wa.query1[A]())
    var got_ab = len(wa.select(Filter().with_[A]().without[B]()))
    print("  300 signatures over 9 types: with A", got_a, "/", want_a, " A without B", got_ab, "/", want_ab)
    s.check(got_a == want_a and got_ab == want_ab, "300 archetype signatures (9 types): queries still exact")
    var we = World[NaiveBackend[A, B, C, D, Gravity, Disabled[5]]]()
    s.check(len(we.select(Filter().with_[A]())) == 0 and len(we.select(Filter().without[A]())) == 0, "empty world: nothing")
    for i in range(5):
        _ = we.spawn1(A(i))
    s.check(len(we.select(Filter().with_[A]())) == 5 and len(we.select(Filter().with_[B]())) == 0, "all match / none match")
    s.finish()
