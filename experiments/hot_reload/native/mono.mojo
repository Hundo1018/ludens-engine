"""The engine and its main loop as one ordinary program (no .so, no swap).

The ordinary path in compile_speed.py: edit engine.mojo, build this, start it,
replay the matrix protocol (30 frames, despawn 2 and 5, 40 frames) to reach
the state the hot path keeps.

    mojo build -I build -I experiments/hot_reload/native experiments/hot_reload/native/mono.mojo
"""

from engine import engine_count, engine_despawn, engine_frame, engine_init, engine_state_size, engine_update
from hotswap import CAPACITY, DT, block


def main() raises:
    var s = block(engine_state_size())
    engine_init(s, CAPACITY)
    for _ in range(30):
        engine_update(s, DT)
    engine_despawn(s, 2)
    engine_despawn(s, 5)
    for _ in range(40):
        engine_update(s, DT)
    print("frame=", engine_frame(s), " count=", engine_count(s), sep="")
