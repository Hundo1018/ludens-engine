"""Object-oriented baseline for the duration-buff and periodic-damage subset of
`gameplay/rules.mojo` (ROADMAP 17.70 (b), paradigm comparison).

Each character is an object that owns a list of effect objects. Effects are
applied and advanced by methods on the owner, not by a central rules table.
Only the subset the comparison needs is implemented: OP_MUL duration buffs on
one attribute, and periodic health damage with no resistance or shield. The
arithmetic is the same fixed point (FX = 1000) and the same tick order as
`Rules.step`, so the two can be compared actor by actor.

Tick order (as in `Rules.step`): the tick advances; each effect whose period
is due and that has not expired fires; an effect past its expiry ends.
"""

comptime FX = 1000


struct OopEffect(Copyable, Movable):
    var mul: Int  # OP_MUL percent in FX (a buff); 0 for a damage effect
    var dot: Int  # health change per period in FX (negative = damage); 0 for a buff
    var period: Int  # 0 for a duration buff
    var expires: Int
    var next_period: Int

    def __init__(out self, mul: Int, dot: Int, period: Int, expires: Int, next_period: Int):
        self.mul = mul
        self.dot = dot
        self.period = period
        self.expires = expires
        self.next_period = next_period


struct OopCharacter(Movable):
    var base_speed: Int
    var health: Int
    var dead: Bool
    var effects: List[OopEffect]

    def __init__(out self, base_speed: Int, health: Int):
        self.base_speed = base_speed
        self.health = health
        self.dead = False
        self.effects = List[OopEffect]()

    def speed(self) -> Int:
        """Base speed scaled by the summed OP_MUL percents of the active buffs."""
        var mul = 0
        for e in self.effects:
            mul += e.mul
        return self.base_speed * (FX + mul) // FX

    def hit(mut self, amount: Int) -> Int:
        """Health lost to `amount` (no resistance, no shield); records death once."""
        if self.dead or amount <= 0:
            return 0
        var lost = min(amount, max(self.health, 0))
        self.health -= lost
        if self.health <= 0:
            self.dead = True
        return lost

    def add_buff(mut self, mul: Int, tick: Int, duration: Int):
        self.effects.append(OopEffect(mul, 0, 0, tick + duration, tick))

    def add_dot(mut self, dot: Int, period: Int, tick: Int, duration: Int):
        self.effects.append(OopEffect(0, dot, period, tick + duration, tick + period))

    def advance(mut self, tick: Int):
        """One tick for this character's effects (the tick has already advanced)."""
        var i = 0
        while i < len(self.effects):
            var due = self.effects[i].period > 0 and tick >= self.effects[i].next_period
            var live = self.effects[i].expires < 0 or tick <= self.effects[i].expires
            if due and live:
                _ = self.hit(-self.effects[i].dot)
                self.effects[i].next_period = tick + self.effects[i].period
            if self.effects[i].expires >= 0 and tick >= self.effects[i].expires:
                _ = self.effects.pop(i)
                continue
            i += 1
