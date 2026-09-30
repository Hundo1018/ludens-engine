# tier: integration
"""Entity pools (ROADMAP 17.37, docs/design/wave-a-services.md).

Why `integration` and not `component` (`test_backend_parity`'s tier, which
this file otherwise mirrors in shape): `ecs.pool` records capacity events
through `diag.counters` (ARCHITECTURE.md §2's "capacity/budget overflow" row
requires this), so a pool test's one-hop span is genuinely `{diag, ecs}`, not
just `ecs` -- `Pool` really does wire those two packages together in
production code, unlike `test_backend_parity`, which touches nothing outside
`ecs`. Declaring `component` with an override would be papering over that;
the mechanical tier is the honest one here.

Cases (testing standard v3):
  ordinary     -- acquire returns template values equal to a fresh spawn's;
                  `Pool.active_query2` sees exactly the acquired + non-pool
                  entities, never the still-released pool slots (raw
                  `World.query2` still sees them all -- a documented limit of
                  building this on a trait with no query-exclusion filter,
                  see ecs/pool.mojo's module docstring).
  integration  -- the SAME scenario run identically across all six
                  `StorageBackend` implementations (the seam), exactly
                  `test_backend_parity`'s cross-backend comparison shape.
  extreme      -- pool exhaustion (fixed cap refuses + counts;
                  unbounded grows + counts), release of a foreign (non-pool)
                  entity, double release, stale handle held across a
                  release/re-acquire cycle.

Double release / foreign-entity release / a truly dead handle are
`debug_assert`-guarded programmer errors (ARCHITECTURE.md §2), and a firing
`debug_assert` terminates the whole process with no way to catch it and keep
recording `Suite` checks -- the same reason `test_diag_invariant.mojo` never
calls `invariant_finite` with a value that should trip it. This file instead
exercises the underlying, non-asserting detection predicates `Pool.is_valid`
and `Pool.owns` that `release` itself asserts on. The assert firing was
verified by hand with a throwaway probe (double release under
`-D ASSERT=all` -> `Assert Error: Pool.release: stale handle ...` and a
non-zero exit), matching `test_diag_invariant`'s documented verification
method; see the 17.37 report for the transcript.
"""

from harness.runner import Suite
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
from diag.counters import POOL_GROWN, POOL_EXHAUSTED


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


comptime DID = 2
"""The `Disabled` marker's component id within this file's component set --
chosen by the test author like any other component (component.mojo's
contract), 2 because Position/Velocity already claim 0/1."""


def apply_template[B: StorageBackend](mut w: World[B], e: Entity):
    w.set(e, Position(11, 22))
    w.set(e, Velocity(1, 1))


def run_scenario[B: StorageBackend]() -> List[Int]:
    """Ordinary acquire/release + the exhaustion/foreign-entity/stale-handle
    extreme cases, all against a fixed-capacity pool. Returns an
    order-independent summary so every backend can be compared exactly, as
    `test_backend_parity.run_scenario` does."""
    var w = World[B]()
    var pool = Pool[B, DID](cap=3)
    pool.prime(w, 3, apply_template[B])

    # --- ordinary: acquire matches a freshly spawned entity's template values ---
    var h = pool.acquire(w, apply_template[B]).value()
    var fresh = w.spawn()
    w.set(fresh, Position(11, 22))
    w.set(fresh, Velocity(1, 1))

    var pos = w.get[Position](h.entity)
    var vel = w.get[Velocity](h.entity)
    var parity_ok = 1 if (pos.x == 11 and pos.y == 22 and vel.dx == 1 and vel.dy == 1) else 0

    # raw World.query2 sees every template-shaped entity regardless of
    # Disabled (documented limitation): 3 primed (1 acquired + 2 still
    # released) + 1 fresh = 4. Pool.active_query2 excludes the 2 released
    # ones: acquired + fresh = 2.
    var raw_count = len(w.query2[Position, Velocity]())
    var active_count = len(pool.active_query2[Position, Velocity](w))

    # --- release drops it back out of the active query ---
    pool.release(w, h)
    var active_after_release = len(pool.active_query2[Position, Velocity](w))

    # --- re-acquire reuses the SAME slot; the old handle is now stale ---
    var h2 = pool.acquire(w, apply_template[B]).value()
    var reused_id = 1 if h2.entity.id == h.entity.id else 0
    var old_handle_now_invalid = 0 if pool.is_valid(h) else 1
    var new_handle_valid = 1 if pool.is_valid(h2) else 0

    # --- exhaustion: cap=3, h2 + the other 2 primed slots fill it exactly ---
    var h3 = pool.acquire(w, apply_template[B]).value()
    var h4 = pool.acquire(w, apply_template[B]).value()
    var refused = pool.acquire(w, apply_template[B])
    var exhausted_is_none = 1 if not refused else 0
    var exhausted_counted = 1 if pool.counters.get(POOL_EXHAUSTED) >= 1 else 0
    _ = h3
    _ = h4

    # --- foreign entity: never issued by this pool ---
    var foreign = w.spawn()
    var foreign_not_owned = 0 if pool.owns(foreign) else 1

    var out = List[Int]()
    out.append(parity_ok)
    out.append(raw_count)
    out.append(active_count)
    out.append(active_after_release)
    out.append(reused_id)
    out.append(old_handle_now_invalid)
    out.append(new_handle_valid)
    out.append(exhausted_is_none)
    out.append(exhausted_counted)
    out.append(foreign_not_owned)
    return out^


