# tier: integration
"""Object-oriented baseline against the data-oriented rules (ROADMAP 17.70 (b)).

`oop/rules_oop.mojo` implements the duration-buff and periodic-damage subset
of `gameplay/rules.mojo` with objects that own their effects. The same
workload runs through both on 500 actors (base speed 5.000, health 100): a
+20 % speed buff for 300 ticks and a 10-per-30-tick damage effect for 300
ticks, applied at tick 0, run for 400 ticks.

Predictions, written before the run:

  * Speed at tick 150 is 6.000 and at tick 301 is 5.000, for every actor, in
    both implementations.
  * Health ends at 0 and dead for every actor in both (10 hits of 10 = 100).
  * Parity: every actor's speed (at both checkpoints), health and dead flag
    agree between the two implementations: 0 mismatches.

This is a parity check only. No timing is taken here; the paradigm cost
comparison needs a benchmark run, which is not in this commit.

Measured: recorded in the roadmap progress note after the run.
"""

from harness.runner import Suite
from gameplay.rules import (
    FX, OP_ADD, OP_MUL, KIND_DURATION, KIND_PERIODIC, STACK_REFRESH,
    Actor, Rules, EffectDef,
)
from oop.rules_oop import OopCharacter

comptime HEALTH = 0
comptime SPEED = 1
comptime N = 500
comptime TICKS = 400


def main() raises:
    var s = Suite("rules_oop")

    var r = Rules(HEALTH)
    var buff = r.define(EffectDef(KIND_DURATION, 300, 0, SPEED, OP_MUL, 200, 0, 0, STACK_REFRESH, 1))
    var dot = r.define(EffectDef(KIND_PERIODIC, 300, 30, HEALTH, OP_ADD, -10 * FX, 0, 0, STACK_REFRESH, 1))

    var actors = List[Actor]()
    var objs = List[OopCharacter]()
    for _ in range(N):
        var a = Actor(3, 2)
        a.attrs.set_base(HEALTH, 100 * FX)
        a.attrs.set_range(HEALTH, 0, 100 * FX)
        a.attrs.set_base(SPEED, 5 * FX)
        _ = r.apply(a, buff, 1)
        _ = r.apply(a, dot, 2)
        actors.append(a^)
        var o = OopCharacter(5 * FX, 100 * FX)
        o.add_buff(200, 0, 300)
        o.add_dot(-10 * FX, 30, 0, 300)
        objs.append(o^)

    var speed_mismatch = 0
    var speed150_rules = 0
    var speed150_oop = 0
    var speed301_rules = 0
    var speed301_oop = 0
    for t in range(1, TICKS + 1):
        r.step(actors)
        for k in range(N):
            objs[k].advance(t)
        if t == 150 or t == 301:
            for k in range(N):
                if actors[k].attrs.value(SPEED) != objs[k].speed():
                    speed_mismatch += 1
        if t == 150:
            speed150_rules = actors[0].attrs.value(SPEED)
            speed150_oop = objs[0].speed()
        if t == 301:
            speed301_rules = actors[0].attrs.value(SPEED)
            speed301_oop = objs[0].speed()

    var mismatch = speed_mismatch
    var hp_rules_end = 0
    for k in range(N):
        if actors[k].attrs.value(HEALTH) != objs[k].health:
            mismatch += 1
        if actors[k].dead != objs[k].dead:
            mismatch += 1
        hp_rules_end += actors[k].attrs.value(HEALTH)
    print("  speed 150 rules", speed150_rules, "oop", speed150_oop, "  speed 301 rules", speed301_rules, "oop", speed301_oop)
    print("  health end (sum over", N, "actors) rules", hp_rules_end, "  mismatched fields", mismatch)
    s.check(speed150_rules == 6 * FX and speed150_oop == 6 * FX, "speed at tick 150 is 6.000 in both")
    s.check(speed301_rules == 5 * FX and speed301_oop == 5 * FX, "speed at tick 301 is 5.000 in both")
    s.check(hp_rules_end == 0, "every actor ends at health 0 (rules)")
    s.check(mismatch == 0, "rules and OOP agree on health and dead flag for all actors")
    s.finish()
