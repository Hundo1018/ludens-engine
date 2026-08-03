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
from geometry.quat import Quat, compose_trs4, slerp, quat_from_mat3
from geometry.mat import Mat4, Mat3, transform_point4
from geometry.motor import Motor3
from geometry.dualquat import DualQuat
from geometry.galie import Screw3, exp_screw3, log_motor3, geodesic3
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

    # ---------------------------------------------------------------- SE(3)
    # The Lie layer priced against the classical routes. `geodesic3` is
    # a·exp(t·log(~a·b)) — ONE screw motion (rotation and translation share an
    # axis and interpolate together); `slerp + lerp` is the decoupled classical
    # route (rotation slerped, translation lerped independently), which is
    # cheaper but traces a different path. Parity/round-trip: test_motor_parity.
    var lie = BenchTable("SE(3) interpolation & Lie ops: PGA screw vs quat slerp+lerp vs mat4")

    var screws = List[Screw3]()
    for i in range(N):
        screws.append(log_motor3(motors[i]))

    comptime T: Real = 0.375

    @parameter
    def lie_exp():
        var acc = Real(0)
        for i in range(N):
            acc += exp_screw3(screws[i]).s
        keep(acc)

    @parameter
    def lie_log():
        var acc = Real(0)
        for i in range(N):
            acc += log_motor3(motors[i]).b12
        keep(acc)

    @parameter
    def interp_motor():
        var acc = Real(0)
        for i in range(N - 1):
            acc += geodesic3(motors[i], motors[i + 1], T).s
        keep(acc)

    @parameter
    def interp_quat():
        # classical decoupled: slerp the rotation, lerp the translation
        var acc = Real(0)
        for i in range(N - 1):
            var q = slerp(quats[i], quats[i + 1], T)
            var t = trans[i].v * (1 - T) + trans[i + 1].v * T
            acc += q.w + t[0]
        keep(acc)

    @parameter
    def interp_dq():
        # via the motor bridge (DualQuat has no native ScLERP): prices what the
        # engine's API actually makes you pay to screw-interpolate a dual quat.
        var acc = Real(0)
        for i in range(N - 1):
            var g = geodesic3(dqs[i].to_motor(), dqs[i + 1].to_motor(), T)
            acc += DualQuat.from_motor(g).real.w
        keep(acc)

    @parameter
    def interp_mat():
        # matrices cannot be interpolated directly (the blend leaves SE(3)):
        # decompose -> slerp/lerp -> recompose is the honest matrix route.
        var acc = Real(0)
        for i in range(N - 1):
            var ra = Mat3()
            var rb = Mat3()
            comptime for r in range(3):
                comptime for c in range(3):
                    ra.set(r, c, mats[i].get(r, c))
                    rb.set(r, c, mats[i + 1].get(r, c))
            var qa = quat_from_mat3(ra)
            var qb = quat_from_mat3(rb)
            var ta = Vec3(mats[i].get(0, 3), mats[i].get(1, 3), mats[i].get(2, 3))
            var tb = Vec3(
                mats[i + 1].get(0, 3), mats[i + 1].get(1, 3), mats[i + 1].get(2, 3)
            )
            var m = compose_trs4(
                ta * (1 - T) + tb * T, slerp(qa, qb, T), Vec3(1, 1, 1)
            )
            acc += m.m[0]
        keep(acc)

    lie.add("motor exp (screw->motor)", N, "exp", measure[lie_exp](3, 20), N)
    lie.add("motor log (motor->screw)", N, "log", measure[lie_log](3, 20), N)
    lie.add("motor geodesic (PGA screw)", N, "interp", measure[interp_motor](3, 20), N)
    lie.add("quat slerp + lerp (decoupled)", N, "interp", measure[interp_quat](3, 20), N)
    lie.add("dual quat (via motor bridge)", N, "interp", measure[interp_dq](3, 20), N)
    lie.add("mat4 decompose+slerp+recompose", N, "interp", measure[interp_mat](3, 20), N)

    lie.print_report()
