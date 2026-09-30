"""mono.mojo, but every engine export is called, so none of the
engine's code is dead in the program (compile_speed.py, exe_all_O3).
"""

from engine import (
    engine_body_count,
    engine_body_x,
    engine_color,
    engine_count,
    engine_despawn,
    engine_destroy,
    engine_draw_x,
    engine_frame,
    engine_grid_sum,
    engine_init,
    engine_key_at,
    engine_label_addr,
    engine_label_byte,
    engine_label_len,
    engine_layout_id,
    engine_load,
    engine_module_addr,
    engine_save,
    engine_state_size,
    engine_trail_len,
    engine_trail_sum,
    engine_update,
)
from hotswap import CAPACITY, DT, block, free_buffer


def main() raises:
    var s = block(engine_state_size())
    engine_init(s, CAPACITY)
    for _ in range(30):
        engine_update(s, DT)
    engine_despawn(s, 2)
    engine_despawn(s, 5)
    for _ in range(40):
        engine_update(s, DT)
    var buf = engine_save(s)
    engine_destroy(s)
    var rc = engine_load(s, buf)
    free_buffer(buf)
    var acc = engine_layout_id() + Int(engine_color()) + engine_module_addr() % 7
    acc += engine_key_at(s, 0) + Int(engine_draw_x(s, 0)) + engine_label_len(s) + engine_label_byte(s, 0)
    acc += engine_label_addr(s) % 7 + engine_trail_len(s) + engine_trail_sum(s) + engine_grid_sum(s)
    acc += engine_body_count(s) + engine_body_x(s, 0)
    print("frame=", engine_frame(s), " count=", engine_count(s), " load=", rc, " acc=", acc % 1000, sep="")
