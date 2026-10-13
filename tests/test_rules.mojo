# tier: unit
"""Gameplay rules: attributes, tags, effects, damage (ROADMAP 17.70).

  1. Ordinary: a +20 % speed buff for 300 ticks raises 5.000 to 6.000 and
     ends exactly at tick 300; a fire DoT of 10 every 30 ticks for 300 ticks
     takes exactly 100 health; a cooldown effect (grants the tag it is
     blocked by) refuses re-use until it expires; STACK_COUNT caps at 3,
     STACK_REFRESH extends instead of stacking.
  2. Integration: the three evaluators (full recompute, incremental sums,
     dirty cache) agree on every read of a seeded 20000-step sequence of
     add / remove / set-base / read over 6 attributes; an actor serialised
     mid-effect and restored continues to the same bytes after 400 ticks;
     tags are hierarchical (Fire implies Burning implies State).
  3. Extreme: 25 % fire resistance and a 30 shield turn 100 fire damage into
     45 health lost; two lethal hits in one tick report one death and the
     second does nothing; removing a modifier twice returns False; an
     effect on a dead actor or an immune actor is refused; a zero-duration
     effect lasts until the next tick; overrides take the highest priority;
     health clamps at its range.
"""

from harness.runner import Suite
from gameplay.rules import (
    FX, OP_ADD, OP_MUL, OP_OVERRIDE, EVAL_FULL, EVAL_INCREMENTAL, EVAL_DIRTY,
    KIND_INSTANT, KIND_DURATION, KIND_INFINITE, KIND_PERIODIC, STACK_REFRESH, STACK_COUNT,
    Attributes, Actor, Rules, EffectDef, TagRegistry, actor_to_bytes, actor_from_bytes,
)

comptime HEALTH = 0
comptime SPEED = 1
comptime ARMOR = 2


def _actor() -> Actor:
    var a = Actor(3, 2)
    a.attrs.set_base(HEALTH, 100 * FX)
    a.attrs.set_range(HEALTH, 0, 100 * FX)
    a.attrs.set_base(SPEED, 5 * FX)
    return a^


