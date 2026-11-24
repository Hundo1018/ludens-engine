"""`ludens sim demo`: the batch runner (game/batch.mojo) for the demo game, native and with no GPU.

    sim_main <seeds> <ticks> <scene> <forward> <right> <jump_every>

`seeds` is a comma-separated list of integers. Prints one JSON line per seed. scripts/sim_batch.py builds and runs this and
prints the table. A game in another repository makes its own entry the same way: `simulate[ItsMode](...)`."""
from game.action_map import ActionMap
from game.batch import SimInput, simulate
from game.demo_actions import DEMO_ACTIONS_TEXT
from game.demo_mode import DemoMode
from geometry.vec import Real
from std.sys import argv, exit, stderr


def main():
    var a = argv()
    if len(a) != 7:
        print("usage: sim_main <seeds> <ticks> <scene> <forward> <right> <jump_every>", file=stderr)
        exit(2)
    try:
        var seeds = List[UInt64]()
        for part in String(a[1]).split(","):
            seeds.append(UInt64(atol(String(part))))
        # the same jump window the app gives the game through its action map, so a batch run and a wasm64 run take one path
        var window = ActionMap.parse(DEMO_ACTIONS_TEXT).buffer_ms("jump")
        var input = SimInput(Real(atof(String(a[4]))), Real(atof(String(a[5]))), atol(String(a[6])), Real(window))
        simulate[DemoMode](seeds, atol(String(a[2])), String(a[3]), input)
    except e:
        print("sim:", String(e), file=stderr)
        exit(1)