def run_growth[B: StorageBackend]() -> List[Int]:
    """Extreme case, the other half of "grow or refuse": an unbounded
    (`cap=0`) pool grows instead of refusing, and the growth is counted."""
    var w = World[B]()
    var pool = Pool[B, DID](cap=0)
    pool.prime(w, 1, apply_template[B])

    var h1 = pool.acquire(w, apply_template[B]).value()  # the primed slot
    var h2 = pool.acquire(w, apply_template[B]).value()  # free list empty -> grows
    var grew_new_id = 1 if h2.entity.id != h1.entity.id else 0
    var grown_counted = 1 if pool.counters.get(POOL_GROWN) >= 1 else 0
    var total_slots = pool.total_slots()

    var out = List[Int]()
    out.append(grew_new_id)
    out.append(grown_counted)
    out.append(total_slots)
    return out^


def _compare(mut s: Suite, name: String, want: List[Int], got: List[Int]):
    var labels = List[String]()
    labels.append("acquire matches a fresh spawn's template values")
    labels.append("raw World.query2 count (sees disabled entities too)")
    labels.append("Pool.active_query2 count (excludes disabled)")
    labels.append("active count drops after release")
    labels.append("re-acquire reuses the released slot's id")
    labels.append("old handle invalid after release+re-acquire (stale)")
    labels.append("new handle valid")
    labels.append("acquire on an exhausted fixed-cap pool returns None")
    labels.append("exhaustion is counted (diag.counters.POOL_EXHAUSTED)")
    labels.append("release of a foreign entity: Pool.owns is False")
    s.eqi(len(got), len(want), name + ": summary length matches")
    for i in range(len(want)):
        s.eqi(got[i], want[i], name + ": " + labels[i])


def _compare_growth(mut s: Suite, name: String, want: List[Int], got: List[Int]):
    var labels = List[String]()
    labels.append("growth acquires a brand new id")
    labels.append("growth is counted (diag.counters.POOL_GROWN)")
    labels.append("total_slots reflects the grown pool")
    s.eqi(len(got), len(want), name + ": growth summary length matches")
    for i in range(len(want)):
        s.eqi(got[i], want[i], name + ": " + labels[i])


def main() raises:
    var s = Suite("pool")

    var want = List[Int]()
    want.append(1)  # parity_ok
    want.append(4)  # raw_count
    want.append(2)  # active_count
    want.append(1)  # active_after_release
    want.append(1)  # reused_id
    want.append(1)  # old_handle_now_invalid
    want.append(1)  # new_handle_valid
    want.append(1)  # exhausted_is_none
    want.append(1)  # exhausted_counted
    want.append(1)  # foreign_not_owned

    _compare(s, "sparse", want, run_scenario[SparseSetBackend[Position, Velocity, Disabled[DID]]]())
    _compare(s, "archetype", want, run_scenario[ArchetypeBackend[Position, Velocity, Disabled[DID]]]())
    _compare(s, "bitset", want, run_scenario[BitsetBackend[Position, Velocity, Disabled[DID]]]())
    _compare(s, "reactive", want, run_scenario[ReactiveBackend[Position, Velocity, Disabled[DID]]]())
    _compare(s, "naive", want, run_scenario[NaiveBackend[Position, Velocity, Disabled[DID]]]())
    _compare(s, "chunked", want, run_scenario[ChunkedBackend[Position, Velocity, Disabled[DID]]]())

    var gwant = List[Int]()
    gwant.append(1)
    gwant.append(1)
    gwant.append(2)

    _compare_growth(s, "sparse", gwant, run_growth[SparseSetBackend[Position, Velocity, Disabled[DID]]]())
    _compare_growth(s, "archetype", gwant, run_growth[ArchetypeBackend[Position, Velocity, Disabled[DID]]]())
    _compare_growth(s, "bitset", gwant, run_growth[BitsetBackend[Position, Velocity, Disabled[DID]]]())
    _compare_growth(s, "reactive", gwant, run_growth[ReactiveBackend[Position, Velocity, Disabled[DID]]]())
    _compare_growth(s, "naive", gwant, run_growth[NaiveBackend[Position, Velocity, Disabled[DID]]]())
    _compare_growth(s, "chunked", gwant, run_growth[ChunkedBackend[Position, Velocity, Disabled[DID]]]())

    s.finish()