def main() raises:
    var s = Suite("rules")
    var reg = TagRegistry()
    var fire = reg.intern("State.Burning.Fire")
    var burning = reg.intern("State.Burning")
    var immune_fire = reg.intern("Immune.Fire")
    var cd = reg.intern("Cooldown.Fireball")
    var bits = reg.with_parents(fire)
    s.check((bits >> UInt64(burning)) & 1 == 1 and (bits >> UInt64(reg.intern("State"))) & 1 == 1, "Fire implies Burning implies State")

    var r = Rules(HEALTH)
    var buff = r.define(EffectDef(KIND_DURATION, 300, 0, SPEED, OP_MUL, 200, 0, 0, STACK_REFRESH, 1))
    var dot = r.define(EffectDef(KIND_PERIODIC, 300, 30, HEALTH, OP_ADD, -10 * FX, reg.with_parents(fire), reg.with_parents(immune_fire), STACK_REFRESH, 1))
    var cool = r.define(EffectDef(KIND_DURATION, 60, 0, ARMOR, OP_ADD, 0, reg.with_parents(cd), reg.with_parents(cd), STACK_REFRESH, 1))
    var stack3 = r.define(EffectDef(KIND_INFINITE, 0, 0, ARMOR, OP_ADD, 2 * FX, 0, 0, STACK_COUNT, 3))
    var zero = r.define(EffectDef(KIND_DURATION, 0, 0, ARMOR, OP_ADD, 7 * FX, 0, 0, STACK_REFRESH, 1))

    var actors = List[Actor]()
    actors.append(_actor())
    _ = r.apply(actors[0], buff, 1)
    var during = actors[0].attrs.value(SPEED)
    var end_tick = -1
    for _ in range(320):
        r.step(actors)
        if end_tick < 0 and actors[0].attrs.value(SPEED) == 5 * FX:
            end_tick = r.tick
    print("  +20 % buff: speed", during, "-> back to base at tick", end_tick)
    s.check(during == 6 * FX and end_tick == 300, "+20 % for exactly 300 ticks")

    var dv = List[Actor]()
    dv.append(_actor())
    dv[0].attrs.set_range(HEALTH, 0, 200 * FX)
    dv[0].attrs.set_base(HEALTH, 200 * FX)
    var t0 = r.tick
    _ = r.apply(dv[0], dot, 2)
    var on_fire = (dv[0].all_tags(r.defs) >> UInt64(burning)) & 1 == 1
    for _ in range(320):
        r.step(dv)
    print("  DoT 10 / 30 ticks for 300: health", dv[0].attrs.value(HEALTH) // FX, " burning while active", on_fire, " after", (dv[0].all_tags(r.defs) >> UInt64(burning)) & 1)
    s.check(dv[0].attrs.value(HEALTH) == 100 * FX and on_fire and len(dv[0].effects) == 0, "periodic damage: exactly 10 ticks x 10 inside 300 ticks, tag granted while active")
    _ = t0

    var cdv = List[Actor]()
    cdv.append(_actor())
    var first = r.apply(cdv[0], cool, 0)
    var second = r.apply(cdv[0], cool, 0)
    for _ in range(60):
        r.step(cdv)
    var third = r.apply(cdv[0], cool, 0)
    s.check(first and not second and third, "cooldown: blocked by its own tag until it expires")

    var st = _actor()
    for _ in range(5):
        _ = r.apply(st, stack3, 4)
    var rf = _actor()
    _ = r.apply(rf, buff, 9)
    var exp0 = rf.effects[0].expires
    var sl = List[Actor]()
    sl.append(rf^)
    for _ in range(100):
        r.step(sl)
    _ = r.apply(sl[0], buff, 9)
    print("  STACK_COUNT x5: stacks", r.stacks(st, stack3), " armor", st.attrs.value(ARMOR) // FX, "  STACK_REFRESH expiry", exp0, "->", sl[0].effects[0].expires)
    s.check(r.stacks(st, stack3) == 3 and st.attrs.value(ARMOR) == 6 * FX, "STACK_COUNT caps at 3")
    s.check(r.stacks(sl[0], buff) == 1 and sl[0].effects[0].expires == exp0 + 100, "STACK_REFRESH extends instead of stacking")

    # ---- evaluator parity --------------------------------------------------------------------------
    var full = Attributes(6, EVAL_FULL)
    var inc = Attributes(6, EVAL_INCREMENTAL)
    var dirty = Attributes(6, EVAL_DIRTY)
    var handles = List[Int]()
    var x = UInt64(12345)
    var agree = True
    var reads = 0
    for _ in range(20000):
        x = x * 6364136223846793005 + 1442695040888963407
        var op = Int((x >> 33) % 10)
        var a = Int((x >> 20) % 6)
        var v = Int((x >> 40) % 2001) - 1000
        if op < 4:
            var kind = OP_ADD if op < 2 else (OP_MUL if op == 2 else OP_OVERRIDE)
            var h1 = full.add_modifier(a, kind, v * 7, op)
            _ = inc.add_modifier(a, kind, v * 7, op)
            _ = dirty.add_modifier(a, kind, v * 7, op)
            handles.append(h1)
        elif op < 7 and len(handles) > 0:
            var k = Int((x >> 50) % UInt64(len(handles)))
            var h = handles[k]
            _ = full.remove_modifier(h)
            _ = inc.remove_modifier(h)
            _ = dirty.remove_modifier(h)
            handles[k] = handles[len(handles) - 1]
            _ = handles.pop()
        elif op == 7:
            full.set_base(a, v * FX)
            inc.set_base(a, v * FX)
            dirty.set_base(a, v * FX)
        else:
            reads += 1
            var f = full.value(a)
            if f != inc.value(a) or f != dirty.value(a):
                agree = False
    print("  evaluators over 20000 seeded ops (", reads, "reads,", len(full.mods), "modifiers left): agree", agree)
    s.check(agree, "full / incremental / dirty agree on every read")

    # ---- snapshot ------------------------------------------------------------------------------------
    var la = List[Actor]()
    la.append(_actor())
    _ = r.apply(la[0], dot, 3)
    _ = r.apply(la[0], buff, 3)
    _ = r.apply(la[0], stack3, 3)
    for _ in range(45):
        r.step(la)
    var bytes = actor_to_bytes(la[0])
    var lb = List[Actor]()
    lb.append(actor_from_bytes(bytes))
    var tick_saved = r.tick
    for _ in range(400):
        r.step(la)
    var after_a = actor_to_bytes(la[0])
    r.tick = tick_saved
    for _ in range(400):
        r.step(lb)
    s.check(actor_to_bytes(lb[0]) == after_a, "serialised mid-effect, restored: same bytes 400 ticks later")

    # ---- damage pipeline and extremes -------------------------------------------------------------------
    var d = List[Actor]()
    d.append(_actor())
    d[0].resist[1] = 250
    d[0].shield = 30 * FX
    var lost = r.damage(d[0], 0, 100 * FX, 1)
    print("  100 fire damage, 25 % resist, 30 shield: health lost", lost // FX, " shield left", d[0].shield)
    s.check(lost == 45 * FX and d[0].shield == 0, "resistance, then shield, then health")
    r.deaths = List[Int]()
    var l1 = r.damage(d[0], 0, 500 * FX, 0)
    var l2 = r.damage(d[0], 0, 500 * FX, 0)
    s.check(l1 == 55 * FX and l2 == 0 and len(r.deaths) == 1 and d[0].attrs.value(HEALTH) == 0, "two lethal hits: one death, the second does nothing, health clamps at 0")
    s.check(not r.apply(d[0], buff, 1), "no effects on a dead actor")
    var im = _actor()
    im.tags |= reg.with_parents(immune_fire)
    s.check(not r.apply(im, dot, 1), "immune actor refuses the fire DoT")
    var at = Attributes(1)
    var h = at.add_modifier(0, OP_ADD, 5)
    s.check(at.remove_modifier(h) and not at.remove_modifier(h), "removing a modifier twice: second is False")
    _ = at.add_modifier(0, OP_OVERRIDE, 11, 1)
    _ = at.add_modifier(0, OP_OVERRIDE, 99, 5)
    _ = at.add_modifier(0, OP_OVERRIDE, 22, 2)
    s.check(at.value(0) == 99, "override: the highest priority wins")
    var z = List[Actor]()
    z.append(_actor())
    _ = r.apply(z[0], zero, 1)
    var zin = z[0].attrs.value(ARMOR)
    r.step(z)
    s.check(zin == 7 * FX and z[0].attrs.value(ARMOR) == 0, "zero duration: active until the next tick")
    s.finish()
