# tier: component
"""Abilities (ROADMAP 17.70, `gameplay.abilities`).

Fireball: costs 30 mana, 60-tick cooldown (an effect granting
Cooldown.Fireball), 25 fire damage to up to 2 targets plus a burning DoT,
refused while Stunned. Channel: a 90-tick channel effect, cancellable.

  1. Activation: mana 100 -> 70, both targets lose 25 (one with 20 % fire
     resistance loses 20), each carries the burn, cues ACTIVATE + 2 HIT.
  2. Refusals change nothing and say why: on cooldown (until tick 60, then
     allowed again), not enough mana, stunned, no target, dead caster.
  3. Channel: activation grants the Channeling tag; `cancel` removes it at
     once (and only once); without a cancel it ends at tick 90.
  4. The cooldown is an effect: saved with `actor_to_bytes` mid-cooldown
     and restored, the restored caster is still refused until it expires.
"""

from harness.runner import Suite
from gameplay.rules import (
    FX, OP_ADD, KIND_DURATION, KIND_PERIODIC, STACK_REFRESH,
    Actor, Rules, EffectDef, TagRegistry, actor_to_bytes, actor_from_bytes,
)
from gameplay.abilities import (
    Abilities, AbilityDef, OK, FAIL_DEAD, FAIL_BLOCKED_TAG, FAIL_COOLDOWN,
    FAIL_COST, FAIL_NO_TARGET, CUE_ACTIVATE, CUE_HIT, CUE_CANCEL, CUE_FAIL,
)

comptime HEALTH = 0
comptime MANA = 1
comptime ARMOR = 2


def actor() -> Actor:
    var a = Actor(3, 2)
    a.attrs.set_base(HEALTH, 100 * FX)
    a.attrs.set_range(HEALTH, 0, 100 * FX)
    a.attrs.set_base(MANA, 100 * FX)
    return a^


