"""Time resolution for a system pack (ROADMAP 17.85): `TieredScheduler`.

Wraps any `Scheduler` and runs its `tick` only on every `period`-th step,
offset by `phase`, so a coarse group of systems (far-away AI, ambient life)
can run at a fraction of the fixed rate while the loop keeps one dt. With
`period == 1` it is the inner scheduler (the parity anchor,
`test_tiers_parity`). Systems that read the elapsed time must scale by
`period` themselves; `ran_last` tells whether the last `tick` ran.
"""

from ecs.world import World
from .scheduler import Scheduler


struct TieredScheduler[S: Scheduler](Scheduler):
    comptime B = Self.S.B
    var inner: Self.S
    var period: Int
    var phase: Int
    var step: Int
    var ticks_run: Int
    var ran_last: Bool

    def __init__(out self):
        self.inner = Self.S()
        self.period = 1
        self.phase = 0
        self.step = 0
        self.ticks_run = 0
        self.ran_last = False

    def set_rate(mut self, period: Int, phase: Int = 0) raises:
        if period < 1 or phase < 0:
            raise Error("TieredScheduler.set_rate: period >= 1, phase >= 0")
        self.period = period
        self.phase = phase % period

    def tick(mut self, mut world: World[Self.B]):
        self.ran_last = (self.step + self.phase) % self.period == 0
        if self.ran_last:
            self.inner.tick(world)
            self.ticks_run += 1
        self.step += 1
