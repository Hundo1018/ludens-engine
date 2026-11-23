"""Run a game headless over many seeds and print what each run ended with (`ludens sim`, docs/automation.md).

`simulate[M]` is generic over the `GameMode` seam, so a game in another repository gets a batch runner with a three-line
entry point (see `app/sim_main.mojo`). Each run is a fresh game started with `reset(seed, scene)`, stepped `ticks` frames of
1/60 s with one constant input, and written as one JSON line `{"seed":S,"state":<GameMode.state()>}`. The table, the
statistics and the choice of fields are `scripts/sim_batch.py`'s: it reads these lines."""
from game.intent import Intent
from game.mode import GameMode
from geometry.vec import Real


struct SimInput(Copyable, Movable):
    """The input every run is given: held movement, and a jump press every `jump_every` frames (0 = never)."""
    var forward: Real
    var right: Real
    var jump_every: Int

    def __init__(out self, forward: Real, right: Real, jump_every: Int):
        self.forward = forward
        self.right = right
        self.jump_every = jump_every

    def at(self, frame: Int) -> Intent:
        var jump = self.jump_every > 0 and frame % self.jump_every == 0
        return Intent(self.forward, self.right, Real(0), Real(0), jump, False, False)


def simulate[M: GameMode](seeds: List[UInt64], ticks: Int, scene: String, input: SimInput) raises:
    for seed in seeds:
        var m = M.create()
        if not m.reset(seed, scene):
            raise Error("sim: this game has no seeds or scenes (GameMode.reset returned False)")
        for frame in range(ticks):
            m.step(input.at(frame), 1.0 / 60.0)
        print(String('{"seed":') + String(seed) + String(',"state":') + m.state() + String("}"))
