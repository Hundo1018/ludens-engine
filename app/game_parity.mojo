"""The scripted run `scripts/game_parity.py` compares: native prints the numbers, the wasm64 app produces the same ones
through its `app_*` exports (D held for 240 frames, Space pressed on frame 10, chasers on)."""
from game.arena import Arena
from game.intent import Intent


def main() raises:
    var a = Arena()
    for f in range(240):
        a.update(Intent(0, 1, 0, 0, f == 10, False, False), 1.0 / 60.0)
    print("hash", a.hash(), "score", a.score, "collected", a.collected(), "status", a.status())
