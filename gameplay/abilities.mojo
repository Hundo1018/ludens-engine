"""Abilities on top of `rules` (ROADMAP 17.70): activation conditions,
cost, cooldown, targets, cancel, cues.

An `AbilityDef` names what activating it needs and does:

  * gates: `required` tags (all of them) and `blocked` tags (none of them)
    on the caster -- stunned, silenced, already channelling;
  * cost: `cost` (fixed point) of attribute `cost_attr`, paid only if the
    caster has at least that much;
  * cooldown: an effect (`Rules.define`) applied to the caster that grants
    `cooldown_tag`; while the tag is on, the ability is refused. A cooldown
    is therefore an ordinary timed effect -- it expires on the rules tick,
    and it is in the actor's bytes, so it survives a save;
  * targets: up to `max_targets`; each gets `damage` of type `dtype`
    (through `Rules.damage`: resistance, shield, health) and the
    ability's target effects (`add_target_effect`);
  * channel: an optional effect on the caster (`channel_effect`) that runs
    while the ability does; `cancel` ends it early.

`activate` returns `OK` or the reason it refused (checked in this order:
dead caster, missing tag, blocked tag, cooldown, cost, no target), and
changes nothing when it refuses. Every outcome leaves a `Cue` (ability,
caster, target, kind) for the host to play effects / sounds -- cues are
events, the host's to consume (`take_cues`).
"""

from .rules import Rules, Actor

comptime OK = 0
comptime FAIL_DEAD = 1
comptime FAIL_MISSING_TAG = 2
comptime FAIL_BLOCKED_TAG = 3
comptime FAIL_COOLDOWN = 4
comptime FAIL_COST = 5
comptime FAIL_NO_TARGET = 6

comptime CUE_ACTIVATE = 0
comptime CUE_HIT = 1
comptime CUE_CANCEL = 2
comptime CUE_FAIL = 3


@fieldwise_init
struct AbilityDef(Copyable, ImplicitlyCopyable, Movable):
    var required: UInt64
    var blocked: UInt64
    var cost_attr: Int
    var cost: Int
    var cooldown_effect: Int  # -1: none
    var cooldown_tag: UInt64
    var max_targets: Int
    var damage: Int
    var dtype: Int
    var channel_effect: Int  # -1: none


@fieldwise_init
struct Cue(Copyable, ImplicitlyCopyable, Movable):
    var ability: Int
    var caster: Int
    var target: Int  # -1: none
    var kind: Int
    var detail: Int  # FAIL_* for CUE_FAIL, health lost for CUE_HIT


struct Abilities(Movable):
    var defs: List[AbilityDef]
    var eff_start: List[Int]  # target effects of ability i: eff[eff_start[i] .. eff_start[i + 1]]
    var eff: List[Int]
    var cues: List[Cue]

    def __init__(out self):
        self.defs = List[AbilityDef]()
        self.eff_start = [0]
        self.eff = List[Int]()
        self.cues = List[Cue]()

    def define(mut self, d: AbilityDef) raises -> Int:
        if d.max_targets < 0 or d.cost < 0 or d.damage < 0:
            raise Error("Abilities.define: max_targets, cost and damage must be >= 0")
        self.defs.append(d)
        self.eff_start.append(len(self.eff))
        return len(self.defs) - 1

    def add_target_effect(mut self, ability: Int, effect: Int) raises:
        """Only for the most recently defined ability (effects are stored
        contiguously)."""
        if ability != len(self.defs) - 1:
            raise Error("Abilities.add_target_effect: only the last defined ability")
        self.eff.append(effect)
        self.eff_start[ability + 1] = len(self.eff)

    def _fail(mut self, ability: Int, caster: Int, reason: Int) -> Int:
        self.cues.append(Cue(ability, caster, -1, CUE_FAIL, reason))
        return reason

    def check(self, rules: Rules, actors: List[Actor], caster: Int, ability: Int, n_targets: Int) -> Int:
        var d = self.defs[ability]
        ref c = actors[caster]
        if c.dead:
            return FAIL_DEAD
        var tags = c.all_tags(rules.defs)
        if (tags & d.required) != d.required:
            return FAIL_MISSING_TAG
        if (tags & d.blocked) != 0:
            return FAIL_BLOCKED_TAG
        if d.cooldown_tag != 0 and (tags & d.cooldown_tag) != 0:
            return FAIL_COOLDOWN
        if d.cost > 0 and c.attrs.base[d.cost_attr] < d.cost:
            return FAIL_COST
        if d.max_targets > 0 and n_targets == 0:
            return FAIL_NO_TARGET
        return OK

    def activate(mut self, mut rules: Rules, mut actors: List[Actor], caster: Int, ability: Int, targets: List[Int]) raises -> Int:
        for t in targets:
            if t < 0 or t >= len(actors):
                raise Error("Abilities.activate: target index out of range")
        var why = self.check(rules, actors, caster, ability, len(targets))
        if why != OK:
            return self._fail(ability, caster, why)
        var d = self.defs[ability]
        if d.cost > 0:
            actors[caster].attrs.set_base(d.cost_attr, actors[caster].attrs.base[d.cost_attr] - d.cost)
        if d.cooldown_effect >= 0:
            _ = rules.apply(actors[caster], d.cooldown_effect, caster)
        if d.channel_effect >= 0:
            _ = rules.apply(actors[caster], d.channel_effect, caster)
        self.cues.append(Cue(ability, caster, -1, CUE_ACTIVATE, 0))
        var n = min(len(targets), d.max_targets)
        for k in range(n):
            var t = targets[k]
            var lost = 0
            if d.damage > 0:
                lost = rules.damage(actors[t], t, d.damage, d.dtype)
            for e in range(self.eff_start[ability], self.eff_start[ability + 1]):
                _ = rules.apply(actors[t], self.eff[e], caster)
            self.cues.append(Cue(ability, caster, t, CUE_HIT, lost))
        return OK

    def cancel(mut self, mut rules: Rules, mut actors: List[Actor], caster: Int, ability: Int) -> Bool:
        """End the caster's channel of this ability early; False if none runs."""
        var ch = self.defs[ability].channel_effect
        if ch < 0:
            return False
        ref effs = actors[caster].effects
        for i in range(len(effs)):
            if effs[i].def_id == ch and effs[i].source == caster:
                rules._end(actors[caster], i)
                self.cues.append(Cue(ability, caster, -1, CUE_CANCEL, 0))
                return True
        return False

    def take_cues(mut self) -> List[Cue]:
        var out = self.cues^
        self.cues = List[Cue]()
        return out^
