"""Example 16 — an entity pool for high-churn projectiles (ROADMAP 17.37).

The production-style caller `ecs.pool` needs (architecture law v3, "接上專案"):
a small bullet-hell-shaped sim where projectiles are fired every frame and
expire after a fixed lifetime, cycling through the SAME pre-built entities
via `acquire`/`release` instead of paying `spawn`/`despawn` on every shot.
Run:

    pixi run mojo run -I build examples/16_entity_pool.mojo
"""

from ecs.entity import Entity
from ecs.component import ComponentType
from ecs.world import World
from ecs.storage import StorageBackend
from ecs.sparse_backend import SparseSetBackend
from ecs.pool import Pool, PooledEntity, Disabled


@fieldwise_init
struct Position(ComponentType):
    comptime ID: Int = 0
    var x: Float64
    var y: Float64


@fieldwise_init
struct Velocity(ComponentType):
    comptime ID: Int = 1
    var dx: Float64
    var dy: Float64


@fieldwise_init
struct Lifetime(ComponentType):
    comptime ID: Int = 2
    var ticks_left: Int


comptime DID = 3
comptime B = SparseSetBackend[Position, Velocity, Lifetime, Disabled[DID]]


def apply_bullet_template(mut w: World[B], e: Entity):
    """A freshly acquired bullet starts at the origin, at rest, expired
    (`fire` below immediately overwrites all three) -- this is the template
    every pre-spawned slot carries before its first `acquire`."""
    w.set(e, Position(0, 0))
    w.set(e, Velocity(0, 0))
    w.set(e, Lifetime(0))


def fire(mut w: World[B], mut pool: Pool[B, DID], mut live: List[PooledEntity], x: Float64, y: Float64, dx: Float64, dy: Float64):
    var maybe = pool.acquire(w, apply_bullet_template)
    if not maybe:
        print("  pool exhausted -- shot dropped")
        return
    var h = maybe.value()
    w.set(h.entity, Position(x, y))
    w.set(h.entity, Velocity(dx, dy))
    w.set(h.entity, Lifetime(4))
    live.append(h)


def main() raises:
    var w = World[B]()
    var pool = Pool[B, DID](cap=8)
    pool.prime(w, 8, apply_bullet_template)
    var live = List[PooledEntity]()

    for frame in range(6):
        # A cannon fires two shots a frame -- more churn than the cap can
        # hold live at once once lifetimes start expiring, exercising both
        # acquire (reuse) and the pool staying within its fixed capacity.
        fire(w, pool, live, 0, 0, 1, 0)
        fire(w, pool, live, 0, 0, 0, 1)

        # advance + expire: move every acquired bullet, release the ones
        # whose lifetime just ran out (returned to the pool, NOT despawned).
        var still_live = List[PooledEntity]()
        for i in range(len(live)):
            var h = live[i]
            var p = w.get[Position](h.entity)
            var v = w.get[Velocity](h.entity)
            var lt = w.get[Lifetime](h.entity)
            w.set(h.entity, Position(p.x + v.dx, p.y + v.dy))
            var left = lt.ticks_left - 1
            if left <= 0:
                pool.release(w, h)
            else:
                w.set(h.entity, Lifetime(left))
                still_live.append(h)
        live = still_live^

        var active = pool.active_query2[Position, Velocity](w)
        print(
            "frame", frame, "- live bullets:", len(live),
            "active (pool-visible) entities:", len(active),
            "world entity_count:", w.entity_count(),
        )

    print("done: world never despawned a bullet after the initial", pool.total_slots(), "were primed")
