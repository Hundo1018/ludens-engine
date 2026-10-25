"""Effects and abilities from text tables (ROADMAP 17.70: data-driven
definitions instead of code).

One definition per line, `name key=value ...`; blank lines and lines
starting with `#` are skipped. Values are in game units -- numbers with a
decimal point are converted to fixed point (`rules.FX`), tags are
hierarchical names interned in the caller's `TagRegistry` (with their
parents), attributes and damage types are names looked up in lists the
caller passes. Effects first, then abilities (which name effects).

Effects (`load_effects`):
    burn kind=periodic duration=30 period=10 attr=health op=add value=-1.0
         grants=State.Burning.Fire immune=Immune.Fire stacking=refresh max=1
  kind: instant / duration / infinite / periodic; op: add / mul / override
  (a mul value is the fractional increase, as `rules` stores it: 0.2 is
  +20 %, stored 200); stacking: refresh / count.

Abilities (`load_abilities`):
    fireball cost_attr=mana cost=30.0 cooldown=cool cooldown_tag=Cooldown.Fireball
             blocked=State.Stunned targets=2 damage=25.0 dtype=fire effects=burn
  `effects` is a comma-separated list of effect names; `required` /
  `blocked` / `cooldown_tag` take comma-separated tag names; `channel`
  names an effect.

Unknown keys, unknown names and malformed numbers raise with the line
number: a table error is an input error, reported once at load.
"""

from .rules import (
    FX, OP_ADD, OP_MUL, OP_OVERRIDE, KIND_INSTANT, KIND_DURATION, KIND_INFINITE,
    KIND_PERIODIC, STACK_REFRESH, STACK_COUNT, EffectDef, Rules, TagRegistry,
)
from .abilities import Abilities, AbilityDef
from ecs.schema import TypeSchema


def _index(names: List[String], name: String, what: String, line: Int) raises -> Int:
    for i in range(len(names)):
        if names[i] == name:
            return i
    raise Error("rules_table: line " + String(line) + ": unknown " + what + " '" + name + "'")


def _fixed(v: String, line: Int) raises -> Int:
    """'1.2' -> 1200, '30' -> 30 (integers stay as written: ticks, counts)."""
    try:
        if "." in v:
            var f = atof(v)
            return Int(f * Float64(FX) + (0.5 if f >= 0 else -0.5))
        return atol(v)
    except:
        raise Error("rules_table: line " + String(line) + ": bad number '" + v + "'")


def _tags(mut reg: TagRegistry, v: String) raises -> UInt64:
    var bits = UInt64(0)
    for part in v.split(","):
        var p = String(part.strip())
        if p.byte_length() > 0:
            bits |= reg.with_parents(reg.intern(p))
    return bits


def _lines(text: String) -> List[Tuple[Int, List[String]]]:
    var out = List[Tuple[Int, List[String]]]()
    var n = 0
    for raw in text.split("\n"):
        n += 1
        var l = String(raw.strip())
        if l.byte_length() == 0 or l.startswith("#"):
            continue
        var words = List[String]()
        for w in l.split(" "):
            var ws = String(w.strip())
            if ws.byte_length() > 0:
                words.append(ws)
        out.append((n, words^))
    return out^


def load_effects(text: String, mut rules: Rules, mut reg: TagRegistry, attrs: List[String], mut names: Dict[String, Int]) raises:
    for item in _lines(text):
        var line = item[0]
        ref w = item[1]
        var kind = KIND_INSTANT
        var duration = 0
        var period = 0
        var attr = 0
        var op = OP_ADD
        var value = 0
        var grants = UInt64(0)
        var immune = UInt64(0)
        var stacking = STACK_REFRESH
        var max_stacks = 1
        for k in range(1, len(w)):
            var kv = w[k].split("=")
            if len(kv) != 2:
                raise Error("rules_table: line " + String(line) + ": expected key=value, got '" + w[k] + "'")
            var key = String(kv[0])
            var v = String(kv[1])
            if key == "kind":
                var kinds: List[String] = ["instant", "duration", "infinite", "periodic"]
                kind = _index(kinds, v, "kind", line)
            elif key == "duration":
                duration = _fixed(v, line)
            elif key == "period":
                period = _fixed(v, line)
            elif key == "attr":
                attr = _index(attrs, v, "attribute", line)
            elif key == "op":
                var ops: List[String] = ["add", "mul", "override"]
                op = _index(ops, v, "op", line)
            elif key == "value":
                value = _fixed(v, line)
            elif key == "grants":
                grants = _tags(reg, v)
            elif key == "immune":
                immune = _tags(reg, v)
            elif key == "stacking":
                var st: List[String] = ["refresh", "count"]
                stacking = _index(st, v, "stacking", line)
            elif key == "max":
                max_stacks = _fixed(v, line)
            else:
                raise Error("rules_table: line " + String(line) + ": unknown key '" + key + "'")
        names[w[0]] = rules.define(EffectDef(kind, duration, period, attr, op, value, grants, immune, stacking, max_stacks))


