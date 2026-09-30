# tier: integration
"""Character IK (ROADMAP 17.3).

  ordinary     two-bone reaches a reachable target exactly, keeps both bone
               lengths, and bends toward the pole; FABRIK converges on a
               5-joint chain with lengths kept.
  seam parity  analytic two-bone vs FABRIK on the same two-segment chain:
               same end effector, same lengths.
  integration  foot planting on a sloped static box found by a world-query
               ray: the ankle target sits the ankle height above the hit
               point and the two-bone leg reaches it; two arms off one
               chest reach two targets (multi-effector FABRIK).
  extreme      unreachable target (chain straight toward it), target on the
               root, pole on the target line, zero-length bone, NaN target
               (input returned unchanged), look-at clamped to its cone,
               ground out of reach (foot left as animated).
"""

from std.math import isfinite, sqrt, sin, cos
from harness.runner import Suite
from geometry.vec import Real, Vec3, dot, length
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from collision.world_query import QueryFilter
from procedural.ik import two_bone, fabrik, fabrik_multi, look_at, foot_plant, chain_lengths


def _al(mut s: Suite, got: Real, want: Real, tol: Real, label: String):
    s.almost(Float64(got), Float64(want), label, Float64(tol))


def main() raises:
    var s = Suite("ik")
    var hip = Vec3(0, 1, 0, 0)
    var knee = Vec3(0, 0.55, 0.05, 0)
    var ankle = Vec3(0, 0.1, 0, 0)
    var l1 = length(knee - hip)
    var l2 = length(ankle - knee)

    # ---- ordinary: two-bone -------------------------------------------------
    var tgt = Vec3(0.2, 0.3, 0.3, 0)
    var r = two_bone(hip, knee, ankle, tgt, Vec3(0, 0.5, 1, 0))
    s.check(r.reached, "two-bone: reachable target reported reached")
    _al(s, length(r.end - tgt), 0, 1e-5, "two-bone: end effector on the target")
    _al(s, length(r.mid - hip), l1, 1e-5, "two-bone: upper length kept")
    _al(s, length(r.end - r.mid), l2, 1e-5, "two-bone: lower length kept")
    var line = _n(tgt - hip)
    var kv = r.mid - hip
    var off = kv - line * dot(kv, line)
    s.check(off[2] > 0, "two-bone: knee bends toward the pole (+z)")

    # ---- ordinary: FABRIK --------------------------------------------------
    var ch = List[Vec3]()
    for i in range(5):
        ch.append(Vec3(0, Real(i) * 0.3, 0, 0))
    var lens0 = chain_lengths(ch)
    var ft = Vec3(0.5, 0.6, 0.3, 0)
    var its = fabrik(ch, ft, 64, 1e-4)
    s.check(its > 0 and its < 64, "FABRIK converges on a 5-joint chain")
    _al(s, length(ch[4] - ft), 0, 1e-4, "FABRIK: end effector on the target")
    var lens_ok = True
    var lens1 = chain_lengths(ch)
    for i in range(4):
        if abs(lens1[i] - lens0[i]) > 1e-4:
            lens_ok = False
    s.check(lens_ok and ch[0] == Vec3(0, 0, 0, 0), "FABRIK: lengths kept, root fixed")

    # ---- seam parity: analytic vs FABRIK on the same leg ------------------
    var leg = List[Vec3]()
    leg.append(hip)
    leg.append(knee)
    leg.append(ankle)
    _ = fabrik(leg, tgt, 200, 1e-6)
    _al(s, length(leg[2] - r.end), 0, 1e-4, "analytic == FABRIK: same end effector")
    _al(s, length(leg[1] - leg[0]), l1, 1e-4, "FABRIK leg keeps the upper length too")

    # ---- integration: foot planting on a slope via a world query ----------
    var sc = ContactScene6[QuatBody6]()
    var tilt = Real(0.2)  # ~11.5 degrees about z
    var slope = QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 5, 0.5, 5))
    slope.q = Quat(0, 0, sin(tilt / 2), cos(tilt / 2))
    _ = sc.add(slope^, Vec3(5, 0.5, 5, 0), True)
    var foot_x = Real(0.4)
    var hit = sc.ray_cast(Vec3(foot_x, 3, 0, 0), Vec3(0, -1, 0, 0), 10, QueryFilter.all())
    s.check(hit.hit, "world query finds the ground under the foot")
    var anim_ankle = Vec3(foot_x, 0.1, 0, 0)
    var fp = foot_plant(anim_ankle, 0.08, hit.point[1], hit.normal, 0.5, 0.5)
    s.check(fp.planted, "foot plant: ground within reach")
    _al(s, fp.ankle[1] - hit.point[1], 0.08, 1e-5, "foot plant: ankle sits its height above the hit point")
    _al(s, fp.foot_angle, tilt, 1e-3, "foot plant: foot tilted by the slope angle")
    var hip2 = Vec3(foot_x, 1, 0, 0)
    var leg2 = two_bone(hip2, Vec3(foot_x, 0.55, 0.05, 0), anim_ankle, fp.ankle, Vec3(foot_x, 0.5, 1, 0))
    _al(s, length(leg2.end - fp.ankle), 0, 1e-5, "leg IK reaches the planted ankle")

    var chest = Vec3(0, 1.4, 0, 0)
    var pelvis = Vec3(0, 1.0, 0, 0)
    var arms = List[List[Vec3]]()
    for side in range(2):
        var sgn = Real(1) if side == 0 else Real(-1)
        var a = List[Vec3]()
        a.append(chest)
        a.append(chest + Vec3(0.2 * sgn, 0, 0, 0))
        a.append(chest + Vec3(0.5 * sgn, 0, 0, 0))
        a.append(chest + Vec3(0.8 * sgn, 0, 0, 0))
        arms.append(a^)
    var targets = List[Vec3]()
    targets.append(Vec3(0.6, 1.2, 0.4, 0))
    targets.append(Vec3(-0.5, 1.6, 0.3, 0))
    var worst = fabrik_multi(chest, pelvis, 0.4, arms, targets, 64)
    s.check(worst < 1e-3, "multi-effector FABRIK: both hands reach")
    _al(s, length(chest - pelvis), 0.4, 1e-5, "multi-effector: chest stays on its sphere around the pelvis")

    # ---- extremes --------------------------------------------------------------
    var far = Vec3(0, 5, 3, 0)
    var ru = two_bone(hip, knee, ankle, far, Vec3(0, 0, 1, 0))
    s.check(not ru.reached, "unreachable: reported")
    var straight = _n(far - hip)
    _al(s, length(ru.end - (hip + straight * (l1 + l2))), 0, 1e-4, "unreachable: chain laid straight toward it")
    var ron = two_bone(hip, knee, ankle, hip, Vec3(0, 0, 1, 0))
    s.check(_fin(ron.mid) and _fin(ron.end), "target on the root: finite")
    var rpl = two_bone(hip, knee, ankle, tgt, tgt)
    s.check(_fin(rpl.mid) and length(rpl.end - tgt) < 1e-4, "pole on the target line: falls back to the current knee side")
    var rz = two_bone(hip, hip, ankle, tgt, Vec3(0, 0, 1, 0))
    s.check(rz.mid == hip and rz.end == ankle and not rz.reached, "zero-length bone: input returned")
    var nanv = Real(0) / Real(0)
    var rn = two_bone(hip, knee, ankle, Vec3(nanv, 0, 0, 0), Vec3(0, 0, 1, 0))
    s.check(rn.mid == knee and rn.end == ankle, "NaN target (two-bone): input returned")
    var chn = ch.copy()
    _ = fabrik(chn, Vec3(nanv, 0, 0, 0))
    s.check(chn[4] == ch[4], "NaN target (FABRIK): chain untouched")
    var la = look_at(Vec3(0, 0, 1, 0), Vec3(1, 0, 0, 0), 0.5)
    _al(s, la[1], 0.5, 1e-6, "look-at clamped to its cone")
    var lb = look_at(Vec3(0, 0, 1, 0), Vec3(0, 0, -1, 0), 4)
    _al(s, lb[1], 3.14159265, 1e-4, "look-at straight behind: a half turn about a perpendicular")
    var fno = foot_plant(anim_ankle, 0.08, -3, Vec3(0, 1, 0, 0), 0.5, 0.5)
    s.check(not fno.planted and fno.ankle == anim_ankle, "ground out of reach: animated foot kept")

    s.finish()


def _n(v: Vec3) -> Vec3:
    return v * (1 / sqrt(dot(v, v)))


def _fin(v: Vec3) -> Bool:
    return isfinite(v[0]) and isfinite(v[1]) and isfinite(v[2])
