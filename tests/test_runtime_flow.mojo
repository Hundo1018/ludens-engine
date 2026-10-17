# tier: system
"""Runtime under a flow state stack (ROADMAP 17.72, `Runtime.flow`).

A floor and 5 falling boxes; 60 Hz frames.

  1. Pause is exact: run 40 frames, push Paused (events only) for 30
     frames, push a Menu over it (nothing ticks) for 10 frames, pop both,
     run 80 more. The scene bytes and the timer tick equal a straight
     120-frame run; while paused the scene bytes and the timer tick do not
     move, and the paused frames leave no owed ticks behind.
  2. Masks gate parts separately: a state with `TICK_SIM` but not
     `TICK_EVENTS` steps the world (boxes land) and forwards no contact
     events (an all-ticks run of the same world forwards some);
     `TICK_TIMERS` alone advances timers without stepping.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from ecs.sparse_backend import SparseSetBackend
from ecs.transform import Transform
from physics.rigid6 import Inertia3, QuatBody6
from physics.serialize import scene_to_bytes
from collision.contact_events import ContactEvent
from gameplay.runtime import Runtime, RigidBodyRef
from gameplay.flow import TICK_ALL, TICK_SIM, TICK_TIMERS, TICK_EVENTS

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime Bk = SparseSetBackend[Transform, RigidBodyRef]
comptime Rt = Runtime[Bk, QuatBody6]
comptime PLAYING = 1
comptime PAUSED = 2
comptime MENU = 3


def world() raises -> Rt:
    var rt = Rt(DT, G)
    _ = rt.spawn_body(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    for k in range(5):
        _ = rt.spawn_body(QuatBody6.at_rest(Vec3(Real(k) - 2, 1 + Real(k) * 0.4, 0, 0), Inertia3.box(1, 0.3, 0.3, 0.3)), Vec3(0.3, 0.3, 0.3, 0), False)
    _ = rt.timers.schedule(1000, 1)
    return rt^


def same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for k in range(len(a)):
        if a[k] != b[k]:
            return False
    return True


def frames(mut rt: Rt, n: Int) raises:
    for _ in range(n):
        _ = rt.advance(Float64(DT))


def main() raises:
    var s = Suite("runtime_flow")
    var a = world()
    frames(a, 120)

    var b = world()
    b.flow.push(PLAYING, TICK_ALL)
    frames(b, 40)
    var before = scene_to_bytes(b.scene)
    var t_before = b.timers.current_tick()
    b.flow.push(PAUSED, TICK_EVENTS)
    frames(b, 30)
    b.flow.push(MENU, 0)
    frames(b, 10)
    var during = scene_to_bytes(b.scene)
    var t_during = b.timers.current_tick()
    _ = b.flow.pop()
    _ = b.flow.pop()
    frames(b, 80)
    print("pause: timer tick before / after the pause", t_before, t_during, " end", a.timers.current_tick(), b.timers.current_tick(), " accumulator", b.loop.accumulator < Float64(DT))
    s.check(same(before, during) and t_before == t_during, "nothing moves while paused or in the menu")
    s.check(same(scene_to_bytes(a.scene), scene_to_bytes(b.scene)) and a.timers.current_tick() == b.timers.current_tick(), "pause 40 frames then resume == straight run, bit for bit")
    s.check(b.loop.accumulator < Float64(DT), "paused frames leave no owed ticks")

    var ctl = world()
    var c = world()
    var rd0 = ctl.events.register_reader()
    var rd = c.events.register_reader()
    c.flow.push(PLAYING, TICK_SIM)
    var loud = 0
    var quiet = 0
    for _ in range(90):
        _ = ctl.advance(Float64(DT))
        _ = c.advance(Float64(DT))
        var e0 = List[ContactEvent]()
        var e1 = List[ContactEvent]()
        ctl.events.read(rd0, e0)
        c.events.read(rd, e1)
        loud += len(e0)
        quiet += len(e1)
    var landed = c.scene.bset.bodies[1].position()[1] < 0.5
    c.flow.push(PLAYING, TICK_TIMERS)
    var cb = scene_to_bytes(c.scene)
    var tt = c.timers.current_tick()
    frames(c, 10)
    print("masks: contact events all / sim-only", loud, quiet, " timer tick under sim-only", tt, " under timers-only", c.timers.current_tick())
    s.check(landed and loud > 0 and quiet == 0 and tt == 0, "TICK_SIM alone: the world steps, no contact events, no timers")
    s.check(same(cb, scene_to_bytes(c.scene)) and c.timers.current_tick() == 10, "TICK_TIMERS alone: timers advance, the world does not")
    s.finish()
