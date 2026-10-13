"""Achievements and stat counters as predicates on events (ROADMAP 17.73).

An achievement counts events of one kind up to a threshold and unlocks
once; the unlock is written to an `Outbox` (kind `OUT_ACHIEVEMENT`, key =
achievement id) for the host to forward to the platform. Progress and the
unlocked bit live in `gameplay.flow.Flags` (one FLAG_INT per achievement,
-1 once unlocked), so they save, load and replay with the other flags.
"""

from diag.outbox import Outbox
from .flow import Flags, FLAG_INT

comptime OUT_ACHIEVEMENT = 1


struct Achievements(Copyable, Movable):
    var kinds: List[Int]
    var thresholds: List[Int]
    var flag: List[Int]  # flag index holding progress (-1 = unlocked)

    def __init__(out self):
        self.kinds = List[Int]()
        self.thresholds = List[Int]()
        self.flag = List[Int]()

    def define(mut self, mut flags: Flags, name: String, event_kind: Int, threshold: Int) raises -> Int:
        if threshold < 1:
            raise Error("Achievements.define: threshold >= 1")
        self.kinds.append(event_kind)
        self.thresholds.append(threshold)
        self.flag.append(flags.declare("ach." + name, FLAG_INT, 0))
        return len(self.kinds) - 1

    def unlocked(self, flags: Flags, id: Int) -> Bool:
        return flags.get(self.flag[id]) < 0

    def on_event(self, mut flags: Flags, mut out: Outbox, kind: Int, amount: Int, tick: Int) -> Int:
        """Advance the achievements counting `kind`; returns how many
        unlocked now (each exactly once)."""
        var n = 0
        for i in range(len(self.kinds)):
            if self.kinds[i] != kind:
                continue
            var f = self.flag[i]
            var p = flags.get(f)
            if p < 0:
                continue
            p = min(p + amount, self.thresholds[i])
            if p >= self.thresholds[i]:
                flags.set(f, -1)
                _ = out.push(OUT_ACHIEVEMENT, tick, i)
                n += 1
            else:
                flags.set(f, p)
        return n
