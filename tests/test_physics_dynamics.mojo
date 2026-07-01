"""Rigid-body contact solving: per-solver behaviour + cross-solver rest parity.

- rest_test (all 3 solvers): a box dropped on a static floor settles at the
  expected height with no penetration and near-zero velocity — the invariant
  every solver must satisfy (the swap-seam parity check).
- restitution_swap (SequentialImpulse): an elastic head-on hit of equal masses
  swaps velocities and conserves momentum.
- friction_decel (SequentialImpulse): a sliding box on a frictional floor loses
  horizontal speed without reversing.
"""

from harness.runner import Suite
from geometry.vec import Vec2
from physics.rigidbody import RigidBody
from physics.solver import ContactSolver, SequentialImpulse, Pbd, Xpbd
from physics.step import PhysicsWorld


def rest_test[S: ContactSolver](mut s: Suite, tag: String) raises:
    var w = PhysicsWorld[2, S](Vec2(0, -10), 10)
    # floor: static box, top edge at y = 0
    _ = w.add(RigidBody[2].static_box(Vec2(0, -1), Vec2(10, 1)))
    # dynamic unit box dropped from y = 3 -> should rest with center at y = 0.5
    var box = w.add(RigidBody[2].dynamic(Vec2(0, 3), Vec2(0.5, 0.5), 1.0))
    for _ in range(240):  # 4 s at 1/60
        w.step(1.0 / 60.0)
    var b = w.body(box)
    s.almost(Float64(b.pos[1]), 0.5, tag + " rests at y=0.5", 0.05)
    s.check(b.pos[1] >= 0.47, tag + " no sink")
    s.check(Float64(b.vel[1]) > -0.5 and Float64(b.vel[1]) < 0.5, tag + " ~at rest")


def restitution_swap(mut s: Suite) raises:
    var w = PhysicsWorld[2, SequentialImpulse](Vec2(0, 0), 20)
    _ = w.add(
        RigidBody[2]
        .dynamic(Vec2(0, 0), Vec2(0.5, 0.5), 1.0, 1.0, 0.0)
        .with_velocity(Vec2(2, 0))
    )
    _ = w.add(RigidBody[2].dynamic(Vec2(0.999, 0), Vec2(0.5, 0.5), 1.0, 1.0, 0.0))
    w.step(1.0 / 60.0)
    var a = w.body(0)
    var b = w.body(1)
    s.almost(Float64(a.vel[0]), 0.0, "elastic: A stops", 0.05)
    s.almost(Float64(b.vel[0]), 2.0, "elastic: B takes velocity", 0.05)
    s.almost(Float64(a.vel[0] + b.vel[0]), 2.0, "momentum conserved", 0.05)


def friction_decel(mut s: Suite) raises:
    var w = PhysicsWorld[2, SequentialImpulse](Vec2(0, -10), 20)
    _ = w.add(RigidBody[2].static_box(Vec2(0, -1), Vec2(10, 1), 0.0, 0.8))
    _ = w.add(
        RigidBody[2]
        .dynamic(Vec2(0, 0.499), Vec2(0.5, 0.5), 1.0, 0.0, 0.8)
        .with_velocity(Vec2(3, 0))
    )
    for _ in range(60):
        w.step(1.0 / 60.0)
    var b = w.body(1)
    s.check(Float64(b.vel[0]) < 3.0, "friction decelerates")
    s.check(Float64(b.vel[0]) >= -0.05, "friction does not reverse")


def main() raises:
    var s = Suite("physics_dynamics")
    rest_test[SequentialImpulse](s, "impulse")
    rest_test[Pbd](s, "pbd")
    rest_test[Xpbd](s, "xpbd")
    restitution_swap(s)
    friction_decel(s)
    s.finish()
