"""GA benchmark: rigid-transform representations head-to-head.

The same workload — apply N random rigid transforms to a point, and compose N
pairs — through three representations: PGA motor (8 floats), dual quaternion
(8 floats), and the classical Mat4 (16) / Quat+Vec3 paths. Timings use the
hardened harness (`measure`: warmup + min-of-reps, pin with taskset).

Run: taskset -c 3 pixi run mojo run -I build benchmarks/bench_ga.mojo
"""

from std.benchmark import keep
from harness.bench import BenchTable, measure
from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real, Vec3, normalize
from geometry.quat import Quat, compose_trs4
from geometry.mat import Mat4, transform_point4
from geometry.motor import Motor3
from geometry.dualquat import DualQuat
from geometry.skinning import SkinVert, skin_motor, skin_lbs


def main() raises:
    var table = BenchTable("rigid transforms: motor vs dual quat vs mat4 vs quat")
    comptime N = 4096
    var rng = SplitMix64.seeded(3)

    # --- build N random rigid transforms in every representation ---
    var quats = List[Quat]()
    # Struct-wrapped: bare width-3 lists crashed the runtime at teardown when
    # several were captured by closures in one program (see SkinVert's note;
    # capacity pre-sizing alone did NOT fix it).
    var trans = List[SkinVert]()
    var motors = List[Motor3]()
    var dqs = List[DualQuat]()
    var mats = List[Mat4]()
    for _ in range(N):
        var axis = normalize(
            Vec3(
                Real(rng.next_f32()) + 0.1,
                Real(rng.next_f32()) + 0.2,
                Real(rng.next_f32()) + 0.3,
            )
        )
        var q = Quat.from_axis_angle(axis, Real(rng.next_f32()) * 3 - 1.5)
        var t = Vec3(
            Real(rng.next_f32()) * 2 - 1,
            Real(rng.next_f32()) * 2 - 1,
            Real(rng.next_f32()) * 2 - 1,
        )
        quats.append(q)
        trans.append(SkinVert(t))
        motors.append(Motor3.from_quat_translation(q, t))
        dqs.append(DualQuat.from_quat_translation(q, t))
        mats.append(compose_trs4(t, q, Vec3(1, 1, 1)))

    var p = Vec3(0.7, -0.3, 1.1)

    # --- apply: transform a point through all N ---
    @parameter
    def apply_motor():
        var acc = Vec3(0)
        for i in range(N):
            acc = acc + motors[i].apply_point(p)
        keep(acc[0])

    @parameter
    def apply_dq():
        var acc = Vec3(0)
        for i in range(N):
            acc = acc + dqs[i].transform_point(p)
        keep(acc[0])

    @parameter
    def apply_mat():
        var acc = Vec3(0)
        for i in range(N):
            acc = acc + transform_point4(mats[i], p)
        keep(acc[0])

    @parameter
    def apply_quat():
        var acc = Vec3(0)
        for i in range(N):
            acc = acc + quats[i].rotate(p) + trans[i].v
        keep(acc[0])

    table.add("motor (PGA, 8f)", N, "apply", measure[apply_motor](3, 20), N)
    table.add("dual quat (8f)", N, "apply", measure[apply_dq](3, 20), N)
    table.add("mat4 (16f)", N, "apply", measure[apply_mat](3, 20), N)
    table.add("quat+vec (7f)", N, "apply", measure[apply_quat](3, 20), N)

    # --- compose: chain neighbouring transforms ---
    @parameter
    def compose_motor():
        var acc = Motor3.identity()
        for i in range(N - 1):
            acc = motors[i] * motors[i + 1]
        keep(acc.s)

    @parameter
    def compose_dq():
        var acc = DualQuat.identity()
        for i in range(N - 1):
            acc = dqs[i] * dqs[i + 1]
        keep(acc.real.w)

    @parameter
    def compose_mat():
        var acc = Mat4.identity()
        for i in range(N - 1):
            acc = mats[i] * mats[i + 1]
        keep(acc.m[0])

    table.add("motor (PGA, 8f)", N, "compose", measure[compose_motor](3, 20), N)
    table.add("dual quat (8f)", N, "compose", measure[compose_dq](3, 20), N)
    table.add("mat4 (16f)", N, "compose", measure[compose_mat](3, 20), N)

    # --- skinning: per-vertex 2-bone blend + transform (DLB vs LBS) ---
    var rest = List[SkinVert]()
    var ia = List[Int]()
    var ib = List[Int]()
    var wa = List[Real]()
    var out = List[SkinVert]()
    for i in range(N):
        rest.append(
            SkinVert(Vec3(
                Real(rng.next_f32()) * 2 - 1,
                Real(rng.next_f32()) * 2 - 1,
                Real(rng.next_f32()) * 2 - 1,
            ))
        )
        ia.append(i % len(motors))
        ib.append((i * 7 + 3) % len(motors))
        wa.append(Real(rng.next_f32()))
        out.append(SkinVert(Vec3(0)))

    @parameter
    def skin_m():
        skin_motor(motors, rest, ia, ib, wa, out)
        keep(out.unsafe_ptr())

    @parameter
    def skin_l():
        skin_lbs(mats, rest, ia, ib, wa, out)
        keep(out.unsafe_ptr())

    table.add("motor DLB (8f)", N, "skin", measure[skin_m](3, 20), N)
    table.add("mat4 LBS (16f)", N, "skin", measure[skin_l](3, 20), N)

    table.print_report()
