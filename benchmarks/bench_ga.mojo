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
from geometry.cga import (
    invert_point, dilate_point, invert_point_with, dilate_point_with,
    dilator, dilator_reverse, sphere_dual,
    Circle3, point_circle_dist, point_circle_dist_cga,
    rotor, translator, apply_versor,
)
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

    # ------------------------------------------------- conformal versors
    # What the CONFORMAL algebra adds over the rigid (PGA) one: uniform scale
    # as a versor, and spherical inversion — which has no 4x4-matrix row here
    # because it cannot have one. Inversion is conformal but not affine, so it
    # is not a linear map on homogeneous coordinates at all; the only
    # comparison available is the hand-written closed form.
    var cf = BenchTable("Conformal versors: CGA inversion / dilation vs closed form")

    var pts = List[SkinVert]()
    for _ in range(N):
        pts.append(
            SkinVert(Vec3(
                Real(rng.next_f32()) * 6 - 3,
                Real(rng.next_f32()) * 6 - 3,
                Real(rng.next_f32()) * 6 - 3,
            ))
        )
    var ic = Vec3(0.3, -0.2, 0.1)
    comptime IR: Real = 2.0
    comptime SCALE: Real = 1.7

    # versors are fixed for a given sphere/scale: build once, like real code
    var inv_versor = sphere_dual(ic, IR)
    var dil_d = dilator(SCALE)
    var dil_dr = dilator_reverse(SCALE)

    @parameter
    def inv_cga():
        var acc = Real(0)
        for i in range(N):
            acc += invert_point_with(inv_versor, pts[i].v)[0]
        keep(acc)

    @parameter
    def inv_analytic():
        var acc = Real(0)
        for i in range(N):
            var d = pts[i].v - ic
            var d2 = d[0] * d[0] + d[1] * d[1] + d[2] * d[2]
            if d2 > 1e-9:
                acc += (ic + d * (IR * IR / d2))[0]
        keep(acc)

    @parameter
    def dil_cga():
        var acc = Real(0)
        for i in range(N):
            acc += dilate_point_with(dil_d, dil_dr, pts[i].v)[0]
        keep(acc)

    @parameter
    def dil_scalar():
        var acc = Real(0)
        for i in range(N):
            acc += (pts[i].v * SCALE)[0]
        keep(acc)

    # point-to-circle (point-to-arc): a circle is a first-class CGA round, so
    # both scalars the distance needs come back as inner products — but the
    # split-and-recombine algorithm is the same either way.
    var circ = Circle3.make(Vec3(0.5, -0.25, 1.0), normalize(Vec3(0.3, 1.0, -0.2)), 2.0)

    @parameter
    def arc_cga():
        var acc = Real(0)
        for i in range(N):
            acc += point_circle_dist_cga(circ, pts[i].v)
        keep(acc)

    @parameter
    def arc_closed():
        var acc = Real(0)
        for i in range(N):
            acc += point_circle_dist(circ, pts[i].v)
        keep(acc)

    cf.add("point-arc cga carriers", N, "point", measure[arc_cga](3, 20), N)
    cf.add("point-arc closed form", N, "point", measure[arc_closed](3, 20), N)
    cf.add("inversion cga versor", N, "point", measure[inv_cga](3, 20), N)
    cf.add("inversion closed form", N, "point", measure[inv_analytic](3, 20), N)
    cf.add("dilation cga versor", N, "point", measure[dil_cga](3, 20), N)
    cf.add("dilation scalar multiply", N, "point", measure[dil_scalar](3, 20), N)
    cf.print_report()

    # ------------------------------------------------- transform CHAIN regime
    # Where a compact rigid representation is supposed to pay: composing long
    # chains, as a deep transform hierarchy does. A motor is 8 floats against a
    # matrix's 16, so the chain streams half the memory and composes with fewer
    # flops; the per-point APPLY rows above are the opposite regime, where the
    # matrix's single dot-product-per-row wins outright. Sweeping chain length
    # separates the two instead of letting one stand for both.
    var ch = BenchTable("Transform CHAIN: composing K transforms (compact rep's regime)")

    comptime for ki in range(4):
        comptime K = 4 if ki == 0 else (16 if ki == 1 else (64 if ki == 2 else 256))

        @parameter
        def chain_motor():
            var acc = Real(0)
            for base in range(0, N - K, K):
                var m = motors[base]
                for j in range(1, K):
                    m = m * motors[base + j]
                acc += m.s
            keep(acc)

        @parameter
        def chain_dq():
            var acc = Real(0)
            for base in range(0, N - K, K):
                var d = dqs[base]
                for j in range(1, K):
                    d = d * dqs[base + j]
                acc += d.real.w
            keep(acc)

        @parameter
        def chain_mat():
            var acc = Real(0)
            for base in range(0, N - K, K):
                var m = mats[base]
                for j in range(1, K):
                    m = m * mats[base + j]
                acc += m.m[0]
            keep(acc)

        ch.add("motor (8f)  K=" + String(K), N, "compose", measure[chain_motor](3, 20), N)
        ch.add("dualquat(8f) K=" + String(K), N, "compose", measure[chain_dq](3, 20), N)
        ch.add("mat4 (16f)  K=" + String(K), N, "compose", measure[chain_mat](3, 20), N)
    ch.print_report()

    # --------------------------------------- CAPABILITY regime: mixed chains
    # The conformal versor's argument is not speed, it is that ONE operator can
    # hold rotation, translation, scale AND spherical inversion. A 4x4 matrix
    # cannot absorb an inversion at all, so a matrix pipeline has to BREAK the
    # chain at every inversion: fold the affine run into a matrix, transform,
    # apply a closed-form inversion, start a new matrix.
    #
    # That makes inversion count the scaling axis. The versor path folds the
    # whole chain once and touches each point once no matter how many
    # inversions there are; the matrix path pays an extra transform plus an
    # inversion per point per break. `test_cga_inversion` gates that the fold
    # reproduces the sequential result, so both paths compute the same thing.
    var cap = BenchTable(
        "Mixed transform chains with INVERSIONS (the versor's capability regime)"
    )
    comptime CN = 1024
    var cpts = List[SkinVert]()
    for _ in range(CN):
        cpts.append(
            SkinVert(Vec3(
                Real(rng.next_f32()) * 4 - 2,
                Real(rng.next_f32()) * 4 - 2,
                Real(rng.next_f32()) * 4 - 2,
            ))
        )
    var ax = normalize(Vec3(0.2, 1.0, -0.4))
    var inv_c = Vec3(0.1, 0.2, -0.1)
    comptime INV_R: Real = 1.3

    comptime for ii in range(5):
        comptime NINV = 0 if ii == 0 else (1 if ii == 1 else (2 if ii == 2 else (4 if ii == 3 else 8)))

        # fold the whole chain into one versor (done once, outside the point loop)
        var V = rotor(ax, 0.7) * translator(Vec3(0.5, -0.8, 0.3))
        comptime for k in range(NINV):
            V = sphere_dual(inv_c, INV_R) * rotor(ax, 0.3) * V

        @parameter
        def chain_versor():
            var acc = Real(0)
            for i in range(CN):
                acc += apply_versor(V, cpts[i].v)[0]
            keep(acc)

        # matrix path: one Mat4 per affine run, closed-form inversion between
        var m0 = compose_trs4(Vec3(0.5, -0.8, 0.3), Quat.from_axis_angle(ax, 0.7), Vec3(1, 1, 1))
        var mk = compose_trs4(Vec3(0, 0, 0), Quat.from_axis_angle(ax, 0.3), Vec3(1, 1, 1))

        @parameter
        def chain_matrix():
            var acc = Real(0)
            for i in range(CN):
                var q = transform_point4(m0, cpts[i].v)
                comptime for k in range(NINV):
                    q = transform_point4(mk, q)
                    var d = q - inv_c
                    var d2 = d[0] * d[0] + d[1] * d[1] + d[2] * d[2]
                    if d2 > 1e-9:
                        q = inv_c + d * (INV_R * INV_R / d2)
                acc += q[0]
            keep(acc)

        cap.add(
            "versor (folded) inversions=" + String(NINV),
            CN, "point", measure[chain_versor](3, 20), CN,
        )
        cap.add(
            "mat4 + closed-form inversions=" + String(NINV),
            CN, "point", measure[chain_matrix](3, 20), CN,
        )
    cap.print_report()
