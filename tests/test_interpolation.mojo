# tier: unit  (override: exercises gameplay.interpolation alone; geometry.quat supplies its value type)
"""ROADMAP 17.7: the pose-interpolator seam (LerpNlerp / DqNlerp /
MotorGeodesic) and PoseHistory.

Parity: every variant returns the endpoints at t = 0 and 1 and agrees on pure
translations. Where they differ: a screw motion (a quarter turn about a
vertical axis through x = 1) -- the motor geodesic keeps the body origin on
the unit circle around the axis, lerp+nlerp cuts the chord.
Extreme: alpha outside [0, 1] clamps (or extrapolates when asked), antipodal
quaternions (same rotation) blend without a flip or NaN, a new slot starts
with prev == curr, a teleport makes prev == curr for one capture."""

from harness.runner import Suite
from std.math import sqrt
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from gameplay.interpolation import (
    PoseQT, PoseHistory, PoseInterpolator, LerpNlerp, DqNlerp, MotorGeodesic,
)

comptime PROBES = 3


def _probe(k: Int) -> Vec3:
    if k == 0:
        return Vec3(1, 0, 0, 0)
    if k == 1:
        return Vec3(0, 2, 0, 0)
    return Vec3(0.3, -0.4, 0.5, 0)


def _same_action(a: PoseQT, b: PoseQT, tol: Real) -> Bool:
    for k in range(PROBES):
        if length(a.apply(_probe(k)) - b.apply(_probe(k))) > tol:
            return False
    return True


def _check_variant[I: PoseInterpolator](mut s: Suite, name: String):
    var a = PoseQT(Vec3(1, 2, 3, 0), Quat.from_axis_angle(Vec3(0, 1, 0, 0), 0.3))
    var b = PoseQT(Vec3(-2, 0.5, 4, 0), Quat.from_axis_angle(Vec3(1, 1, 0, 0), 1.1))
    s.check(_same_action(I.blend(a, b, 0), a, 1e-5), name + ": t = 0 gives the start pose")
    s.check(_same_action(I.blend(a, b, 1), b, 1e-5), name + ": t = 1 gives the end pose")
    var ta = PoseQT(Vec3(0, 0, 0, 0), Quat.identity())
    var tb = PoseQT(Vec3(4, -2, 6, 0), Quat.identity())
    var mid = I.blend(ta, tb, 0.25)
    s.check(length(mid.p - Vec3(1, -0.5, 1.5, 0)) < 1e-5, name + ": pure translation is linear")
    var anti = I.blend(a, PoseQT(a.p, Quat(-a.q.x, -a.q.y, -a.q.z, -a.q.w)), 0.5)
    s.check(_same_action(anti, a, 1e-4), name + ": antipodal quaternions blend to the same rotation")


def main() raises:
    var s = Suite("interpolation")
    _check_variant[LerpNlerp](s, "LerpNlerp")
    _check_variant[DqNlerp](s, "DqNlerp")
    _check_variant[MotorGeodesic](s, "MotorGeodesic")

    # screw: quarter turn about the vertical axis through (1, 0, 0)
    var q90 = Quat.from_axis_angle(Vec3(0, 1, 0, 0), 1.5707963)
    var a = PoseQT(Vec3(0, 0, 0, 0), Quat.identity())
    var b = PoseQT(Vec3(1, 0, 0, 0) - q90.rotate(Vec3(1, 0, 0, 0)), q90)
    var axis = Vec3(1, 0, 0, 0)
    var worst_geo = Real(0)
    var worst_lerp = Real(0)
    var worst_dq = Real(0)
    for k in range(1, 10):
        var t = Real(k) / 10
        worst_geo = max(worst_geo, abs(length(MotorGeodesic.blend(a, b, t).p - axis) - 1))
        worst_lerp = max(worst_lerp, abs(length(LerpNlerp.blend(a, b, t).p - axis) - 1))
        worst_dq = max(worst_dq, abs(length(DqNlerp.blend(a, b, t).p - axis) - 1))
    print("  screw: off-circle error  geodesic", worst_geo, " dq-nlerp", worst_dq, " lerp+nlerp", worst_lerp)
    s.check(worst_geo < 1e-4, "motor geodesic stays on the screw's circle")
    s.check(worst_lerp > 0.2, "lerp+nlerp cuts the chord (off the circle by > 0.2)")
    s.check(worst_dq < worst_lerp, "dual-quaternion nlerp is closer to the screw than lerp+nlerp")

    # history
    var h = PoseHistory()
    var p0 = List[PoseQT]()
    p0.append(PoseQT(Vec3(0, 10, 0, 0), Quat.identity()))
    h.capture(p0)
    s.check(length(h.prev[0].p - h.curr[0].p) == 0, "a new slot starts with prev == curr")
    var p1 = List[PoseQT]()
    p1.append(PoseQT(Vec3(0, 9, 0, 0), Quat.identity()))
    h.capture(p1)
    var mid = h.sample[LerpNlerp](0, 0.5)
    s.check(abs(mid.p[1] - 9.5) < 1e-6, "sample at alpha 0.5 is halfway between ticks")
    s.check(h.sample[LerpNlerp](0, 1.7).p[1] == 9, "alpha > 1 clamps to the current tick")
    s.check(abs(h.sample[LerpNlerp](0, 2.0, True).p[1] - 8) < 1e-5, "extrapolate runs past the current tick")
    s.check(h.sample[LerpNlerp](0, -3).p[1] == 10, "alpha < 0 clamps to the previous tick")
    h.mark_teleport(0)
    var p2 = List[PoseQT]()
    p2.append(PoseQT(Vec3(50, 9, 0, 0), Quat.identity()))
    h.capture(p2)
    s.check(h.prev[0].p[0] == 50 and h.curr[0].p[0] == 50, "a teleport leaves no in-between pose")
    s.finish()
