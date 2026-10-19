# tier: component
"""Tables through `TypeSchema` reflection (ROADMAP 17.70, 17.11).

`rules_table.load_records[T]` reads `name key=value ...` lines into any
plain-data struct whose fields are 8 bytes, with the struct's own field names
as keys. Parity: the effect table below, loaded this way into `EffectDef`,
equals what the fixed-column `load_effects` builds from the same lines (the
fixed loader spells two keys differently, `immune` / `max`, which the
reflective one reads as `immune_if` / `max_stacks`). A struct the rules
package has never heard of loads with no loader change; a 4-byte field and
an unknown key raise with the line.
"""

from harness.runner import Suite
from ecs.schema import schema_of
from gameplay.rules import EffectDef, Rules, TagRegistry, FX
from gameplay.rules_table import load_effects, load_records

comptime FIXED = """
cool     kind=duration duration=60 attr=armor op=add value=0 grants=Cooldown.Fireball
burn     kind=periodic duration=30 period=10 attr=health op=add value=-1.0 grants=State.Burning.Fire immune=Immune.Fire
haste    kind=duration duration=300 attr=speed op=mul value=0.2 stacking=count max=3
"""

comptime REFLECTED = """
cool     kind=duration duration=60 attr=armor op=add value=0 grants=Cooldown.Fireball
burn     kind=periodic duration=30 period=10 attr=health op=add value=-1.0 grants=State.Burning.Fire immune_if=Immune.Fire
haste    kind=duration duration=300 attr=speed op=mul value=0.2 stacking=count max_stacks=3
"""


@fieldwise_init
struct Turret(Copyable, Movable):
    var range: Int
    var rate: Int
    var damage: Int
    var team: Int


@fieldwise_init
struct Narrow(Copyable, Movable):
    var a: Int
    var b: Int32


def same(a: EffectDef, b: EffectDef) -> Bool:
    return a.kind == b.kind and a.duration == b.duration and a.period == b.period and a.attr == b.attr and a.op == b.op and a.value == b.value and a.grants == b.grants and a.immune_if == b.immune_if and a.stacking == b.stacking and a.max_stacks == b.max_stacks


def main() raises:
    var s = Suite("rules_records")
    var attrs: List[String] = ["health", "mana", "armor", "speed"]

    var reg_f = TagRegistry()
    var rf = Rules(0)
    var names = Dict[String, Int]()
    load_effects(FIXED, rf, reg_f, attrs, names)

    var reg_r = TagRegistry()
    var enums = Dict[String, List[String]]()
    enums["kind"] = ["instant", "duration", "infinite", "periodic"]
    enums["op"] = ["add", "mul", "override"]
    enums["stacking"] = ["refresh", "count"]
    enums["attr"] = attrs.copy()
    var tags: List[String] = ["grants", "immune_if"]
    var template = EffectDef(0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
    var recs = load_records(REFLECTED, template, schema_of[EffectDef](), enums, tags, reg_r)
    var eq = len(recs) == len(rf.defs)
    for i in range(len(recs)):
        eq = eq and same(recs[i][1], rf.defs[i])
    print("reflective effects:", len(recs), " burn grants", recs[1][1].grants, " haste max_stacks", recs[2][1].max_stacks)
    s.check(eq and recs[0][0] == "cool" and recs[2][0] == "haste", "reflective load equals the fixed-column load, field for field")

    var tt = Turret(10 * FX, 2, 5 * FX, 7)
    var turrets = load_records("gun range=25.5 damage=3.0\nlaser rate=9 team=2", tt, schema_of[Turret](), Dict[String, List[String]](), List[String](), reg_r)
    print("turrets: gun", turrets[0][1].range, turrets[0][1].rate, turrets[0][1].damage, turrets[0][1].team, " laser", turrets[1][1].range, turrets[1][1].rate, turrets[1][1].damage, turrets[1][1].team)
    s.check(turrets[0][1].range == 25500 and turrets[0][1].damage == 3000 and turrets[0][1].rate == 2 and turrets[0][1].team == 7, "an unknown struct loads: decimals fixed point, omitted keys keep the template")
    s.check(turrets[1][1].rate == 9 and turrets[1][1].team == 2 and turrets[1][1].range == 10 * FX, "a second line starts from the template again")

    var errs = 0
    var msgs = List[String]()
    for bad in [String("t colour=red"), String("t range"), String("t range=abc")]:
        try:
            _ = load_records(bad, tt, schema_of[Turret](), Dict[String, List[String]](), List[String](), reg_r)
        except e:
            errs += 1
            msgs.append(String(e))
    try:
        _ = load_records("n b=3", Narrow(0, 0), schema_of[Narrow](), Dict[String, List[String]](), List[String](), reg_r)
    except e:
        errs += 1
        msgs.append(String(e))
    print("errors:", msgs[0], "|", msgs[3])
    s.check(errs == 4 and "line 1" in msgs[0] and "8-byte" in msgs[3], "unknown key / missing '=' / bad number / 4-byte field raise with the line")
    s.finish()
