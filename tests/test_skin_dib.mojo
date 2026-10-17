# tier: integration
"""Iterative blending, joint-angle coordinates, soft-body pins (ROADMAP
17.65).

  1. DIB parity: every bone the same motion -> DIB = DLB (1e-6); K = 1 ->
     the bone; two bones at 0.5 / 0.5 -> the geodesic midpoint
     (`geodesic3(a, b, 0.5)`, 1e-5), which DLB only approximates (its
     distance printed).
  2. Twist (4 bones, 0 .. 170 deg about the arm axis, weights spread
     along it): DIB keeps the 0.2 radius like DLB; LBS collapses (printed).
  3. Angles: `rotation_angle` of a 70 deg motor is 70 deg; `joint_angle`
     of child (100 deg) under parent (30 deg) about the same axis is 70 deg;
     `twist_angle` of swing(30 deg about x) x twist(50 deg about y) about y
     is 50 deg; a pure translation has angle 0.
  4. Soft-body pins: a 3^3 lattice whose top layer is re-pinned to
     skinned vertices after each of its steps sits on them exactly and
     hangs from them for 1 s.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from geometry.motor import Motor3
from geometry.mat import Mat4
from geometry.galie import geodesic3
from geometry.skinning import blend_k, blend_k_iter, skin_dib_k, skin_motor_k, skin_lbs_k
from geometry.pose_space import rotation_angle, joint_angle, twist_angle
from physics.softbody import SoftBody
from gameplay.skin_link import pin_softbody_to_skin

comptime DEG: Real = 3.14159265358979 / 180


def mdist(a: Motor3, b: Motor3) -> Real:
    var d = abs(a.s - b.s) + abs(a.b12 - b.b12) + abs(a.b13 - b.b13) + abs(a.b23 - b.b23) + abs(a.b10 - b.b10) + abs(a.b20 - b.b20) + abs(a.b30 - b.b30) + abs(a.pss - b.pss)
    var e = abs(a.s + b.s) + abs(a.b12 + b.b12) + abs(a.b13 + b.b13) + abs(a.b23 + b.b23) + abs(a.b10 + b.b10) + abs(a.b20 + b.b20) + abs(a.b30 + b.b30) + abs(a.pss + b.pss)
    return min(d, e)


def main() raises:
    var s = Suite("skin_dib")
    # 1. parity
    var m = Motor3.from_quat_translation(Quat.from_axis_angle(Vec3(0.3, 1, 0.2, 0) * (1 / sqrt(Real(1.13))), 1.1), Vec3(0.4, -0.2, 0.1, 0))
    var same: List[Motor3] = [m, m, m, m]
    var idx: List[Int] = [0, 1, 2, 3]
    var w: List[Real] = [0.1, 0.2, 0.3, 0.4]
    s.check(mdist(blend_k_iter(same, idx, w, 0, 4, 10), blend_k(same, idx, w, 0, 4)) < 1e-6, "same motion on all bones: DIB = DLB")
    s.check(mdist(blend_k_iter(same, [2], [1.0], 0, 1, 10), m) < 1e-6, "K = 1: the bone")
    var a = Motor3.from_quat_translation(Quat.from_axis_angle(Vec3(0, 0, 1, 0), 0.2), Vec3(0, 0, 0, 0))
    var b = Motor3.from_quat_translation(Quat.from_axis_angle(Vec3(1, 0, 0, 0), 2.4), Vec3(1.0, 0.5, 0, 0))
    var two: List[Motor3] = [a, b]
    var mid = geodesic3(a, b, 0.5)
    var dib = blend_k_iter(two, [0, 1], [0.5, 0.5], 0, 2, 20)
    var dlb = blend_k(two, [0, 1], [0.5, 0.5], 0, 2)
    var pe_dib = Real(0)
    var pe_dlb = Real(0)
    for p in [Vec3(0.5, 0.3, 0.2, 0), Vec3(2, -1, 1, 0), Vec3(-1, 0.5, 3, 0)]:
        pe_dib = max(pe_dib, length(dib.apply_point(p) - mid.apply_point(p)))
        pe_dlb = max(pe_dlb, length(dlb.apply_point(p) - mid.apply_point(p)))
    print("two bones 0.5 / 0.5: |DIB - geodesic mid| coefficients", mdist(dib, mid), " points", pe_dib, "   DLB points", pe_dlb)
    s.check(mdist(dib, mid) < 1e-5 and pe_dib < 1e-5, "two bones at 0.5: DIB is the geodesic midpoint (coefficients and points)")

    # 2. twist: arm along x, 4 bones twisted 0, 57, 113, 170 deg about x
    var bones = List[Motor3]()
    var mats = List[Mat4]()
    for j in range(4):
        var q = Quat.from_axis_angle(Vec3(1, 0, 0, 0), Real(j) * 170.0 / 3.0 * DEG)
        bones.append(Motor3.from_quat(q))
        mats.append(bones[j].to_mat4())
    var rest = List[Vec3]()
    var vi = List[Int]()
    var vw = List[Real]()
    for k in range(32):
        var x = Real(k) / 31
        rest.append(Vec3(x, 0.2, 0, 0))
        for j in range(4):
            vi.append(j)
            var c = Real(j) / 3
            vw.append(max(Real(0), 1 - abs(x - c) * 3))
    var o_dib = List[Vec3](length=32, fill=Vec3(0, 0, 0, 0))
    var o_dlb = List[Vec3](length=32, fill=Vec3(0, 0, 0, 0))
    var o_lbs = List[Vec3](length=32, fill=Vec3(0, 0, 0, 0))
    skin_dib_k(bones, rest, vi, vw, 4, 10, o_dib)
    skin_motor_k(bones, rest, vi, vw, 4, o_dlb)
    skin_lbs_k(mats, rest, vi, vw, 4, o_lbs)
    var r_dib = Real(1)
    var r_dlb = Real(1)
    var r_lbs = Real(1)
    for k in range(32):
        r_dib = min(r_dib, sqrt(o_dib[k][1] * o_dib[k][1] + o_dib[k][2] * o_dib[k][2]))
        r_dlb = min(r_dlb, sqrt(o_dlb[k][1] * o_dlb[k][1] + o_dlb[k][2] * o_dlb[k][2]))
        r_lbs = min(r_lbs, sqrt(o_lbs[k][1] * o_lbs[k][1] + o_lbs[k][2] * o_lbs[k][2]))
    print("twist 0..170 deg, smallest radius (rest 0.2): DIB", r_dib, " DLB", r_dlb, " LBS", r_lbs)
    s.check(abs(r_dib - 0.2) < 1e-5 and abs(r_dlb - 0.2) < 1e-5 and r_lbs < 0.19, "DIB and DLB keep the radius, LBS collapses (> 5 %)")

    # 3. angles
    var m70 = Motor3.from_quat_translation(Quat.from_axis_angle(Vec3(0, 0, 1, 0), 70 * DEG), Vec3(1, 2, 3, 0))
    var p30 = Motor3.from_quat(Quat.from_axis_angle(Vec3(0, 0, 1, 0), 30 * DEG))
    var c100 = Motor3.from_quat(Quat.from_axis_angle(Vec3(0, 0, 1, 0), 100 * DEG))
    var sw = Motor3.from_quat(Quat.from_axis_angle(Vec3(1, 0, 0, 0), 30 * DEG))
    var tw = Motor3.from_quat(Quat.from_axis_angle(Vec3(0, 1, 0, 0), 50 * DEG))
    var ra = rotation_angle(m70) / DEG
    var ja = joint_angle(p30, c100) / DEG
    var ta = twist_angle(sw * tw, Vec3(0, 1, 0, 0)) / DEG
    var t0 = rotation_angle(Motor3.from_translation(Vec3(3, 0, 0, 0)))
    print("angles: rotation", ra, " joint", ja, " twist", ta, " translation", t0)
    s.check(abs(ra - 70) < 1e-3 and abs(ja - 70) < 1e-3, "rotation / joint angle 70 deg")
    s.check(abs(ta - 50) < 1e-3 and t0 == 0, "twist about y of swing x twist = 50 deg; translation 0")

    # 4. soft body pinned to skinned vertices
    var sb = SoftBody.box_lattice(Vec3(0, 1, 0, 0), Vec3(0.1, 0.1, 0.1, 0), 3, 1.0, 0.0)
    var top = List[Int]()
    var skinned = List[Vec3]()
    var sv = List[Int]()
    for i in range(len(sb.pts)):
        if sb.pts[i].x[1] > 1.05:
            top.append(i)
            sv.append(len(skinned))
            skinned.append(sb.pts[i].x + Vec3(0.05, 0.02, 0, 0))
    var bottom = 0
    for i in range(len(sb.pts)):
        if sb.pts[i].x[1] < sb.pts[bottom].x[1]:
            bottom = i
    pin_softbody_to_skin(sb, top, sv, skinned, 1.0 / 60.0)
    for _ in range(60):
        sb.advance(1.0 / 60.0, Vec3(0, -9.8, 0, 0))
        pin_softbody_to_skin(sb, top, sv, skinned, 1.0 / 60.0)
    var ok = len(top) == 9
    for k in range(len(top)):
        ok = ok and length(sb.pts[top[k]].x - skinned[k]) == 0 and sb.pts[top[k]].w == 0
    var drop = skinned[0][1] - sb.pts[bottom].x[1]
    print("soft body, 1 s on 9 skinned pins: bottom particle", drop, "m below the pinned layer (rest 0.2)")
    s.check(ok, "9 top particles sit on their skinned vertices after each step")
    s.check(drop > 0.15 and drop < 0.4, "the lattice hangs from its pins instead of falling away")
    s.finish()
