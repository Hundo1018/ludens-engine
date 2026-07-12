"""Example 06 — geometric algebra motors: screw motion, interpolation, bones.

Three vignettes of the PGA layer:
  1. Screw dynamics — a body with angular AND linear velocity in ONE bivector,
     integrated exactly along its helix (`physics.screw`).
  2. Screw interpolation — `geodesic3` moves a pose along the screw axis
     between two motors (what slerp+lerp approximates, done in one motion).
  3. A 3-bone chain propagated by pure motor composition (`propagate_motor`),
     cross-checked against the classic quaternion path.

Run:

    pixi run mojo run -I build examples/06_ga_motor.mojo
"""

from ecs.world import World
from ecs.sparse_backend import SparseSetBackend
from ecs.transform import Parent
from ecs.motor_transform import MotorTransform, propagate_motor
from ecs.hierarchy import Hierarchy
from geometry.vec import Vec3
from geometry.quat import Quat
from geometry.motor import Motor3
from geometry.galie import geodesic3
from geometry.dualquat import DualQuat
from physics.screw import ScrewBody, screw_velocity, step_screw


def _p(label: String, v: Vec3):
    print(label, "(", v[0], ",", v[1], ",", v[2], ")")


def main():
    # --- 1. screw dynamics: spin about z while climbing it (a helix) ---
    print("== screw motion: ω=2rad/s about z, v=0.5/s along z ==")
    var body = ScrewBody.at_rest(Vec3(1, 0, 0))
    body.vel = screw_velocity(Vec3(0, 0, 2.0), Vec3(0, 0, 0.5))
    for i in range(5):
        body.pose = step_screw(body.pose, body.vel, 0.25)
        _p("  t=" + String(Float64(i + 1) * 0.25) + " ", body.position())

    # --- 2. screw interpolation between two poses ---
    print("== geodesic (screw) interpolation ==")
    var a = Motor3.identity()
    var b = Motor3.from_quat_translation(
        Quat.from_axis_angle(Vec3(0, 0, 1), 1.5708), Vec3(2, 0, 1)
    )
    for k in range(5):
        var t = Float32(k) * 0.25
        var m = geodesic3(a, b, t)
        _p("  t=" + String(t) + " origin ->", m.apply_point(Vec3(0, 0, 0)))

    # --- 3. a bone chain in the ECS, propagated by motor composition ---
    print("== 3-bone chain via propagate_motor ==")
    var w = World[SparseSetBackend[MotorTransform, Parent]]()
    var bend = Quat.from_axis_angle(Vec3(0, 0, 1), 0.5236)  # 30° per joint
    var root = w.spawn()
    w.set(root, MotorTransform.from_quat_translation(Quat.identity(), Vec3(0, 0, 0)))
    var upper = w.spawn()
    w.set(upper, MotorTransform.from_quat_translation(bend, Vec3(1, 0, 0)))
    w.set(upper, Parent(root.id))
    var lower = w.spawn()
    w.set(lower, MotorTransform.from_quat_translation(bend, Vec3(1, 0, 0)))
    w.set(lower, Parent(upper.id))

    var h = Hierarchy.build_for[MotorTransform](w)
    propagate_motor(w, h)
    var tip = w.get[MotorTransform](lower).world.apply_point(Vec3(1, 0, 0))
    _p("  fingertip (60° total bend):", tip)

    # same chain, classical composition, for comparison
    var q1 = bend
    var q12 = q1 * bend
    var classic = Vec3(1, 0, 0) + q1.rotate(Vec3(1, 0, 0)) + q12.rotate(Vec3(1, 0, 0))
    _p("  classical quat chain:     ", classic)

    # --- bonus: the dual-quaternion view of the same motor ---
    var dq = DualQuat.from_motor(b)
    _p("== dq(motor b) moves origin ->", dq.transform_point(Vec3(0, 0, 0)))
