"""Fixed-timestep driver: decouple simulation rate from frame rate.

`FixedLoop` is the canonical accumulator loop. Feed it the real elapsed frame
time; it runs as many fixed `dt` simulation ticks as have accumulated (capped by
`max_steps` to defuse the spiral of death), and exposes `alpha` — the leftover
fraction of a step — for render-time interpolation. It drives *any* `Scheduler`
over `World[S.B]`, recovering the backend from the scheduler's associated type,
exactly like the parity driver in the scheduler tests. No changes to `Scheduler`
or `World` are required.
"""

from .scheduler import Scheduler
from ecs.world import World


@fieldwise_init
struct FixedLoop(Movable, ImplicitlyDeletable):
    var dt: Float64  # fixed simulation step (seconds)
    var accumulator: Float64
    var max_steps: Int  # cap on ticks per advance() — spiral-of-death guard
    var alpha: Float64  # leftover fraction in [0,1) after a non-clamped advance

    @staticmethod
    def new(dt: Float64, max_steps: Int = 8) -> Self:
        return Self(dt, 0.0, max_steps, 0.0)

    def advance[S: Scheduler](
        mut self, mut sched: S, mut world: World[S.B], frame_dt: Float64
    ) -> Int:
        """Accumulate `frame_dt`, tick `sched` once per whole `dt`, return tick count."""
        self.accumulator += frame_dt
        var steps = 0
        while self.accumulator >= self.dt and steps < self.max_steps:
            sched.tick(world)
            self.accumulator -= self.dt
            steps += 1
        self.alpha = self.accumulator / self.dt
        return steps
