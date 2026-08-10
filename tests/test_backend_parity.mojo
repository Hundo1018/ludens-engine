"""The swappability contract: an identical scenario produces identical results
on the sparse-set backend and the archetype backend."""

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
struct Frozen(ComponentType):
    comptime ID: Int = 2
    var flag: Int


# A fixed scenario written once against the StorageBackend interface; returns an
# order-independent summary so the two backends can be compared exactly.
def run_scenario[B: StorageBackend]() -> List[Int]:
    var w = World[B]()
    var ents = List[Entity]()
    for _ in range(10):
        ents.append(w.spawn())

    # give every entity a Position; even ids also get Velocity; multiples of 3 Frozen
    for i in range(10):
        w.set(ents[i], Position(i, i * 2))
        if i % 2 == 0:
            w.set(ents[i], Velocity(1, 1))
        if i % 3 == 0:
            w.set(ents[i], Frozen(1))

    # despawn entity 4 and remove Velocity from entity 6
    w.despawn(ents[4])
    w.remove[Velocity](ents[6])

    # run a movement system: pos += vel
    var movers = w.query2[Position, Velocity]()
    for i in range(len(movers)):
        var e = movers[i]
        var p = w.get[Position](e)
        var v = w.get[Velocity](e)
        w.set(e, Position(p.x + v.dx, p.y + v.dy))

    # order-independent summary
    var sum_x = 0
    var p_all = w.query1[Position]()
    for i in range(len(p_all)):
        sum_x += w.get[Position](p_all[i]).x

    var out = List[Int]()
    out.append(w.entity_count())
    out.append(len(w.query1[Position]()))
    out.append(len(w.query2[Position, Velocity]()))
    out.append(len(w.query3[Position, Velocity, Frozen]()))
    out.append(sum_x)
    return out^


def _compare(
    mut s: Suite, name: String, sparse: List[Int], other: List[Int]
):
    var labels = List[String]()
    labels.append("entity_count")
    labels.append("count[P]")
    labels.append("count[P,V]")
    labels.append("count[P,V,F]")
    labels.append("sum_x")
    s.eqi(len(other), len(sparse), name + ": summary length matches")
    for i in range(len(sparse)):
        s.eqi(other[i], sparse[i], name + " parity: " + labels[i])


def recycle_scenario[B: StorageBackend]() -> List[Int]:
    """Entity-handle lifecycle: despawn, respawn into the recycled id, and
    check that the OLD handle is dead while the new one is alive.

    This is the semantics an ECS handle exists to provide — an id alone cannot
    distinguish "the entity I stored" from "whatever now occupies that slot",
    which is why `Entity` carries a generation. Every backend must agree, and
    for a long time only the archetype one actually recycled: the others
    always stamped generation 0, so a reused id silently resurrected stale
    handles. Summary is order-independent so it can be compared across
    backends."""
    var w = World[B]()
    var a = w.spawn2(Position(1, 1), Velocity(0, 0))
    var b = w.spawn2(Position(2, 2), Velocity(0, 0))
    _ = b
    w.despawn(a)

    var old_dead = 0 if w.is_alive(a) else 1
    # respawn: a recycling backend hands the same id back with a bumped gen
    var c = w.spawn2(Position(3, 3), Velocity(0, 0))
    var reused_id = 1 if c.id == a.id else 0
    var new_alive = 1 if w.is_alive(c) else 0
    # the crucial one: the stale handle must NOT be revived by the respawn
    var stale_still_dead = 0 if w.is_alive(a) else 1
    var gen_advanced = 1 if (c.id != a.id or c.gen > a.gen) else 0

    var out = List[Int]()
    out.append(old_dead)
    out.append(reused_id)
    out.append(new_alive)
    out.append(stale_still_dead)
    out.append(gen_advanced)
    out.append(w.entity_count())
    return out^


