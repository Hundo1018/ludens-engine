# tier: system
"""Timer fires delivered by the runtime (ROADMAP 17.72, `Runtime.take_fired`).

Before, `Runtime._tick` advanced the timer queue and dropped what fired.

  1. Ordinary: timers at ticks 3 (id 7) and 5 (id 9, repeating every 4)
     over 13 one-tick frames: `take_fired` returns (7 @ 3), (9 @ 5),
     (9 @ 9), (9 @ 13) in order, each once; a second call is empty.
  2. Integration: a flow state without `TICK_TIMERS` (a pause) fires
     nothing and the queue does not advance; after the pause the timer
     fires on its tick counted in timer ticks.
  3. Extreme: capacity 2 and 5 fires not taken: 2 kept (the oldest), 3
     counted in `TIMER_FIRES_DROPPED`.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from ecs.sparse_backend import SparseSetBackend
from ecs.transform import Transform
from physics.rigid6 import QuatBody6
from diag.counters import TIMER_FIRES_DROPPED
from gameplay.runtime import Runtime, RigidBodyRef
from gameplay.flow import TICK_SIM

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime Bk = SparseSetBackend[Transform, RigidBodyRef]
comptime Rt = Runtime[Bk, QuatBody6]


def main() raises:
    var s = Suite("runtime_fired")

    var rt = Rt(DT, G)
    _ = rt.timers.schedule(3, 7)
    _ = rt.timers.schedule(5, 9, repeat_every=4)
    for _ in range(13):
        _ = rt.advance(Float64(DT))
    var f = rt.take_fired()
    var line = String()
    for e in f:
        line += " (" + String(e.id) + " @ " + String(e.due_tick) + ")"
    print("  fired over 13 ticks:" + line)
    var ok = len(f) == 4 and f[0].id == 7 and f[0].due_tick == 3 and f[1].id == 9 and f[1].due_tick == 5
    ok = ok and f[2].due_tick == 9 and f[3].due_tick == 13
    s.check(ok, "fires delivered in order: 7 @ 3, 9 @ 5, 9 @ 9, 9 @ 13")
    s.check(len(rt.take_fired()) == 0, "taken once: the next call is empty")

    var p = Rt(DT, G)
    _ = p.timers.schedule(4, 1)
    _ = p.advance(Float64(DT))
    p.flow.push(2, TICK_SIM)  # a state that does not tick timers
    for _ in range(10):
        _ = p.advance(Float64(DT))
    var during = len(p.take_fired())
    var t_during = p.timers.current_tick()
    _ = p.flow.pop()
    for _ in range(3):
        _ = p.advance(Float64(DT))
    var after = p.take_fired()
    print("  paused 10 frames: fires", during, " timer tick", t_during, "; 3 frames after: fires", len(after), "at timer tick", after[0].due_tick if len(after) > 0 else -1)
    s.check(during == 0 and t_during == 1, "no TICK_TIMERS: nothing fires, the queue stays at tick 1")
    s.check(len(after) == 1 and after[0].due_tick == 4, "after the pause it fires on timer tick 4")

    var c = Rt(DT, G, fired_capacity=2)
    for k in range(5):
        _ = c.timers.schedule(k + 1, 100 + k)
    for _ in range(5):
        _ = c.advance(Float64(DT))
    var kept = c.take_fired()
    var dropped = c.loop.counters.get(TIMER_FIRES_DROPPED)
    print("  capacity 2, 5 fires untaken: kept", len(kept), " dropped", dropped)
    s.check(len(kept) == 2 and kept[0].id == 100 and kept[1].id == 101 and dropped == 3, "capacity 2: oldest 2 kept, 3 dropped and counted")
    s.finish()
