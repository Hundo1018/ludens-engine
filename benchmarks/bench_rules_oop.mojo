"""Rules timing comparison (ROADMAP 17.70 (a), (b)): value-struct `gameplay/rules.mojo`,
the object baseline `oop/rules_oop.mojo`, and the componentised variant
`gameplay/rules_ecs.mojo` on the archetype backend. All three implement the
same subset (a +20 % speed buff and a 10-per-30-tick damage effect, 400 ticks).
Parity is in `tests/test_rules_oop.mojo` and `tests/test_rules_ecs.mojo`; this
file only times them.

Only the tick loop is timed (setup and the effect application are outside).
Each row is one population size; the unit is one actor-tick. Run with:
`mojo run -I build benchmarks/bench_rules_oop.mojo`.
"""

from std.benchmark import keep
from gameplay.rules import FX, OP_ADD, OP_MUL, KIND_DURATION, KIND_PERIODIC, STACK_REFRESH, Actor, Rules, EffectDef
from oop.rules_oop import OopCharacter
from gameplay.rules_ecs import Life, Stat, Buff, Dot, spawn_actor, tick_once
from ecs.world import World
from ecs.archetype import ArchetypeBackend
from ecs.entity import Entity
from harness.bench import BenchTable, now

comptime HEALTH = 0
comptime SPEED = 1
comptime TICKS = 400


def run_rules(n: Int) raises -> Int:
    var r = Rules(HEALTH)
    var buff = r.define(EffectDef(KIND_DURATION, 300, 0, SPEED, OP_MUL, 200, 0, 0, STACK_REFRESH, 1))
    var dot = r.define(EffectDef(KIND_PERIODIC, 300, 30, HEALTH, OP_ADD, -10 * FX, 0, 0, STACK_REFRESH, 1))
    var actors = List[Actor]()
    for _ in range(n):
        var a = Actor(3, 2)
        a.attrs.set_base(HEALTH, 100 * FX)
        a.attrs.set_range(HEALTH, 0, 100 * FX)
        a.attrs.set_base(SPEED, 5 * FX)
        _ = r.apply(a, buff, 1)
        _ = r.apply(a, dot, 2)
        actors.append(a^)
    var t0 = now()
    for _ in range(TICKS):
        r.step(actors)
    var t1 = now()
    var acc = 0
    for k in range(n):
        acc += actors[k].attrs.value(SPEED)
    keep(acc)
    return t1 - t0


def run_oop(n: Int) -> Int:
    var objs = List[OopCharacter]()
    for _ in range(n):
        var o = OopCharacter(5 * FX, 100 * FX)
        o.add_buff(200, 0, 300)
        o.add_dot(-10 * FX, 30, 0, 300)
        objs.append(o^)
    var t0 = now()
    for t in range(1, TICKS + 1):
        for k in range(n):
            objs[k].advance(t)
    var t1 = now()
    var acc = 0
    for k in range(n):
        acc += objs[k].speed()
    keep(acc)
    return t1 - t0


def run_ecs(n: Int) raises -> Int:
    var w = World[ArchetypeBackend[Life, Stat, Buff, Dot]]()
    var ents = List[Entity]()
    for _ in range(n):
        ents.append(spawn_actor(w, 5 * FX, 100 * FX, 200, 300, 10 * FX, 30, 300))
    var t0 = now()
    for t in range(1, TICKS + 1):
        tick_once(w, t)
    var t1 = now()
    keep(len(ents))
    return t1 - t0


def main() raises:
    var t = BenchTable("Rules layouts: buff + DoT, 400 ticks, value struct vs object vs components (17.70 (a), (b))")
    for n in [1000, 5000, 10000, 20000]:
        var ops = n * TICKS
        t.add("rules (value struct) N=" + String(n), n, "actor-tick", run_rules(n), ops)
        t.add("oop (object) N=" + String(n), n, "actor-tick", run_oop(n), ops)
        t.add("ecs (archetype backend) N=" + String(n), n, "actor-tick", run_ecs(n), ops)
    t.print_report()
