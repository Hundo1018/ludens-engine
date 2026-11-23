"""The scripted run `scripts/game_same.py` compares: native prints the numbers, the wasm64 app produces the same ones
through its `app_*` exports (D held for 240 frames, Space pressed on frame 10)."""
from game.demo_mode import DemoMode
from game.intent import Intent
from app.mesh_pass import mesh_probe_hash


def main() raises:
    var m = DemoMode()
    for f in range(240):
        m.step(Intent(0, 1, 0, 0, f == 10, False, False), 1.0 / 60.0)
    print("mesh_hash", mesh_probe_hash())
    print("hash", m.hash())