def _chunk_release_scenario() -> List[Int]:
    """Page release: the property a growable column cannot have.

    Fills a wide id range, kills everything in the LOW half, compacts, and
    checks that (a) memory actually came back, (b) the surviving half is
    completely unaffected, and (c) a released page can be taken again. (b) is
    the one that matters — handing back a page whose neighbours are still in
    use is exactly how this goes wrong, and a leak-free-but-corrupting release
    would still look like a win on the memory number alone."""
    var w = World[ChunkedBackend[Position, Velocity, Frozen]]()
    var ents = List[Entity]()
    for i in range(4096):
        ents.append(w.spawn2(Position(i, i), Velocity(1, 1)))

    var held_full = w.backend.cells_held()
    # kill the low half only
    for i in range(2048):
        w.despawn(ents[i])
    w.backend.compact()
    var held_after = w.backend.cells_held()

    # survivors must be intact
    var survivors_ok = 1
    for i in range(2048, 4096):
        if not w.is_alive(ents[i]):
            survivors_ok = 0
        elif w.get[Position](ents[i]).x != i:
            survivors_ok = 0

    # a released page must be usable again
    var e2 = w.spawn2(Position(77, 77), Velocity(2, 2))
    var reuse_ok = 1 if (w.is_alive(e2) and w.get[Position](e2).x == 77) else 0

    var out = List[Int]()
    out.append(1 if held_after < held_full else 0)
    out.append(survivors_ok)
    out.append(reuse_ok)
    out.append(w.entity_count())
    return out^


def _recycle_check(
    mut su: Suite,
    name: String,
    got: List[Int],
    want: List[Int],
    labels: List[String],
) raises:
    # module level: a nested def cannot infer the capture convention of an
    # outer `var` on this nightly
    for i in range(len(want)):
        su.eqi(got[i], want[i], name + " recycle: " + labels[i])


def main() raises:
    var s = Suite("backend_parity")

    # The sparse-set backend is the reference; every other backend must produce
    # the identical order-independent summary for the same scenario.
    var sparse = run_scenario[SparseSetBackend[Position, Velocity, Frozen]]()
    var arch = run_scenario[ArchetypeBackend[Position, Velocity, Frozen]]()
    var bitset = run_scenario[BitsetBackend[Position, Velocity, Frozen]]()
    var reactive = run_scenario[ReactiveBackend[Position, Velocity, Frozen]]()
    var naive = run_scenario[NaiveBackend[Position, Velocity, Frozen]]()
    var chunked = run_scenario[ChunkedBackend[Position, Velocity, Frozen]]()

    _compare(s, "archetype", sparse, arch)
    _compare(s, "bitset", sparse, bitset)
    _compare(s, "reactive", sparse, reactive)
    _compare(s, "naive", sparse, naive)
    _compare(s, "chunked", sparse, chunked)

    # sanity: the scenario isn't trivially empty
    s.eqi(sparse[0], 9, "9 entities remain (10 - 1 despawned)")

    # --- generational-handle parity across every backend ---
    var r_sparse = recycle_scenario[SparseSetBackend[Position, Velocity, Frozen]]()
    var r_arch = recycle_scenario[ArchetypeBackend[Position, Velocity, Frozen]]()
    var r_bitset = recycle_scenario[BitsetBackend[Position, Velocity, Frozen]]()
    var r_react = recycle_scenario[ReactiveBackend[Position, Velocity, Frozen]]()
    var r_naive = recycle_scenario[NaiveBackend[Position, Velocity, Frozen]]()
    var r_chunk = recycle_scenario[ChunkedBackend[Position, Velocity, Frozen]]()

    var rlabels = List[String]()
    rlabels.append("despawned handle is dead")
    rlabels.append("respawn reuses the freed id")
    rlabels.append("new handle is alive")
    rlabels.append("stale handle stays dead after reuse")
    rlabels.append("generation advanced on reuse")
    rlabels.append("entity count")

    var want = List[Int]()
    want.append(1)
    want.append(1)
    want.append(1)
    want.append(1)
    want.append(1)
    want.append(2)

    _recycle_check(s, "sparse", r_sparse, want, rlabels)
    _recycle_check(s, "archetype", r_arch, want, rlabels)
    _recycle_check(s, "bitset", r_bitset, want, rlabels)
    _recycle_check(s, "reactive", r_react, want, rlabels)
    _recycle_check(s, "naive", r_naive, want, rlabels)
    _recycle_check(s, "chunked", r_chunk, want, rlabels)

    # --- chunked page release ---
    var cr = _chunk_release_scenario()
    s.eqi(cr[0], 1, "compact() actually returns memory")
    s.eqi(cr[1], 1, "surviving entities in other pages are untouched")
    s.eqi(cr[2], 1, "a released page can be reused")
    s.eqi(cr[3], 2049, "entity count after killing half and respawning one")

    s.finish()
