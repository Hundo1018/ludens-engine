# tier: integration
"""Componentised rules subset (ROADMAP 17.70 (a)), `gameplay/rules_ecs.mojo`.

The same workload as `tests/test_rules_oop.mojo`: 500 actors (base speed 5.000,
health 100), a +20 % speed buff for 300 ticks and a 10-per-30-tick damage effect
for 300 ticks, run for 400 ticks. The reference is `gameplay/rules.mojo`
(`Rules`, value struct per actor). The componentised variant runs on each of
the six `StorageBackend` implementations, instantiated over the four components
`Life`, `Stat`, `Buff`, `Dot`.

Predictions, written before the run:

  1. Each backend agrees with `Rules` on every actor: speed at tick 150, 300
     and 301, final health, and the dead flag. 0 mismatches per backend.
  2. The reference values hold on the componentised run as well: speed 6.000
     at tick 150, 5.000 at tick 300 and 301 (the buff ends at tick 300, where
     `Rules` removes it), health 0 and dead for every actor.
  2b. Mutation check: with the buff expiry changed from `>=` to `>`, the
     tick-301 checkpoint alone does not detect it (the buff is gone by 301 either
     way). The tick-300 checkpoint is what detects it. The first run of this test
     did not have the tick-300 checkpoint; it was added before any reported result.
  3. The six backends give identical summaries (the seam's parity rule).

Scope: parity on the one-buff, one-DoT subset only. Tags, stacking modes,
grants / immunity, resistance, shield and serialisation are not implemented on
components and are not tested here.

Measured (2026-10-27): 12/12 with the tick-300 checkpoint. The first version (ticks 150 and 301 only)
also had 12 checks and passed; it could not detect the mutation in 2b, so the checkpoint was added. Every
backend: 0 of 2500 fields mismatched. Mutation (buff expiry `>=` changed to `>`, rebuilt): every backend 500 mismatches, the
module restored, 12/12 again.
"""

from harness.runner import Suite
from gameplay.rules import (
    FX, OP_ADD, OP_MUL, KIND_DURATION, KIND_PERIODIC, STACK_REFRESH,
    Actor, Rules, EffectDef,
)
from gameplay.rules_ecs import Life, Stat, Buff, Dot, spawn_actor, tick_once, speed, health, is_dead
from ecs.entity import Entity
from ecs.world import World
from ecs.storage import StorageBackend
from ecs.sparse_backend import SparseSetBackend
from ecs.archetype import ArchetypeBackend
from ecs.bitset_backend import BitsetBackend
from ecs.chunked_backend import ChunkedBackend
from ecs.naive_backend import NaiveBackend
from ecs.reactive_backend import ReactiveBackend

comptime HEALTH = 0
comptime SPEED = 1
comptime N = 500
comptime TICKS = 400
comptime CHECK_A = 150
comptime CHECK_C = 300
comptime CHECK_B = 301


def reference() raises -> List[Int]:
    """Per actor: speed at CHECK_A, CHECK_C, CHECK_B, final health, dead (0 / 1)."""
    var r = Rules(HEALTH)
    var buff = r.define(EffectDef(KIND_DURATION, 300, 0, SPEED, OP_MUL, 200, 0, 0, STACK_REFRESH, 1))
    var dot = r.define(EffectDef(KIND_PERIODIC, 300, 30, HEALTH, OP_ADD, -10 * FX, 0, 0, STACK_REFRESH, 1))
    var actors = List[Actor]()
    for _ in range(N):
        var a = Actor(3, 2)
        a.attrs.set_base(HEALTH, 100 * FX)
        a.attrs.set_range(HEALTH, 0, 100 * FX)
        a.attrs.set_base(SPEED, 5 * FX)
        _ = r.apply(a, buff, 1)
        _ = r.apply(a, dot, 2)
        actors.append(a^)
    var out = List[Int]()
    var sa = List[Int]()
    var sc = List[Int]()
    var sb = List[Int]()
    for t in range(1, TICKS + 1):
        r.step(actors)
        if t == CHECK_A:
            for k in range(N):
                sa.append(actors[k].attrs.value(SPEED))
        if t == CHECK_C:
            for k in range(N):
                sc.append(actors[k].attrs.value(SPEED))
        if t == CHECK_B:
            for k in range(N):
                sb.append(actors[k].attrs.value(SPEED))
    for k in range(N):
        out.append(sa[k])
        out.append(sc[k])
        out.append(sb[k])
        out.append(actors[k].attrs.value(HEALTH))
        out.append(1 if actors[k].dead else 0)
    return out^


def run_ecs[B: StorageBackend]() raises -> List[Int]:
    """The same per-actor summary as `reference()`, from the componentised run."""
    var w = World[B]()
    var ents = List[Entity]()
    for _ in range(N):
        ents.append(spawn_actor(w, 5 * FX, 100 * FX, 200, 300, 10 * FX, 30, 300))
    var out = List[Int]()
    var sa = List[Int]()
    var sc = List[Int]()
    var sb = List[Int]()
    for t in range(1, TICKS + 1):
        tick_once(w, t)
        if t == CHECK_A:
            for k in range(N):
                sa.append(speed(w, ents[k]))
        if t == CHECK_C:
            for k in range(N):
                sc.append(speed(w, ents[k]))
        if t == CHECK_B:
            for k in range(N):
                sb.append(speed(w, ents[k]))
    for k in range(N):
        out.append(sa[k])
        out.append(sc[k])
        out.append(sb[k])
        out.append(health(w, ents[k]))
        out.append(1 if is_dead(w, ents[k]) else 0)
    return out^


def mismatches(a: List[Int], b: List[Int]) -> Int:
    var m = 0
    for i in range(len(a)):
        if a[i] != b[i]:
            m += 1
    return m


def main() raises:
    var s = Suite("rules_ecs")
    var want = reference()

    var sets = List[List[Int]]()
    var names = List[String]()
    sets.append(run_ecs[SparseSetBackend[Life, Stat, Buff, Dot]]())
    names.append("sparse set")
    sets.append(run_ecs[ArchetypeBackend[Life, Stat, Buff, Dot]]())
    names.append("archetype")
    sets.append(run_ecs[BitsetBackend[Life, Stat, Buff, Dot]]())
    names.append("bitset")
    sets.append(run_ecs[ChunkedBackend[Life, Stat, Buff, Dot]]())
    names.append("chunked")
    sets.append(run_ecs[NaiveBackend[Life, Stat, Buff, Dot]]())
    names.append("naive")
    sets.append(run_ecs[ReactiveBackend[Life, Stat, Buff, Dot]]())
    names.append("reactive")

    var first_speed_ok = True
    for k in range(N):
        if want[5 * k] != 6 * FX or want[5 * k + 1] != 5 * FX or want[5 * k + 2] != 5 * FX:
            first_speed_ok = False
    print("  reference speed at 150 / 300 / 301 (actor 0):", want[0], want[1], want[2], "  health end:", want[3], "  dead:", want[4])
    s.check(first_speed_ok, "reference: speed 6.000 at tick 150 and 5.000 at ticks 300 and 301 for every actor")

    for i in range(len(sets)):
        var m = mismatches(sets[i], want)
        print("  backend", names[i], " mismatched fields vs Rules:", m, "  of", len(want))
        s.eqi(m, 0, "backend " + names[i] + " agrees with Rules on every actor")
    for i in range(1, len(sets)):
        s.eqi(mismatches(sets[i], sets[0]), 0, "backend " + names[i] + " matches " + names[0])
    s.finish()
