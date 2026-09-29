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
from diag.counters import Counters, GAMELOOP_DEBT_DROPPED


@fieldwise_init
struct FixedLoop(Movable, Deinitable):
    var dt: Float64  # fixed simulation step (seconds)
    var accumulator: Float64
    var max_steps: Int  # cap on ticks per advance() — spiral-of-death guard
    var alpha: Float64  # leftover fraction in [0,1) after a non-clamped advance
    var counters: Counters
    """ROADMAP 17.0h / audit E22/F16: `GAMELOOP_DEBT_DROPPED` bumps every
    time `advance` hits `max_steps` with time still owed -- see `advance`."""

    @staticmethod
    def new(dt: Float64, max_steps: Int = 8) -> Self:
        return Self(dt, 0.0, max_steps, 0.0, Counters())

    def advance[S: Scheduler](
        mut self, mut sched: S, mut world: World[S.B], frame_dt: Float64
    ) -> Int:
        """Accumulate `frame_dt`, tick `sched` once per whole `dt`, return tick count.

        `dt <= 0` (audit E22) would make the `while` condition either loop
        forever (`dt == 0`: `accumulator` never drops below it) or never run
        (`dt < 0`: immediately false) while `alpha = accumulator / dt` comes
        out `inf`/negative either way -- `debug_assert` rather than `raise`:
        `FixedLoop.new` is the validating boundary a caller would use if `dt`
        came from untrusted input; `advance` runs every frame, so this is
        the same "hot path debug_asserts, construction is where a caller
        opts into raising" split as `SolverConfig`/`step`."""
        debug_assert(self.dt > 0, "FixedLoop.advance: dt must be > 0")
        self.accumulator += frame_dt
        var steps = 0
        while self.accumulator >= self.dt and steps < self.max_steps:
            sched.tick(world)
            self.accumulator -= self.dt
            steps += 1
        if self.accumulator >= self.dt:
            # audit E22/F16: `max_steps` clamped a frame-rate spike with time
            # still owed. Carrying that debt into next frame's accumulator
            # would just repeat this same clamp every frame after a single
            # bad one (or worse, grow unbounded, pushing `alpha` outside
            # [0, 1)) -- drop the excess now, once, and count it, rather
            # than let it silently compound.
            self.counters.incr(GAMELOOP_DEBT_DROPPED)
            self.accumulator = 0
        self.alpha = self.accumulator / self.dt
        return steps
