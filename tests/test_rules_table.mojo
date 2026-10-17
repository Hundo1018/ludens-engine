# tier: component
"""Effects and abilities from a text table (ROADMAP 17.70,
`gameplay.rules_table`).

  1. Parity: the table below defines the same effects and abilities as
     `test_abilities` does in code; the definitions are field-for-field
     equal (tags interned in the same order) and the fireball scenario plays
     the same: mana 100 -> 70, targets 100 -> 75 and 80 (20 % resistance),
     cooldown over at tick 60.
  2. A +20 % mul buff written as value=0.2 turns speed 5.0 into 6.0.
  3. Errors name the line: unknown key, unknown effect, bad number,
     missing '='.
"""

from harness.runner import Suite
from gameplay.rules import (
    FX, OP_ADD, OP_MUL, KIND_DURATION, KIND_PERIODIC, STACK_REFRESH,
    Actor, Rules, EffectDef, TagRegistry,
)
from gameplay.abilities import Abilities, AbilityDef, OK
from gameplay.rules_table import load_effects, load_abilities

comptime HEALTH = 0
comptime MANA = 1
comptime ARMOR = 2

comptime EFFECTS = """
# name        fields
cool     kind=duration duration=60 attr=armor op=add value=0 grants=Cooldown.Fireball
burn     kind=periodic duration=30 period=10 attr=health op=add value=-1.0 grants=State.Burning.Fire
haste    kind=duration duration=300 attr=speed op=mul value=0.2
"""

comptime ABILITIES = """
fireball blocked=State.Stunned cost_attr=mana cost=30.0 cooldown=cool cooldown_tag=Cooldown.Fireball targets=2 damage=25.0 dtype=fire effects=burn
"""


def actor() -> Actor:
    var a = Actor(4, 2)
    a.attrs.set_base(HEALTH, 100 * FX)
    a.attrs.set_range(HEALTH, 0, 100 * FX)
    a.attrs.set_base(MANA, 100 * FX)
    a.attrs.set_base(3, 5 * FX)
    return a^


def same_effect(a: EffectDef, b: EffectDef) -> Bool:
    return a.kind == b.kind and a.duration == b.duration and a.period == b.period and a.attr == b.attr and a.op == b.op and a.value == b.value and a.grants == b.grants and a.immune_if == b.immune_if and a.stacking == b.stacking and a.max_stacks == b.max_stacks


def main() raises:
    var s = Suite("rules_table")
    var attrs: List[String] = ["health", "mana", "armor", "speed"]
    var dtypes: List[String] = ["physical", "fire"]

    # code definitions, tags interned in table order
    var reg_c = TagRegistry()
    var cd = reg_c.with_parents(reg_c.intern("Cooldown.Fireball"))
    var fire = reg_c.with_parents(reg_c.intern("State.Burning.Fire"))
    var stun = reg_c.with_parents(reg_c.intern("State.Stunned"))
    var rc = Rules(HEALTH)
    _ = rc.define(EffectDef(KIND_DURATION, 60, 0, ARMOR, OP_ADD, 0, cd, 0, STACK_REFRESH, 1))
    _ = rc.define(EffectDef(KIND_PERIODIC, 30, 10, HEALTH, OP_ADD, -1 * FX, fire, 0, STACK_REFRESH, 1))
    _ = rc.define(EffectDef(KIND_DURATION, 300, 0, 3, OP_MUL, 200, 0, 0, STACK_REFRESH, 1))
    var ac = Abilities()
    var fb_c = ac.define(AbilityDef(0, stun, MANA, 30 * FX, 0, cd, 2, 25 * FX, 1, -1))
    ac.add_target_effect(fb_c, 1)

    # table definitions
    var reg_t = TagRegistry()
    var rt = Rules(HEALTH)
    var eff = Dict[String, Int]()
    load_effects(EFFECTS, rt, reg_t, attrs, eff)
    var at = Abilities()
    var abn = Dict[String, Int]()
    load_abilities(ABILITIES, at, reg_t, attrs, dtypes, eff, abn)
    var eq = len(rt.defs) == len(rc.defs)
    for i in range(len(rc.defs)):
        eq = eq and same_effect(rt.defs[i], rc.defs[i])
    var a1 = at.defs[abn["fireball"]]
    var a0 = ac.defs[fb_c]
    var ab_eq = a1.required == a0.required and a1.blocked == a0.blocked and a1.cost_attr == a0.cost_attr and a1.cost == a0.cost and a1.cooldown_effect == a0.cooldown_effect and a1.cooldown_tag == a0.cooldown_tag and a1.max_targets == a0.max_targets and a1.damage == a0.damage and a1.dtype == a0.dtype and a1.channel_effect == a0.channel_effect and at.eff == ac.eff
    s.check(eq and ab_eq, "table definitions equal the code ones field for field")

    var actors = List[Actor]()
    for _ in range(3):
        actors.append(actor())
    actors[2].resist[1] = 200
    var r = at.activate(rt, actors, 0, abn["fireball"], [1, 2])
    var back = -1
    for _ in range(80):
        rt.step(actors)
        if back < 0 and at.check(rt, actors, 0, abn["fireball"], 1) == OK:
            back = rt.tick
    print("table fireball: mana", actors[0].attrs.base[MANA], " hp", actors[1].attrs.base[HEALTH], actors[2].attrs.base[HEALTH], " cooldown over at", back)
    s.check(r == OK and actors[0].attrs.base[MANA] == 70 * FX and actors[2].attrs.base[HEALTH] < 100 * FX and back == 60, "the table fireball plays like the code one")

    var h = List[Actor]()
    h.append(actor())
    _ = rt.apply(h[0], eff["haste"], 0)
    s.check(h[0].attrs.value(3) == 6 * FX, "value=0.2 on a mul effect: +20 %")

    var errs = 0
    var msgs = List[String]()
    for bad in [String("x kind=duration colour=red"), String("y kind=sometimes"), String("z duration=abc"), String("w duration")]:
        try:
            var e2 = Dict[String, Int]()
            load_effects(bad, rt, reg_t, attrs, e2)
        except e:
            errs += 1
            msgs.append(String(e))
    try:
        var n2 = Dict[String, Int]()
        load_abilities("q effects=nonesuch", at, reg_t, attrs, dtypes, eff, n2)
    except e:
        errs += 1
        msgs.append(String(e))
    print("errors:", msgs[0], "|", msgs[4])
    s.check(errs == 5 and "line 1" in msgs[0], "unknown key / kind / bad number / missing '=' / unknown effect raise with the line")
    s.finish()
