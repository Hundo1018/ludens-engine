# tier: integration
"""Wing polar from the LBM tunnel (ROADMAP 17.74).

`Wing.set_polar` swaps the analytic CL(alpha) for a sampled table;
`vehicle_tunnel.plate_polar` fills one from a flat plate in an `Lbm` tunnel
(lattice Re 40, so a viscous polar). The table lookup is checked on a
synthetic table, then on the tunnel polar at 0 / 30 / 60 / 90 degrees.
"""

from std.math import pi
from harness.runner import Suite
from geometry.vec import Real, Vec3
from gameplay.aircraft import Wing
from gameplay.vehicle_tunnel import plate_polar


def main() raises:
    var s = Suite("wing_polar")

    # 1. lookup on a synthetic table: cl 0, 1, 2 and cd 0.1, 0.2, 0.3 at 0, 0.5, 1.0
    var w = Wing.simple(Vec3(0, 0, 0, 0), 1)
    w.set_polar([Real(0), Real(1), Real(2)], [Real(0.1), Real(0.2), Real(0.3)], 0.5)
    var a = w.coefficients(0.25)
    var b = w.coefficients(-0.25)
    var c = w.coefficients(Real(pi) - 0.25)
    var d = w.coefficients(1.2)
    print("table lookup: +0.25", a[0], a[1], " -0.25", b[0], b[1], " pi-0.25", c[0], c[1], " past the end 1.2", d[0], d[1])
    s.check(abs(a[0] - 0.5) < 1e-6 and abs(a[1] - 0.15) < 1e-6, "interpolates between samples")
    s.check(abs(b[0] + 0.5) < 1e-6 and abs(b[1] - 0.15) < 1e-6, "CL is odd in alpha, CD even")
    s.check(abs(c[0] + 0.5) < 1e-5 and abs(c[1] - 0.15) < 1e-5, "mirrored about pi / 2 beyond (CL flips sign)")
    s.check(abs(d[0] - 2) < 1e-6 and abs(d[1] - 0.3) < 1e-6, "clamps at the last sample")
    var raised = False
    try:
        var bad = Wing.simple(Vec3(0, 0, 0, 0), 1)
        bad.set_polar([Real(0)], [Real(0)], 0.5)
    except:
        raised = True
    s.check(raised, "a one-sample table is refused")

    # 2. the tunnel polar of a flat plate, coarse domain
    var cl = List[Real]()
    var cd = List[Real]()
    var step = Real(pi) / 6
    for k in range(4):
        var p = plate_polar(Real(k) * step, 16, 80, 56, 4, 0.05, 0.02, 1500, 300)
        cl.append(p.cl)
        cd.append(p.cd)
        print("plate", k * 30, "deg: CL", p.cl, " CD", p.cd)
    s.check(abs(cl[0]) < 1e-3, "no lift at zero angle of attack")
    s.check(cl[1] > 0.3 and cl[1] < 6.2831855 * step, "lift at 30 degrees is positive and below the inviscid 2 pi alpha")
    s.check(cd[3] > 2 * cd[0], "broadside drag is more than twice the edge-on drag")
    w.set_polar(cl.copy(), cd.copy(), step)
    var at = w.coefficients(step)
    s.check(at[0] == cl[1] and at[1] == cd[1], "the Wing returns the tunnel value at a sample")
    s.finish()
