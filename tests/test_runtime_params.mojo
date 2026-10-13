# tier: system
"""`Runtime` exposure of the per-body parameters (ROADMAP 17.48).

  1. Ordinary: by entity, gravity_scale 0 floats a ball through 30 fixed
     ticks, and a 60 N force for one tick moves a 1 kg ball at 1 m/s.
  2. Integration: the setter reaches the same body the scene sees
     (`body_of`), and damping set through the runtime shows in the scene.
  3. Extreme: a setter while a step is in flight raises and changes nothing.
  4. ROADMAP 17.49: a ball dropped on a floor -- the BEGAN event read from the
     runtime's channel carries the impact impulse (m v + m g dt).
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from ecs.sparse_backend import SparseSetBackend
from ecs.transform import Transform
from physics.rigid6 import Inertia3, QuatBody6
from gameplay.runtime import Runtime, RigidBodyRef
from collision.contact_events import ContactEvent, EV_BEGAN

comptime DT: Real = 1.0 / 60.0
comptime Bk = SparseSetBackend[Transform, RigidBodyRef]
comptime Rt = Runtime[Bk, QuatBody6]


def main() raises:
    var s = Suite("runtime_params")
    var rt = Rt(DT, Vec3(0, -9.8, 0, 0))
    var floater = rt.spawn_sphere(QuatBody6.at_rest(Vec3(0, 10, 0, 0), Inertia3.sphere(1, 0.5)), 0.5, False)
    var pushed = rt.spawn_sphere(QuatBody6.at_rest(Vec3(5, 10, 0, 0), Inertia3.sphere(1, 0.5)), 0.5, False)
    rt.set_gravity_scale(floater, 0)
    rt.set_gravity_scale(pushed, 0)
    rt.add_force(pushed, Vec3(60, 0, 0, 0))
    for _ in range(30):
        _ = rt.advance(Float64(DT))
    print("  floater vy", rt.velocity(floater)[1], " pushed vx", rt.velocity(pushed)[0])
    s.check(rt.velocity(floater)[1] == 0, "gravity_scale 0 through the runtime: floats")
    s.check(abs(rt.velocity(pushed)[0] - 1) < 1e-6, "60 N for one tick on 1 kg: 1 m/s")

    rt.set_damping(floater, 3, 0)
    var id = rt.body_of(floater)
    s.check(rt.scene.bset.lin_damping[id.index()] == 3, "runtime setter writes the scene's body")

    var h = rt.begin_advance(Float64(DT))
    var raised = False
    try:
        rt.set_gravity_scale(floater, 1)
    except:
        raised = True
    s.check(raised and rt.scene.bset.gravity_scale[id.index()] == 0, "setter in flight raises, value unchanged")
    rt.execute(h)
    _ = rt.finish(h)

    var rd = Rt(DT, Vec3(0, -9.8, 0, 0))
    _ = rd.spawn_body(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    var ball = QuatBody6.at_rest(Vec3(0, 0.52, 0, 0), Inertia3.sphere(1, 0.5))
    ball.vel = Vec3(0, -4, 0, 0)
    _ = rd.spawn_sphere(ball^, 0.5, False)
    var reader = rd.events.register_reader()
    var hit = Real(-1)
    for _ in range(10):
        _ = rd.advance(Float64(DT))
        var evs = List[ContactEvent]()
        rd.events.read(reader, evs)
        for k in range(len(evs)):
            if evs[k].kind == EV_BEGAN and hit < 0:
                hit = evs[k].impulse
    print("  runtime channel: began impulse", hit)
    s.check(abs(hit - (4 + 9.8 * DT)) < 0.05 * 4, "the runtime's event channel carries the 17.49 impulse payload")
    s.finish()
