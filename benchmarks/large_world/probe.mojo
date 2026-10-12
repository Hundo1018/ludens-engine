"""Precision probe for bench_large_world (ROADMAP 17.8), run against either
build/ (f32 world scalar) or build64/ (f64, `pixi run build-f64`).

    probe slow D   -> |travel - 0.5| of a box moving 0.5 m/s along x for 1 s from x = D
    probe stack D  -> top-box position (x - D, y, z) of a 3-box stack built at x = D after 4 s

Prints one line: `<WorldType> <value(s)>`.
"""

from std.sys import argv
from geometry.vec import Real, Vec3, WorldType
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig

comptime DT: Real = 1.0 / 60.0


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def main() raises:
    var args = argv()
    var mode = String(args[1])
    var D = Float64(atof(String(args[2])))
    var c = SolverConfig()
    c.broadphase = True
    var sc = ContactScene6[QuatBody6]()
    if mode == "slow":
        var id = sc.add(QuatBody6.at_rest(_v(Real(D), 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), _v(0.25, 0.25, 0.25), False)
        sc.set_can_sleep(id, False)
        sc.set_velocity(id, _v(0.5, 0, 0), _v(0, 0, 0))
        for _ in range(60):
            sc.step(DT, Vec3(0, 0, 0, 0), c)
        print(WorldType, abs(Float64(sc.bset.bodies[0].position()[0]) - D - 0.5))
    else:
        _ = sc.add(QuatBody6.at_rest(_v(Real(D), -0.5, 0), Inertia3.box(1, 5, 0.5, 5)), _v(5, 0.5, 5), True)
        for k in range(3):
            _ = sc.add(QuatBody6.at_rest(_v(Real(D), 0.25 + 0.51 * Real(k), 0), Inertia3.box(1, 0.25, 0.25, 0.25)), _v(0.25, 0.25, 0.25), False)
        for _ in range(240):
            sc.step(DT, Vec3(0, -9.8, 0, 0), c)
        var p = sc.bset.bodies[3].position()
        print(WorldType, Float64(p[0]) - D, Float64(p[1]), Float64(p[2]))
