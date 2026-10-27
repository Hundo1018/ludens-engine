"""Fixed workload for the cachegrind probe of the rules-vs-OOP timing (ROADMAP 17.70 (b)).

Same buff + DoT subset as `benchmarks/bench_rules_oop.mojo`. Compile-time knobs:
`-D VARIANT=0` runs `gameplay/rules.mojo` (value struct per actor),
`-D VARIANT=1` runs `oop/rules_oop.mojo` (object per actor); `-D N=` population,
`-D TICKS=` tick count (0 gives setup only, so the difference of two runs is the
tick loop). `scripts/rules_icount.py` drives this under cachegrind.

Predictions, written before the run:

  P1. Instructions per actor-tick (Ir difference / (N * 400)) are within 1.5x
      between the variants at N = 1000 and N = 10000. The per-tick work is a
      short loop over two effects in both; the rules side copies a 10-field
      `EffectDef` per effect, which is a few extra loads.
  P2. Data-cache read misses per actor-tick (D1mr difference / (N * 400)) for
      the rules variant are at least 2x the OOP variant at N = 10000. The
      rules actor is a wider struct with its effect list behind a second
      pointer, so one actor touches more cache lines per tick.
  P3. At N = 1000 the working set fits in L2 for both variants and the D1mr
      ratio is below 2x.
  P4. With the last-level cache forced to 1 MiB (the host's L2; `--ll` in
      `scripts/rules_icount.py`), the rules variant's LL read misses per
      actor-tick at N = 10000 are at least 3x its value at N = 1000, and at
      least 2x the OOP variant's at N = 10000. Rules actors span about 3 MB
      against about 0.6 MB for OOP, so rules spills the 1 MiB level and OOP
      does not.

Measured (2026-10-27, default LL = host L3 33 MiB): Ir per actor-tick rules 87 vs OOP 114
(P1 holds, ratio 0.76); D1mr 2.3 vs 1.7 flat in N (P2 fails: ratio 1.36, not 2x; P3 holds);
DLmr about 0 at both N, so the default LL does not see the spill. P4 is run next.
"""

from std.sys import get_defined_int
from std.benchmark import keep
from gameplay.rules import FX, OP_ADD, OP_MUL, KIND_DURATION, KIND_PERIODIC, STACK_REFRESH, Actor, Rules, EffectDef
from oop.rules_oop import OopCharacter

comptime HEALTH = 0
comptime SPEED = 1


def run_rules(n: Int, ticks: Int) raises -> Int:
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
    for _ in range(ticks):
        r.step(actors)
    var acc = 0
    for k in range(n):
        acc += actors[k].attrs.value(SPEED)
    return acc


def run_oop(n: Int, ticks: Int) -> Int:
    var objs = List[OopCharacter]()
    for _ in range(n):
        var o = OopCharacter(5 * FX, 100 * FX)
        o.add_buff(200, 0, 300)
        o.add_dot(-10 * FX, 30, 0, 300)
        objs.append(o^)
    for t in range(1, ticks + 1):
        for k in range(n):
            objs[k].advance(t)
    var acc = 0
    for k in range(n):
        acc += objs[k].speed()
    return acc


def main() raises:
    comptime variant = get_defined_int["VARIANT", 0]()
    comptime n = get_defined_int["N", 1000]()
    comptime ticks = get_defined_int["TICKS", 400]()
    var acc = 0
    if variant == 0:
        acc = run_rules(n, ticks)
    else:
        acc = run_oop(n, ticks)
    keep(acc)
