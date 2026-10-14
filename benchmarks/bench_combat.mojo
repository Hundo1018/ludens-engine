"""ROADMAP 17.71: melee detection modes and projectile cost.

Table 1: a blade (0.2 to 1.0 m from the pivot, 1 cm radius) sweeps 1.5 rad
about the vertical; 200 thin shields (1 cm radius, 0.4 m tall) are placed
on its arc at random angles and radii 0.3-1.0 m, one at a time. Per angular
speed (rad per tick) and mode: the share of shields detected, and the
nanoseconds per `Swing.step` (the arc and linear modes sample so no blade
point moves more than 1 cm).
Table 2: N projectiles with quadratic drag over a floor, one step each:
microseconds per step (one ray cast per projectile).
"""

from std.time import perf_counter_ns
from std.math import cos, sin
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from gameplay.combat import Hurtbox, Swing, DETECT_DISCRETE, DETECT_LINEAR, DETECT_ARC
from gameplay.projectile import ProjectileSet, DRAG_QUADRATIC


struct _Rng:
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed

    def next(mut self) -> Real:
        self.s = self.s * 6364136223846793005 + 1442695040888963407
        return Real(Float64((self.s >> 11) & 0xFFFFFFFF) / 4294967296.0)


def _row(mode: Int, dtheta: Real) -> Tuple[Int, Int]:
    var rng = _Rng(11)
    var hits = 0
    var ns = 0
    var steps = 0
    var axis = Vec3(0, 1, 0, 0)
    for _ in range(200):
        var phi = 0.1 + rng.next() * 1.3
        var rad = 0.3 + rng.next() * 0.7
        var c = Vec3(rad * cos(phi), 0, -rad * sin(phi), 0)
        var boxes: List[Hurtbox] = [Hurtbox(1, 0, 1, 1.0, c - Vec3(0, 0.2, 0, 0), c + Vec3(0, 0.2, 0, 0), 0.01)]
        var sw = Swing(0, 0.2, 1.0, 0.01, mode, 0.01)
        sw.begin(Vec3(0, 0, 0, 0), Quat.from_axis_angle(axis, 0))
        var th = Real(0)
        var t0 = Int(perf_counter_ns())
        while th < 1.5:
            th += dtheta
            hits += len(sw.step(Vec3(0, 0, 0, 0), Quat.from_axis_angle(axis, th), boxes))
            steps += 1
        ns += Int(perf_counter_ns()) - t0
    return (hits, ns // max(steps, 1))


def main() raises:
    print("### Combat (17.71): melee detection vs swing speed\n")
    print("| rad / tick | tip speed m/s | discrete hit % | linear hit % | arc hit % | discrete ns | linear ns | arc ns |")
    print("|---:|---:|---:|---:|---:|---:|---:|---:|")
    for dth in [Real(0.05), Real(0.3), Real(0.6), Real(1.2)]:
        var d = _row(DETECT_DISCRETE, dth)
        var l = _row(DETECT_LINEAR, dth)
        var a = _row(DETECT_ARC, dth)
        print("|", dth, "|", Int(dth * 60), "|", d[0] // 2, "|", l[0] // 2, "|", a[0] // 2, "|", d[1], "|", l[1], "|", a[1], "|")
    print("")
    print("| projectiles | us per step |")
    print("|---:|---:|")
    for n in [1000, 10000]:
        var sc = ContactScene6[QuatBody6]()
        _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 500, 0.5, 500)), Vec3(500, 0.5, 500, 0), True)
        var ps = ProjectileSet(n, DRAG_QUADRATIC, 0.01)
        for i in range(n):
            _ = ps.spawn(Vec3(Real(i % 100), 2, Real(i // 100), 0), Vec3(30, 10, 0, 0))
        var t0 = Int(perf_counter_ns())
        for _ in range(10):
            _ = ps.step(sc, 1.0 / 60.0, Vec3(0, -9.8, 0, 0))
        print("|", n, "|", (Int(perf_counter_ns()) - t0) // 10000, "|")
    print("")
