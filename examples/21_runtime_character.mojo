"""Example 21 — the gameplay stack end to end.

A `gameplay.runtime.Runtime` owns the ECS world, the physics scene, the fixed
60 Hz loop, contact events and timers. In it: a floor, a 0.2 m step and a crate.
A `CharacterController` walks toward the step, climbs it, walks off the far
side and bumps the crate along. Frames arrive at 144 Hz; the
crate is drawn with the interpolated pose between ticks. The example prints
the character's height as it goes, the crate's displacement, the contact
events the runtime published, and whether the rendered crate stays between
ticks.

Run:

    pixi run mojo run -I build examples/21_runtime_character.mojo
"""

from geometry.vec import Real, Vec3
from ecs.sparse_backend import SparseSetBackend
from ecs.transform import Transform
from physics.rigid6 import Inertia3, QuatBody6
from collision.contact_events import ContactEvent, EV_BEGAN
from gameplay.runtime import Runtime, RigidBodyRef
from gameplay.character import CharacterController

comptime Bk = SparseSetBackend[Transform, RigidBodyRef]
comptime Rt = Runtime[Bk, QuatBody6]
comptime TICK: Real = 1.0 / 60.0


def _st(p: Vec3) -> QuatBody6:
    return QuatBody6.at_rest(p, Inertia3.box(1, 1, 1, 1))


def main() raises:
    var rt = Rt(TICK, Vec3(0, -9.8, 0, 0))
    _ = rt.spawn_body(_st(Vec3(0, -1, 0, 0)), Vec3(30, 1, 30, 0), True)  # floor
    _ = rt.spawn_body(_st(Vec3(3, 0.1, 0, 0)), Vec3(1, 0.1, 2, 0), True)  # 0.2 m step
    var crate = rt.spawn_body(
        QuatBody6.at_rest(Vec3(5.2, 0.45, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)),
        Vec3(0.25, 0.25, 0.25, 0), False,
    )
    var reader = rt.events.register_reader()
    var c = CharacterController(Vec3(0, 0.92, 0, 0))
    var crate_x0 = Real(5.2)
    var began = 0
    var bounded = True
    var frame_t = Real(0)
    var next_tick = TICK
    for f in range(4 * 144):
        frame_t += 1.0 / 144.0
        _ = rt.advance(1.0 / 144.0)
        # the controller moves on the simulation clock: once per tick owed
        while frame_t >= next_tick:
            c.update(rt.scene, Vec3(1.5, 0, 0, 0), 0, TICK, Vec3(0, -9.8, 0, 0))
            next_tick += TICK
        var evs = List[ContactEvent]()
        rt.events.read(reader, evs)
        for k in range(len(evs)):
            if evs[k].kind == EV_BEGAN:
                began += 1
        var i = rt.world.get[RigidBodyRef](crate).id.index()
        if i < len(rt.history.curr):
            var r = rt.render_pose(crate)
            var lo = min(rt.history.prev[i].p[0], rt.history.curr[i].p[0]) - 1e-4
            var hi = max(rt.history.prev[i].p[0], rt.history.curr[i].p[0]) + 1e-4
            if r.p[0] < lo or r.p[0] > hi:
                bounded = False
        if f % 72 == 0:
            print("t", f // 144, ".", (f % 144) * 100 // 144, "s  character x", c.position[0],
                  " foot y", c.foot()[1], " grounded", c.on_ground)
    var crate_x = rt.scene.bset.bodies[rt.world.get[RigidBodyRef](crate).id.index()].position()[0]
    print("character climbed the 0.2 m step:", "YES" if c.position[0] > 4 else "NO")
    print("crate pushed by", crate_x - crate_x0, "m")
    print("contact BEGAN events published by the runtime:", began)
    print("rendered crate always between ticks:", "YES" if bounded else "NO")