def load_abilities(
    text: String, mut ab: Abilities, mut reg: TagRegistry, attrs: List[String], dtypes: List[String],
    effects: Dict[String, Int], mut names: Dict[String, Int],
) raises:
    for item in _lines(text):
        var line = item[0]
        ref w = item[1]
        var required = UInt64(0)
        var blocked = UInt64(0)
        var cost_attr = 0
        var cost = 0
        var cooldown = -1
        var cd_tag = UInt64(0)
        var targets = 0
        var damage = 0
        var dtype = 0
        var channel = -1
        var target_effects = List[Int]()
        for k in range(1, len(w)):
            var kv = w[k].split("=")
            if len(kv) != 2:
                raise Error("rules_table: line " + String(line) + ": expected key=value, got '" + w[k] + "'")
            var key = String(kv[0])
            var v = String(kv[1])
            if key == "required":
                required = _tags(reg, v)
            elif key == "blocked":
                blocked = _tags(reg, v)
            elif key == "cost_attr":
                cost_attr = _index(attrs, v, "attribute", line)
            elif key == "cost":
                cost = _fixed(v, line)
            elif key == "cooldown" or key == "channel":
                if v not in effects:
                    raise Error("rules_table: line " + String(line) + ": unknown effect '" + v + "'")
                if key == "cooldown":
                    cooldown = effects[v]
                else:
                    channel = effects[v]
            elif key == "cooldown_tag":
                cd_tag = _tags(reg, v)
            elif key == "targets":
                targets = _fixed(v, line)
            elif key == "damage":
                damage = _fixed(v, line)
            elif key == "dtype":
                dtype = _index(dtypes, v, "damage type", line)
            elif key == "effects":
                for e in v.split(","):
                    var es = String(e.strip())
                    if es not in effects:
                        raise Error("rules_table: line " + String(line) + ": unknown effect '" + es + "'")
                    target_effects.append(effects[es])
            else:
                raise Error("rules_table: line " + String(line) + ": unknown key '" + key + "'")
        var id = ab.define(AbilityDef(required, blocked, cost_attr, cost, cooldown, cd_tag, targets, damage, dtype, channel))
        for e in target_effects:
            ab.add_target_effect(id, e)
        names[w[0]] = id


def load_records[T: Copyable & Deinitable](
    text: String,
    template: T,
    schema: TypeSchema,
    enums: Dict[String, List[String]],
    tag_fields: List[String],
    mut reg: TagRegistry,
) raises -> List[Tuple[String, T]]:
    """A table for ANY plain-data struct `T` through its `TypeSchema`
    (`ecs.schema.schema_of[T]`, 17.11): the keys are `T`'s own field names,
    so a new field is a new column with no loader change. Every field read
    this way is 8 bytes (`Int` / `UInt64`). A key in `enums` takes a name
    from that list (stored as its index); a key in `tag_fields` takes
    comma-separated hierarchical tag names (stored as the OR of their bits
    and their parents'); any other key takes a number, decimals as fixed
    point. Lines start from a copy of `template`, so omitted keys keep its
    values. Returns (name, record) per line."""
    var out = List[Tuple[String, T]]()
    for item in _lines(text):
        var line = item[0]
        ref w = item[1]
        var rec = template.copy()
        var dst = Pointer(to=rec).unsafe_bitcast[UInt8]()
        for k in range(1, len(w)):
            var kv = w[k].split("=")
            if len(kv) != 2:
                raise Error("rules_table: line " + String(line) + ": expected key=value, got '" + w[k] + "'")
            var key = String(kv[0])
            var v = String(kv[1])
            var j = schema.find(key)
            if j < 0:
                raise Error("rules_table: line " + String(line) + ": unknown key '" + key + "'")
            ref f = schema.fields[j]
            if f.size != 8:
                raise Error("rules_table: line " + String(line) + ": field '" + key + "' is " + f.type_name + ", only 8-byte fields are supported")
            var bits: UInt64
            var is_tag = False
            for t in tag_fields:
                if t == key:
                    is_tag = True
            if is_tag:
                bits = _tags(reg, v)
            elif key in enums:
                bits = UInt64(_index(enums[key], v, key, line))
            else:
                bits = UInt64(_fixed(v, line))
            for b in range(8):
                dst.unsafe_offset(f.offset + b)[] = UInt8((bits >> UInt64(8 * b)) & 0xFF)
        out.append((w[0], rec^))
    return out^
