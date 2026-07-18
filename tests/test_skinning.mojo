"""Motor skinning (E3): DLB must reproduce single bones at weight endpoints,
stay a unit motor, track the screw geodesic for moderate blends, agree with LBS
on rigid cases — and, at the 180° twist where LBS collapses to the bone axis
(the candy-wrapper artifact), keep the vertex at full radius."""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, length, normalize
from geometry.quat import Quat
from geometry.motor import Motor3
from geometry.galie import geodesic3
from geometry.skinning import SkinVert, blend2, skin_motor, skin_lbs


def _near3(mut s: Suite, a: Vec3, b: Vec3, label: String, tol: Float64 = 1e-3):
    s.almost(Float64(a[0]), Float64(b[0]), label + " .x", tol)
    s.almost(Float64(a[1]), Float64(b[1]), label + " .y", tol)
    s.almost(Float64(a[2]), Float64(b[2]), label + " .z", tol)


def main() raises:
    var s = Suite("skinning")

    var qa = Quat.from_axis_angle(Vec3(0, 0, 1), 0.4)
    var qb = Quat.from_axis_angle(normalize(Vec3(1, 1, 0)), -0.3)
    var ma = Motor3.from_quat_translation(qa, Vec3(0.2, 0, 0))
    var mb = Motor3.from_quat_translation(qb, Vec3(0, 0.3, -0.1))
    var p = Vec3(0.5, 1, 0.2)

    # --- weight endpoints reproduce the bones ---
    _near3(s, blend2(ma, mb, 1, 0).apply_point(p), ma.apply_point(p), "w=(1,0)")
    _near3(s, blend2(ma, mb, 0, 1).apply_point(p), mb.apply_point(p), "w=(0,1)")

    # --- blending a bone with itself is that bone ---
    _near3(s, blend2(ma, ma, 0.5, 0.5).apply_point(p), ma.apply_point(p), "m⊕m = m")

    # --- hemisphere correction: −M is the same motion ---
    var neg = Motor3(-mb.s, -mb.b12, -mb.b13, -mb.b23, -mb.b10, -mb.b20, -mb.b30, -mb.pss)
    _near3(
        s, blend2(ma, neg, 0.5, 0.5).apply_point(p),
        blend2(ma, mb, 0.5, 0.5).apply_point(p), "sign-flip invariant",
    )

    # --- result is a unit motor ---
    s.almost(Float64(blend2(ma, mb, 0.5, 0.5).norm_sq()), 1.0, "unit rotor norm")

    # --- DLB tracks the screw geodesic for moderate angles ---
    var dlb = blend2(ma, mb, 0.5, 0.5).apply_point(p)
    var geo = geodesic3(ma, mb, 0.5).apply_point(p)
    s.check(Float64(length(dlb - geo)) < 0.02, "DLB ≈ geodesic midpoint")

    # --- candy-wrapper: 180° twist about x, vertex off-axis at radius 1 ---
    var bone0 = Motor3.identity()
    var bone1 = Motor3.from_quat(Quat.from_axis_angle(Vec3(1, 0, 0), 3.14159265))
    var vert = Vec3(0.5, 1, 0)  # radius 1 from the twist axis

    var bones = [bone0, bone1]
    var mats = [bone0.to_mat4(), bone1.to_mat4()]
    var rest = [SkinVert(vert)]
    var ia = [0]
    var ib = [1]
    var wa = [Real(0.5)]
    var out_m = [SkinVert(Vec3(0))]
    var out_l = [SkinVert(Vec3(0))]
    skin_motor(bones, rest, ia, ib, wa, out_m)
    skin_lbs(mats, rest, ia, ib, wa, out_l)

    var r_motor = sqrt(
        out_m[0].v[1] * out_m[0].v[1] + out_m[0].v[2] * out_m[0].v[2]
    )
    var r_lbs = sqrt(
        out_l[0].v[1] * out_l[0].v[1] + out_l[0].v[2] * out_l[0].v[2]
    )
    s.almost(Float64(r_motor), 1.0, "motor skinning keeps the radius", 1e-2)
    s.check(Float64(r_lbs) < 0.05, "LBS collapses (the artifact, by design)")

    # --- rigid parity: identical bones -> both paths agree ---
    var bones2 = [ma, ma]
    var mats2 = [ma.to_mat4(), ma.to_mat4()]
    skin_motor(bones2, rest, ia, ib, wa, out_m)
    skin_lbs(mats2, rest, ia, ib, wa, out_l)
    _near3(s, out_m[0].v, out_l[0].v, "rigid case: DQS == LBS")

    s.finish()
