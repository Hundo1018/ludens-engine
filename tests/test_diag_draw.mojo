# tier: unit
"""`DrawQueue[dtype]` contract: pushing every command kind, `tick()` aging a
lifetime across multiple frames, capacity + drop counting, and the 0-commands
edge case. Uses `DType.float32` directly (not `geometry.WorldType`) to prove
`diag` needs no `geometry` import -- any dtype works, per the module
docstring's "points are `SIMD[dtype,4]` with `dtype` a struct parameter"."""

from harness.runner import Suite
from diag.draw import DrawQueue, Kind


def main() raises:
    var s = Suite("diag_draw")
    comptime dt = DType.float32
    var white = SIMD[DType.float32, 4](1, 1, 1, 1)

    # --- ordinary: one of each command kind ---
    var q = DrawQueue[dt](16)
    q.line(SIMD[dt, 4](0, 0, 0, 0), SIMD[dt, 4](1, 0, 0, 0), white)
    q.sphere(SIMD[dt, 4](0, 0, 0, 0), Scalar[dt](0.5), white)
    q.box(SIMD[dt, 4](0, 0, 0, 0), SIMD[dt, 4](1, 1, 1, 0), white)
    q.arrow(SIMD[dt, 4](0, 0, 0, 0), SIMD[dt, 4](0, 1, 0, 0), white)
    q.text(SIMD[dt, 4](0, 0, 0, 0), "hud", white)
    q.point(SIMD[dt, 4](0, 0, 0, 0), white)
    s.eqi(q.count(), 6, "ordinary: all six command kinds pushed")
    s.eqi(q.commands[4].kind, Kind.TEXT, "ordinary: text command kind tagged")
    s.check(q.commands[4].text == "hud", "ordinary: text payload carried through")
    s.eqi(q.commands[1].kind, Kind.SPHERE, "ordinary: sphere command kind tagged")

    # --- extreme: 0 commands -- tick() on an empty queue is a safe no-op ---
    var empty_q = DrawQueue[dt](8)
    empty_q.tick()
    s.eqi(empty_q.count(), 0, "0 commands: tick on empty queue stays empty")

    # --- extreme: lifetime spanning multiple frames ---
    var life_q = DrawQueue[dt](8)
    life_q.point(SIMD[dt, 4](0, 0, 0, 0), white, life=2)  # persists 2 more ticks
    life_q.point(SIMD[dt, 4](1, 0, 0, 0), white, life=0)  # this frame only
    s.eqi(life_q.count(), 2, "lifetime: both commands present before any tick")
    life_q.tick()
    s.eqi(life_q.count(), 1, "lifetime: life=0 command removed after 1st tick")
    life_q.tick()
    s.eqi(life_q.count(), 1, "lifetime: life=2 command still present after 2nd tick")
    life_q.tick()
    s.eqi(life_q.count(), 0, "lifetime: life=2 command gone after 3rd tick")

    # --- extreme: exactly-full, then overflow drop-newest + count ---
    var full_q = DrawQueue[dt](4)
    for i in range(4):
        full_q.point(SIMD[dt, 4](Scalar[dt](i), 0, 0, 0), white)
    s.eqi(full_q.count(), 4, "exactly-full: all 4 stored")
    s.eqi(full_q.dropped, 0, "exactly-full: nothing dropped yet")
    full_q.point(SIMD[dt, 4](99, 0, 0, 0), white)
    s.eqi(full_q.count(), 4, "overflow: count stays at capacity")
    s.eqi(full_q.dropped, 1, "overflow: exactly one drop counted")

    # --- extreme: zero capacity -- every push drops ---
    var zero_q = DrawQueue[dt](0)
    zero_q.point(SIMD[dt, 4](0, 0, 0, 0), white)
    zero_q.line(SIMD[dt, 4](0, 0, 0, 0), SIMD[dt, 4](1, 0, 0, 0), white)
    s.eqi(zero_q.count(), 0, "zero capacity: never stores anything")
    s.eqi(zero_q.dropped, 2, "zero capacity: every push counted as dropped")

    # --- clear() resets both commands and drop count ---
    full_q.clear()
    s.eqi(full_q.count(), 0, "clear: count reset")
    s.eqi(full_q.dropped, 0, "clear: dropped reset")

    s.finish()
