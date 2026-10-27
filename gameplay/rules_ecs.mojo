"""Componentised rules subset (ROADMAP 17.70 (a)): the duration buff and the periodic
damage of `gameplay/rules.mojo`, stored as ECS components on any `StorageBackend`.

Components are `ImplicitlyCopyable`, so a component cannot hold a list. Each
entity therefore has one buff slot and one DoT slot (`Buff`, `Dot`), where
`Rules` keeps an unbounded `List[EffectInst]`. The variant claims parity only on
the workload with one buff and one DoT per actor. See
`docs/design/17.70-rules-componentisation.md`, "Layout".

Fixed point and arithmetic match `Rules`: speed is
`base * (FX + mul) // FX` (the buff is an OP_MUL in permille), and damage
clamps health at 0 and records death once. The tick order matches
`Rules.step`: buff expiry, then the DoT (periodic damage, then expiry). The
buff and the DoT touch different components, so their order does not change
any output.
"""

from ecs.component import ComponentType
from ecs.entity import Entity
from ecs.storage import StorageBackend
from ecs.world import World
from gameplay.rules import FX


@fieldwise_init
struct Life(ComponentType):
    comptime ID: Int = 0
    var hp: Int
    var dead: Int


@fieldwise_init
struct Stat(ComponentType):
    comptime ID: Int = 1
    var base: Int


@fieldwise_init
struct Buff(ComponentType):
    comptime ID: Int = 2
    var mul: Int
    var expires: Int
    var live: Int


@fieldwise_init
struct Dot(ComponentType):
    comptime ID: Int = 3
    var amount: Int
    var period: Int
    var next: Int
    var expires: Int
    var live: Int


def spawn_actor[B: StorageBackend](
    mut w: World[B], base: Int, hp: Int, buff_mul: Int, buff_duration: Int,
    dot_amount: Int, dot_period: Int, dot_duration: Int,
) -> Entity:
    """One actor with a duration buff and a periodic damage effect, both applied
    at tick 0 (the same timing as `Rules.apply` at tick 0)."""
    var e = w.spawn()
    w.set(e, Life(hp, 0))
    w.set(e, Stat(base))
    w.set(e, Buff(buff_mul, buff_duration, 1))
    w.set(e, Dot(dot_amount, dot_period, dot_period, dot_duration, 1))
    return e


def tick_once[B: StorageBackend](mut w: World[B], tick: Int):
    """Advance one tick. `tick` is the tick being entered (the caller counts up
    from 1, as `Rules.step` does after its own increment)."""
    for e in w.query1[Buff]():
        var b = w.get[Buff](e)
        if b.live != 0 and tick >= b.expires:
            b.live = 0
            w.set(e, b)
    for e in w.query1[Dot]():
        var d = w.get[Dot](e)
        if d.live == 0:
            continue
        if tick >= d.next and (d.expires < 0 or tick <= d.expires):
            var l = w.get[Life](e)
            if l.dead == 0 and d.amount > 0:
                var lost = min(d.amount, max(l.hp, 0))
                l.hp -= lost
                if l.hp <= 0:
                    l.dead = 1
                w.set(e, l)
            d.next = tick + d.period
        if d.expires >= 0 and tick >= d.expires:
            d.live = 0
        w.set(e, d)


def speed[B: StorageBackend](w: World[B], e: Entity) -> Int:
    """Current speed: base scaled by the live buff, as `Attributes.value` computes it."""
    var s = w.get[Stat](e)
    var b = w.get[Buff](e)
    var mul = b.mul if b.live != 0 else 0
    return s.base * (FX + mul) // FX


def health[B: StorageBackend](w: World[B], e: Entity) -> Int:
    return w.get[Life](e).hp


def is_dead[B: StorageBackend](w: World[B], e: Entity) -> Bool:
    return w.get[Life](e).dead != 0
