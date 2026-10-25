# tier: component
"""Inertialization in motor space (ROADMAP 17.64, `INERT_MOTOR`).

  1. Ordinary: a bone at radius 1 from a pivot, the shown pose rotated 90
     degrees about the pivot from the target: halfway through the decay
     (k = 0.5) the motor offset keeps the bone 1 from the pivot (on the
     arc); the split offset cuts the chord (0.707).
  2. Integration: for a pure translation offset and for a rotation about
     the bone's own origin the two spaces agree (1e-5); at the start both
     show the old pose, after the duration both are the target exactly.
  3. Extreme: a zero offset leaves the target untouched in motor space.
"""

from std.math import sqrt, pi
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from procedural.inertialize import Inertializer, INERT_SPLIT, INERT_MOTOR


def _pose(p: Vec3, q: Quat) -> Tuple[List[Real], List[Real]]:
    var a: List[Real] = [p[0], p[1], p[2]]
    var b: List[Real] = [q.x, q.y, q.z, q.w]
    return (a^, b^)


def _at(space: Int, src_p: Vec3, src_q: Quat, dst_p: Vec3, dst_q: Quat, elapsed: Real) -> List[Real]:
    var src = _pose(src_p, src_q)
    var dst = _pose(dst_p, dst_q)
    var inz = Inertializer(1, space)
    inz.start(src[0], src[1], dst[0], dst[1], 1.0)
    inz.advance(elapsed)
    var op: List[Real] = [dst_p[0], dst_p[1], dst_p[2]]
    var oq: List[Real] = [dst_q.x, dst_q.y, dst_q.z, dst_q.w]
    inz.apply(op, oq)
    for v in oq:
        op.append(v)
    return op^  # x y z | qx qy qz qw


def _dist(a: List[Real], b: List[Real], lo: Int, hi: Int) -> Real:
    var s = Real(0)
    for k in range(lo, hi):
        s += (a[k] - b[k]) * (a[k] - b[k])
    return sqrt(s)


def _flat(p: Vec3, q: Quat) -> List[Real]:
    return [p[0], p[1], p[2], q.x, q.y, q.z, q.w]


def main() raises:
    var s = Suite("inertialize_motor")
    var up = Vec3(0, 1, 0, 0)
    # target: bone at (1, 0, 0), identity; shown: rotated 90 deg about the
    # origin (pivot) -> at (0, 0, -1) facing rotated
    var qr = Quat.from_axis_angle(up, Real(pi) / 2)
    var dst_p = Vec3(1, 0, 0, 0)
    var src_p = qr.rotate(dst_p)
    var one = Quat(0, 0, 0, 1)
    var m = _at(INERT_MOTOR, src_p, qr, dst_p, one, 0.5)
    var sp = _at(INERT_SPLIT, src_p, qr, dst_p, one, 0.5)
    var rm = sqrt(m[0] * m[0] + m[2] * m[2])
    var rs = sqrt(sp[0] * sp[0] + sp[2] * sp[2])
    print("  rotated 90 deg about a pivot, halfway: distance to pivot  motor", rm, " split", rs)
    s.check(abs(rm - 1) < 1e-4 and abs(rs - 0.70710678) < 1e-4, "motor offset swings on the arc; split cuts the chord")

    var t1 = _at(INERT_MOTOR, Vec3(0.3, 0.2, -0.1, 0), one, Vec3(0, 0, 0, 0), one, 0.37)
    var t2 = _at(INERT_SPLIT, Vec3(0.3, 0.2, -0.1, 0), one, Vec3(0, 0, 0, 0), one, 0.37)
    var q1 = Quat.from_axis_angle(Vec3(1, 0, 0, 0), 0.8)
    var r1 = _at(INERT_MOTOR, Vec3(0, 0, 0, 0), q1, Vec3(0, 0, 0, 0), one, 0.37)
    var r2 = _at(INERT_SPLIT, Vec3(0, 0, 0, 0), q1, Vec3(0, 0, 0, 0), one, 0.37)
    print("  pure translation: motor vs split", _dist(t1, t2, 0, 3), ";  rotation about the origin:", _dist(r1, r2, 3, 7))
    s.check(_dist(t1, t2, 0, 7) < 1e-5 and _dist(r1, r2, 0, 7) < 1e-5, "translation-only and rotation-about-origin offsets: both spaces agree")

    var s0 = _at(INERT_MOTOR, src_p, qr, dst_p, one, 0)
    var src = _flat(src_p, qr)
    var end = _at(INERT_MOTOR, src_p, qr, dst_p, one, 1.0)
    var dst = _flat(dst_p, one)
    s.check(_dist(s0, src, 0, 3) < 1e-5 and end == dst, "starts on the shown pose, ends exactly on the target")
    var z = _at(INERT_MOTOR, dst_p, one, dst_p, one, 0.3)
    s.check(_dist(z, dst, 0, 7) < 1e-6, "zero offset leaves the target")
    s.finish()
