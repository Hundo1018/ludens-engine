# tier: system
"""A body carried from one level's runtime into the next (ROADMAP 17.72,
`Runtime.carry_to`).

  1. Ordinary: a box thrown at (2, 3, 0) m/s with damping 0.3 / 0.1,
     gravity scale 0.5, velocity caps, a z lock, friction 0.2,
     restitution 0.4; carried after 20 frames into a second runtime: its
     pose and velocities equal the source's bit for bit and every setting
     is the same; the entity and body are gone from the source.
  2. Integration: 30 more frames in the new runtime equal 30 more frames
     of an identical runtime that never carried it (mid-air, so no
     contact cache is involved), bit for bit.
  3. Extreme: a sphere carries too; a static body and a removed entity
     raise.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from ecs.sparse_backend import SparseSetBackend
from ecs.transform import Transform
from ecs.entity import Entity
from physics.rigid6 import Inertia3, QuatBody6
from gameplay.runtime import Runtime, RigidBodyRef

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime Bk = SparseSetBackend[Transform, RigidBodyRef]
comptime Rt = Runtime[Bk, QuatBody6]


def level() raises -> Rt:
    var rt = Rt(DT, G)
    _ = rt.spawn_body(QuatBody6.at_rest(Vec3(0, -50.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    return rt^


def thrown(mut rt: Rt) raises -> Entity:
    var b = QuatBody6.at_rest(Vec3(0, 2, 0, 0), Inertia3.box(3, 0.3, 0.2, 0.1))
    b.vel = Vec3(2, 3, 0, 0)
    b.omega = Vec3(0.5, 1, 0, 0)
    var e = rt.spawn_body(b^, Vec3(0.3, 0.2, 0.1, 0), False)
    rt.set_damping(e, 0.3, 0.1)
    rt.set_gravity_scale(e, 0.5)
    rt.set_max_velocity(e, 8, 6)
    rt.set_axis_locks(e, False, False, True, False, False, False)
    var i = rt.body_of(e).index()
    rt.scene.set_friction(i, 0.2)
    rt.scene.set_restitution(i, 0.4)
    return e


def same_state(a: Rt, ea: Entity, b: Rt, eb: Entity) raises -> Bool:
    var ba = a.scene.bset.bodies[a.body_of(ea).index()].copy()
    var bb = b.scene.bset.bodies[b.body_of(eb).index()].copy()
    for c in range(3):
        if ba.position()[c] != bb.position()[c] or ba.vel[c] != bb.vel[c] or ba.omega[c] != bb.omega[c]:
            return False
    var qa = ba.rotation()
    var qb = bb.rotation()
    return qa.x == qb.x and qa.y == qb.y and qa.z == qb.z and qa.w == qb.w


def main() raises:
    var s = Suite("runtime_carry")
    var a = level()
    var e = thrown(a)
    var ctl = level()
    var ec = thrown(ctl)
    for _ in range(20):
        _ = a.advance(Float64(DT))
        _ = ctl.advance(Float64(DT))
    var b = level()
    var bodies_before = len(b.scene.bset.bodies)
    var eb = a.carry_to(e, b)
    s.check(same_state(ctl, ec, b, eb), "carried: pose and velocities equal the source's, bit for bit")
    var i = b.body_of(eb).index()
    ref bs = b.scene.bset
    var ok = bs.lin_damping[i] == 0.3 and bs.ang_damping[i] == 0.1 and bs.gravity_scale[i] == 0.5
    ok = ok and bs.max_lin[i] == 8 and bs.max_ang[i] == 6 and bs.locks[i] == 4 and bs.friction[i] == 0.2 and bs.restitution[i] == 0.4
    s.check(ok, "damping, gravity scale, caps, lock, friction, restitution carried")
    s.check(len(b.scene.bset.bodies) == bodies_before + 1 and not a.world.is_alive(e), "the body joins the new level and leaves the old one")
    for _ in range(30):
        _ = b.advance(Float64(DT))
        _ = ctl.advance(Float64(DT))
    var p = b.scene.bset.bodies[i].position()
    print("  carried at frame 20; after 30 more frames: y", p[1], " vx", b.scene.bset.bodies[i].vel[0])
    s.check(same_state(ctl, ec, b, eb), "30 frames after the carry == the uncarried run, bit for bit")

    var sa = level()
    var ball = QuatBody6.at_rest(Vec3(1, 1, 0, 0), Inertia3.sphere(1, 0.25))
    var es = sa.spawn_sphere(ball^, 0.25, False)
    var sb = level()
    var es2 = sa.carry_to(es, sb)
    s.check(sb.scene.colliders.half[sb.body_of(es2).index()][0] == 0.25, "a sphere carries with its radius")
    var raised = 0
    try:
        var fl = a.world.spawn()
        _ = fl
        var st = a.spawn_body(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(1, 1, 1, 0), True)
        _ = a.carry_to(st, b)
    except:
        raised += 1
    try:
        _ = a.carry_to(e, b)  # already carried away
    except:
        raised += 1
    s.check(raised == 2, "static body and an entity no longer here raise")
    s.finish()