def main() raises:
    var s = Suite("abilities")
    var reg = TagRegistry()
    var cd = reg.with_parents(reg.intern("Cooldown.Fireball"))
    var stun = reg.with_parents(reg.intern("State.Stunned"))
    var chan = reg.with_parents(reg.intern("State.Channeling"))
    var fire = reg.with_parents(reg.intern("State.Burning.Fire"))
    var r = Rules(HEALTH)
    var cool = r.define(EffectDef(KIND_DURATION, 60, 0, ARMOR, OP_ADD, 0, cd, 0, STACK_REFRESH, 1))
    var burn = r.define(EffectDef(KIND_PERIODIC, 30, 10, HEALTH, OP_ADD, -1 * FX, fire, 0, STACK_REFRESH, 1))
    var stunned = r.define(EffectDef(KIND_DURATION, 1000, 0, ARMOR, OP_ADD, 0, stun, 0, STACK_REFRESH, 1))
    var channel = r.define(EffectDef(KIND_DURATION, 90, 0, ARMOR, OP_ADD, 0, chan, 0, STACK_REFRESH, 1))
    var ab = Abilities()
    var fb = ab.define(AbilityDef(0, stun, MANA, 30 * FX, cool, cd, 2, 25 * FX, 1, -1))
    ab.add_target_effect(fb, burn)
    var ch = ab.define(AbilityDef(0, stun | chan, MANA, 0, -1, 0, 0, 0, 0, channel))

    var actors = List[Actor]()
    for _ in range(4):
        actors.append(actor())
    actors[2].resist[1] = 200  # 20 % fire resistance
    var res = ab.activate(r, actors, 0, fb, [1, 2])
    var cues = ab.take_cues()
    var hits = 0
    for c in cues:
        if c.kind == CUE_HIT:
            hits += 1
    print("fireball: mana", actors[0].attrs.base[MANA], " target hp", actors[1].attrs.base[HEALTH], actors[2].attrs.base[HEALTH], " cues", len(cues))
    s.check(res == OK and actors[0].attrs.base[MANA] == 70 * FX, "activation pays 30 mana")
    s.check(actors[1].attrs.base[HEALTH] == 75 * FX and actors[2].attrs.base[HEALTH] == 80 * FX, "25 fire damage, 20 on the resistant target")
    s.check(r.stacks(actors[1], burn) == 1 and r.stacks(actors[2], burn) == 1 and len(cues) == 3 and cues[0].kind == CUE_ACTIVATE and hits == 2, "burn applied to both; cues ACTIVATE + 2 HIT")

    # refusals
    var mana_before = actors[0].attrs.base[MANA]
    var on_cd = ab.activate(r, actors, 0, fb, [1])
    var unchanged = actors[0].attrs.base[MANA] == mana_before and actors[1].attrs.base[HEALTH] == 75 * FX
    var allowed_at = -1
    for _ in range(80):
        r.step(actors)
        if allowed_at < 0 and ab.check(r, actors, 0, fb, 1) == OK:
            allowed_at = r.tick
    print("cooldown: refused with", on_cd, " allowed again at tick", allowed_at)
    s.check(on_cd == FAIL_COOLDOWN and unchanged and allowed_at == 60, "cooldown refuses without changes until tick 60")
    _ = ab.take_cues()  # the cooldown refusal's FAIL cue
    actors[3].attrs.set_base(MANA, 10 * FX)
    var poor = ab.activate(r, actors, 3, fb, [1])
    _ = r.apply(actors[3], stunned, 3)
    actors[3].attrs.set_base(MANA, 100 * FX)
    var st = ab.activate(r, actors, 3, fb, [1])
    var none = ab.activate(r, actors, 0, fb, List[Int]())
    actors[2].dead = True
    var dead = ab.activate(r, actors, 2, fb, [1])
    var fails = 0
    for c in ab.take_cues():
        if c.kind == CUE_FAIL:
            fails += 1
    s.check(poor == FAIL_COST and st == FAIL_BLOCKED_TAG and none == FAIL_NO_TARGET and dead == FAIL_DEAD and fails == 4, "cost, stun, no target, dead caster refused with reasons and FAIL cues")

    # channel
    _ = ab.activate(r, actors, 1, ch, List[Int]())
    var on = (actors[1].all_tags(r.defs) & chan) != 0
    var again = ab.activate(r, actors, 1, ch, List[Int]())
    var c1 = ab.cancel(r, actors, 1, ch)
    var off = (actors[1].all_tags(r.defs) & chan) == 0
    var c2 = ab.cancel(r, actors, 1, ch)
    _ = ab.activate(r, actors, 1, ch, List[Int]())
    var t0 = r.tick
    var ended = -1
    for _ in range(100):
        r.step(actors)
        if ended < 0 and (actors[1].all_tags(r.defs) & chan) == 0:
            ended = r.tick - t0
    print("channel: on", on, " re-cast while channelling", again, " cancel", c1, c2, " uncancelled ends after", ended, "ticks")
    s.check(on and again == FAIL_BLOCKED_TAG and c1 and off and not c2, "channel grants its tag; cancel ends it once")
    s.check(ended == 90, "uncancelled channel ends at 90 ticks")

    # cooldown survives a save
    var fresh = List[Actor]()
    fresh.append(actor())
    fresh.append(actor())
    _ = ab.activate(r, fresh, 0, fb, [1])
    for _ in range(20):
        r.step(fresh)
    var back = actor_from_bytes(actor_to_bytes(fresh[0]))
    var restored = List[Actor]()
    restored.append(back^)
    restored.append(actor())
    var refused = ab.activate(r, restored, 0, fb, [1]) == FAIL_COOLDOWN
    for _ in range(40):
        r.step(restored)
    var after = ab.check(r, restored, 0, fb, 1) == OK
    s.check(refused and after, "restored mid-cooldown: refused until the effect expires")
    s.finish()
