"""G3 parity: motor-based hierarchy propagation vs the matrix path, and screw
dynamics vs analytic motion.

Tree parity builds the SAME 7-node hierarchy (root → 2 children → 4 leaves,
random rigid TRS, scale = 1) in two worlds — `Transform` + `propagate_full` and
`MotorTransform` + `propagate_motor` — then checks every node's world transform
moves a probe point identically. Screw integration is checked against closed
forms (pure translation, pure rotation vs `Quat`, helix step-invariance)."""

from harness.runner import Suite
from scheduler.rng import SplitMix64, Rng
from ecs.world import World
from ecs.sparse_backend import SparseSetBackend
from ecs.transform import Transform, Parent
from ecs.transform_systems import propagate_full
from ecs.motor_transform import MotorTransform, propagate_motor
from ecs.hierarchy import Hierarchy
from geometry.vec import Real, Vec3, normalize
from geometry.quat import Quat
from geometry.mat import transform_point4
from geometry.motor import Motor3
from geometry.galie import Screw3
from physics.screw import ScrewBody, screw_velocity, step_screw, integrate_screw


def _near3(mut s: Suite, a: Vec3, b: Vec3, label: String, tol: Float64 = 1e-3):
    s.almost(Float64(a[0]), Float64(b[0]), label + " .x", tol)
    s.almost(Float64(a[1]), Float64(b[1]), label + " .y", tol)
    s.almost(Float64(a[2]), Float64(b[2]), label + " .z", tol)


def main() raises:
    var s = Suite("motor_transform")
    var rng = SplitMix64.seeded(11)

    # ---------- hierarchy parity: matrix path vs motor path ----------
    comptime WM = World[SparseSetBackend[Transform, Parent]]
    comptime WG = World[SparseSetBackend[MotorTransform, Parent]]
    var wm = WM()
    var wg = WG()

    var parents = [-1, 0, 0, 1, 1, 2, 2]  # 7-node tree by spawn order
    var ids = List[Int]()
    for k in range(7):
        var axis = normalize(
            Vec3(
                Real(rng.next_f32()) + 0.1,
                Real(rng.next_f32()) + 0.2,
                Real(rng.next_f32()) + 0.3,
            )
        )
        var angle = Real(rng.next_f32()) * 2.0 - 1.0
        var q = Quat.from_axis_angle(axis, angle)
        var t = Vec3(
            Real(rng.next_f32()) * 2 - 1,
            Real(rng.next_f32()) * 2 - 1,
            Real(rng.next_f32()) * 2 - 1,
        )

        var em = wm.spawn()
        wm.set(em, Transform.at(t).with_rotation(q))
        var eg = wg.spawn()
        wg.set(eg, MotorTransform.from_quat_translation(q, t))
        ids.append(em.id)
        if parents[k] >= 0:
            wm.set(em, Parent(ids[parents[k]]))
            wg.set(eg, Parent(ids[parents[k]]))

    var hm = Hierarchy.build(wm)
    var hg = Hierarchy.build_for[MotorTransform](wg)
    propagate_full(wm, hm)
    propagate_motor(wg, hg)

    var probe = Vec3(0.7, -0.3, 1.1)
    for k in range(len(hm.order)):
        var e = hm.order[k]
        var tm = wm.get[Transform](e)
        var tg = wg.get[MotorTransform](e)
        _near3(
            s,
            tg.world.apply_point(probe),
            transform_point4(tm.world, probe),
            "node world: motor == matrix",
        )

    # ---------- screw dynamics vs closed forms ----------
    # pure translation: v = (2,0,0) for dt=0.5 moves +1 in x
    var b0 = ScrewBody.at_rest(Vec3(0, 0, 0))
    b0.vel = screw_velocity(Vec3(0, 0, 0), Vec3(2, 0, 0))
    var p1 = step_screw(b0.pose, b0.vel, 0.5).apply_point(Vec3(0, 0, 0))
    _near3(s, p1, Vec3(1, 0, 0), "screw: pure translation")

    # pure rotation: ω = π about z for dt=0.5 → rotate π/2, matches Quat
    var wz = screw_velocity(Vec3(0, 0, 3.14159265), Vec3(0, 0, 0))
    var rot = step_screw(Motor3.identity(), wz, 0.5)
    var qz = Quat.from_axis_angle(Vec3(0, 0, 1), 3.14159265 * 0.5)
    _near3(
        s,
        rot.apply_point(Vec3(1, 0, 0)),
        qz.rotate(Vec3(1, 0, 0)),
        "screw: pure rotation == quat",
    )

    # helix: constant screw — one big step equals ten small steps (exact flow)
    var vel = screw_velocity(Vec3(0, 0, 2.0), Vec3(0, 0, 1.0))
    var big = step_screw(Motor3.identity(), vel, 1.0)
    var small = Motor3.identity()
    for _ in range(10):
        small = step_screw(small, vel, 0.1)
    _near3(
        s,
        big.apply_point(Vec3(1, 0, 0)),
        small.apply_point(Vec3(1, 0, 0)),
        "screw: 1 big step == 10 small (exact helix)",
    )

    # ---------- ECS system: integrate_screw over a world ----------
    var ws = World[SparseSetBackend[ScrewBody]]()
    var e1 = ws.spawn()
    var sb = ScrewBody.at_rest(Vec3(0, 1, 0))
    sb.vel = screw_velocity(Vec3(0, 0, 0), Vec3(1, 0, 0))
    ws.set(e1, sb)
    for _ in range(4):
        integrate_screw(ws, 0.25)
    _near3(
        s, ws.get[ScrewBody](e1).position(), Vec3(1, 1, 0),
        "integrate_screw: linear parity (v·t)",
    )

    s.finish()
