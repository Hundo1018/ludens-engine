from harness.runner import Suite
from geometry.mat import Mat3
from geometry.quat import Quat, quat_from_mat3, slerp
from geometry.vec import Vec3


def apply3(m: Mat3, v: Vec3) -> Vec3:
    """Apply a 3×3 rotation matrix as a pure linear map to a Vec3."""
    var r = Vec3(0)
    comptime for i in range(3):
        r[i] = m.get(i, 0) * v[0] + m.get(i, 1) * v[1] + m.get(i, 2) * v[2]
    return r


def main() raises:
    var s = Suite("quat")
    comptime HALF_PI = 1.5707963

    # identity rotates nothing
    var rv = Quat.identity().rotate(Vec3(1, 2, 3))
    s.almost(Float64(rv[0]), 1.0, "id rotate x")
    s.almost(Float64(rv[1]), 2.0, "id rotate y")
    s.almost(Float64(rv[2]), 3.0, "id rotate z")

    # rotate (1,0,0) by +90deg about Z -> (0,1,0)
    var qz = Quat.from_axis_angle(Vec3(0, 0, 1), HALF_PI)
    var r = qz.rotate(Vec3(1, 0, 0))
    s.almost(Float64(r[0]), 0.0, "rotZ x", 1e-4)
    s.almost(Float64(r[1]), 1.0, "rotZ y", 1e-4)
    s.almost(Float64(r[2]), 0.0, "rotZ z", 1e-4)

    # q * conj(q) == identity for unit q
    var qc = qz * qz.conjugate()
    s.almost(Float64(qc.x), 0.0, "q*conj x")
    s.almost(Float64(qc.y), 0.0, "q*conj y")
    s.almost(Float64(qc.z), 0.0, "q*conj z")
    s.almost(Float64(qc.w), 1.0, "q*conj w")

    # to_mat3 rotation matches rotate()
    var q = Quat.from_axis_angle(Vec3(1, 1, 0), 0.9)
    var mm = q.to_mat3()
    var vv = Vec3(0.3, -0.7, 1.2)
    var via_m = apply3(mm, vv)
    var via_q = q.rotate(vv)
    s.almost(Float64(via_m[0]), Float64(via_q[0]), "mat==rotate x", 1e-4)
    s.almost(Float64(via_m[1]), Float64(via_q[1]), "mat==rotate y", 1e-4)
    s.almost(Float64(via_m[2]), Float64(via_q[2]), "mat==rotate z", 1e-4)

    # quat_from_mat3 round-trip (compare rotation action; sign of quat is ambiguous)
    var q2 = quat_from_mat3(mm)
    var via_q2 = q2.rotate(vv)
    s.almost(Float64(via_q2[0]), Float64(via_q[0]), "recovered rotate x", 1e-4)
    s.almost(Float64(via_q2[1]), Float64(via_q[1]), "recovered rotate y", 1e-4)
    s.almost(Float64(via_q2[2]), Float64(via_q[2]), "recovered rotate z", 1e-4)

    # slerp endpoints + unit norm + degenerate
    var qa = Quat.from_axis_angle(Vec3(0, 0, 1), 0.0)
    var qb = Quat.from_axis_angle(Vec3(0, 0, 1), HALF_PI)
    var e0 = slerp(qa, qb, 0.0)
    var e1 = slerp(qa, qb, 1.0)
    s.almost(Float64(e0.w), Float64(qa.w), "slerp t0 w")
    s.almost(Float64(e1.w), Float64(qb.w), "slerp t1 w", 1e-4)
    var mid = slerp(qa, qb, 0.5)
    s.almost(Float64(mid.norm()), 1.0, "slerp mid unit", 1e-4)
    var same = slerp(qb, qb, 0.3)
    s.almost(Float64(same.w), Float64(qb.w), "slerp same w", 1e-4)

    s.finish()
