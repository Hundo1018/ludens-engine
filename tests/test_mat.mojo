from harness.runner import Suite
from geometry.mat import (
    Mat3,
    Mat4,
    transform_point3,
    transform_dir3,
    transform_point4,
    transform_dir4,
    transform_point4_simd,
    affine_inverse3,
    affine_inverse4,
    compose_trs3,
)
from geometry.quat import Quat, compose_trs4
from geometry.vec import Vec2, Vec3


def main() raises:
    var s = Suite("mat")
    comptime HALF_PI = 1.5707963

    # identity
    var id4 = Mat4.identity()
    s.almost(Float64(id4.get(0, 0)), 1.0, "id4 00")
    s.almost(Float64(id4.get(1, 0)), 0.0, "id4 10")
    s.almost(Float64(id4.get(2, 2)), 1.0, "id4 22")

    # 2D affine: translate (2,3), no rotation/scale
    var a2 = compose_trs3(Vec2(2, 3), 0.0, Vec2(1, 1))
    var p2 = transform_point3(a2, Vec2(1, 0))
    s.almost(Float64(p2[0]), 3.0, "trs3 point x")
    s.almost(Float64(p2[1]), 3.0, "trs3 point y")
    var d2 = transform_dir3(a2, Vec2(1, 0))
    s.almost(Float64(d2[0]), 1.0, "trs3 dir x (no translation)")
    s.almost(Float64(d2[1]), 0.0, "trs3 dir y")

    # 2D rotation by pi/2: (1,0) -> (0,1)
    var rot2 = compose_trs3(Vec2(0, 0), HALF_PI, Vec2(1, 1))
    var rp = transform_point3(rot2, Vec2(1, 0))
    s.almost(Float64(rp[0]), 0.0, "rot2 x", 1e-4)
    s.almost(Float64(rp[1]), 1.0, "rot2 y", 1e-4)

    # 3D affine: translate (1,2,3), identity rot/scale
    var m4 = compose_trs4(Vec3(1, 2, 3), Quat.identity(), Vec3(1, 1, 1))
    var p4 = transform_point4(m4, Vec3(1, 1, 1))
    s.almost(Float64(p4[0]), 2.0, "trs4 point x")
    s.almost(Float64(p4[1]), 3.0, "trs4 point y")
    s.almost(Float64(p4[2]), 4.0, "trs4 point z")
    var d4 = transform_dir4(m4, Vec3(1, 1, 1))
    s.almost(Float64(d4[0]), 1.0, "trs4 dir x")

    # scalar vs SIMD transform parity
    var mq = compose_trs4(
        Vec3(5, -2, 1), Quat.from_axis_angle(Vec3(0, 0, 1), 0.7), Vec3(2, 1, 0.5)
    )
    var ps = transform_point4(mq, Vec3(3, 4, 5))
    var pv = transform_point4_simd(mq, Vec3(3, 4, 5))
    s.almost(Float64(ps[0]), Float64(pv[0]), "scalar==simd x", 1e-4)
    s.almost(Float64(ps[1]), Float64(pv[1]), "scalar==simd y", 1e-4)
    s.almost(Float64(ps[2]), Float64(pv[2]), "scalar==simd z", 1e-4)

    # affine inverse: inv(M) * M == identity
    var inv = affine_inverse4(mq)
    var prod = inv * mq
    comptime for i in range(4):
        comptime for j in range(4):
            var want = 1.0 if i == j else 0.0
            s.almost(Float64(prod.get(i, j)), want, "inv4*M==I", 1e-3)

    # 2D affine inverse round-trip on a point
    var a2b = compose_trs3(Vec2(3, -1), 0.5, Vec2(2, 2))
    var inv3 = affine_inverse3(a2b)
    var there = transform_point3(a2b, Vec2(7, 9))
    var back = transform_point3(inv3, there)
    s.almost(Float64(back[0]), 7.0, "inv3 roundtrip x", 1e-3)
    s.almost(Float64(back[1]), 9.0, "inv3 roundtrip y", 1e-3)

    s.finish()
