"""ROADMAP 17.46: cost of continuous collision for hulls (conservative
advancement on the exact distance) and of the swept-box candidate BVH.

1. N hull bullets (cubes, half 0.1) at 60 m/s toward a thin wall, 30 steps:
   ms per step with CCD off (they tunnel) and on (they stop).
2. Control: N hulls resting on a floor (slow, so CCD only builds the
   candidate tree and clamps nothing): ms per step off / on.
"""

from std.time import perf_counter_ns
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0


def _cube(h: Real) -> List[Real]:
    var v = List[Real]()
    for c in range(8):
        v.append(h if c & 1 else -h)
        v.append(h if c & 2 else -h)
        v.append(h if c & 4 else -h)
    return v^


def _bullets(n: Int, ccd: Bool) raises -> Int:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 0.025, 20, 20)), Vec3(0.025, 20, 20, 0), True)
    for k in range(n):
        var b = QuatBody6.at_rest(Vec3(-2.5, Real(k % 12) * 0.5 - 3, Real(k // 12) * 0.5 - 3, 0), Inertia3.box(1, 0.1, 0.1, 0.1))
        b.vel = Vec3(60, 0, 0, 0)
        _ = sc.add_hull(b^, _cube(0.1), False)
    var t0 = Int(perf_counter_ns())
    for _ in range(30):
        sc.step_soft(DT, Vec3(0, 0, 0, 0), ccd=ccd)
    return (Int(perf_counter_ns()) - t0) // 30


def _resting(n: Int, ccd: Bool) raises -> Int:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    for k in range(n):
        _ = sc.add_hull(QuatBody6.at_rest(Vec3(Real(k % 12) * 0.5 - 3, 0.1, Real(k // 12) * 0.5 - 3, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), _cube(0.1), False)
    for _ in range(30):
        sc.step_soft(DT, Vec3(0, -9.8, 0, 0), ccd=ccd)
    var t0 = Int(perf_counter_ns())
    for _ in range(30):
        sc.step_soft(DT, Vec3(0, -9.8, 0, 0), ccd=ccd)
    return (Int(perf_counter_ns()) - t0) // 30


def main() raises:
    print("### CCD shape coverage (17.46): hull bullets vs a thin wall\n")
    print("| N | scene | CCD off (us/step) | CCD on (us/step) |")
    print("|---:|---|---:|---:|")
    for n in [1, 16, 128]:
        print("|", n, "| bullets at 60 m/s |", _bullets(n, False) // 1000, "|", _bullets(n, True) // 1000, "|")
        print("|", n, "| resting (control) |", _resting(n, False) // 1000, "|", _resting(n, True) // 1000, "|")
    print("")
