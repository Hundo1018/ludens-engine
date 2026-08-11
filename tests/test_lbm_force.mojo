"""Surface force integration: turning the tunnel into a measurement (14.4).

Momentum exchange accumulates the force on a solid across its bounce-back
links. Every check here is physical rather than a stored number, because a
regression test on a drag coefficient would lock in whatever the code did on
the day it was written.

ORDINARY    a body in still fluid feels no force; a symmetric body in a
            symmetric flow feels no lift; the force scales with the square of
            the free-stream velocity, as a drag must.
INTEGRATION the drag coefficient of a sphere is compared to the
            Schiller-Naumann correlation, and the deviation is checked to
            SHRINK with resolution -- a single number agreeing at one
            resolution proves nothing, a trend toward the correlation is the
            real claim.
EXTREME     a body entirely inside a wall, zero free-stream velocity, and a
            blockage ratio approaching one.
"""

from std.math import sqrt, pi
from harness.runner import Suite
from geometry.vec import Real, Vec3
from fluid.lbm import Lbm, BC_TUNNEL, BC_PERIODIC, CELL_SOLID


def schiller_naumann(re: Real) -> Real:
    """The standard sphere-drag correlation, valid to Re ~ 800. This is the
    reference the simulation is held to; it is an empirical fit to experiment,
    not another simulation, which is what makes it worth comparing against."""
    return (24.0 / re) * (1.0 + 0.15 * (Real(re) ** Real(0.687)))


def sphere_cd(
    nx: Int, ny: Int, r: Real, u: Real, nu: Real, steps: Int, avg: Int
) -> Real:
    var t = Lbm(nx, ny, ny, nu, BC_TUNNEL)
    t.init_uniform(1.0, u, 0, 0)
    t.inlet_u = u
    t.set_solid_sphere(Real(nx) * 0.3, Real(ny - 1) * 0.5, Real(ny - 1) * 0.5, r)
    var acc = Real(0)
    var m = 0
    for k in range(steps):
        t.step()
        if k >= steps - avg:
            acc += t.fx
            m += 1
    var area = Real(pi) * r * r
    return (acc / Real(m)) / (Real(0.5) * u * u * area)


def main() raises:
    var s = Suite("lbm_force")

    # ---- ORDINARY ----
    var still = Lbm(16, 16, 16, Real(0.05), BC_PERIODIC)
    still.init_uniform(1.0, 0, 0, 0)
    still.set_solid_sphere(8, 8, 8, 3)
    for _ in range(50):
        still.step()
    print("  still fluid force:", still.fx, still.fy, still.fz)
    s.check(
        abs(Float64(still.fx)) < 1e-5
        and abs(Float64(still.fy)) < 1e-5
        and abs(Float64(still.fz)) < 1e-5,
        "a body in still fluid feels no force",
    )

    var t = Lbm(48, 24, 24, Real(0.02), BC_TUNNEL)
    t.init_uniform(1.0, 0.05, 0, 0)
    t.inlet_u = 0.05
    t.set_solid_sphere(14, 11.5, 11.5, 3.5)
    var fx = Real(0)
    var fy = Real(0)
    var fz = Real(0)
    var m = 0
    for k in range(900):
        t.step()
        if k >= 700:
            fx += t.fx
            fy += t.fy
            fz += t.fz
            m += 1
    fx /= Real(m)
    fy /= Real(m)
    fz /= Real(m)
    print("  sphere in tunnel — Fx", fx, " Fy", fy, " Fz", fz)
    s.check(Float64(fx) > 0, "drag points downstream")
    s.check(
        abs(Float64(fy)) < 1e-3 * Float64(fx)
        and abs(Float64(fz)) < 1e-3 * Float64(fx),
        "a symmetric body in a symmetric flow feels no lift",
    )

    # drag scales as u^2: doubling the free stream must roughly quadruple Fx
    var t2 = Lbm(48, 24, 24, Real(0.02), BC_TUNNEL)
    t2.init_uniform(1.0, 0.1, 0, 0)
    t2.inlet_u = 0.1
    t2.set_solid_sphere(14, 11.5, 11.5, 3.5)
    var fx2 = Real(0)
    var m2 = 0
    for k in range(900):
        t2.step()
        if k >= 700:
            fx2 += t2.fx
            m2 += 1
    fx2 /= Real(m2)
    var ratio = fx2 / fx
    print("  doubling u: force ratio", ratio, " (u^2 would give 4)")
    # Not exactly 4: Cd itself falls with Reynolds number, so the ratio lands
    # between the linear (Stokes) and quadratic limits. Bracketing it is the
    # honest check; demanding 4 would be demanding the wrong physics.
    s.check(
        Float64(ratio) > 2.0 and Float64(ratio) < 4.0,
        "force grows between linearly and quadratically with speed, as Cd falls",
    )

    # ---- INTEGRATION: against the correlation, and its TREND ----
    var u = Real(0.05)
    var nu = Real(0.02)
    var r_lo = Real(3.0)
    var r_hi = Real(5.0)
    var re_lo = u * 2 * r_lo / nu
    var re_hi = u * 2 * r_hi / nu
    var cd_lo = sphere_cd(48, 24, r_lo, u, nu, 1200, 300)
    var cd_hi = sphere_cd(80, 40, r_hi, u, nu, 1200, 300)
    var ref_lo = schiller_naumann(re_lo)
    var ref_hi = schiller_naumann(re_hi)
    var err_lo = abs(cd_lo - ref_lo) / ref_lo
    var err_hi = abs(cd_hi - ref_hi) / ref_hi
    print("  r=3  Re", re_lo, " Cd", cd_lo, " Schiller-Naumann", ref_lo,
          " rel err", err_lo)
    print("  r=5  Re", re_hi, " Cd", cd_hi, " Schiller-Naumann", ref_hi,
          " rel err", err_hi)
    s.check(
        Float64(cd_lo) > 0.5 * Float64(ref_lo)
        and Float64(cd_lo) < 2.5 * Float64(ref_lo),
        "a coarse voxelised sphere lands within a factor of the correlation",
    )
    s.check(
        Float64(err_hi) < Float64(err_lo),
        "and the deviation SHRINKS with resolution -- the trend is the claim,"
        " not the single number",
    )

    # ---- EXTREME ----
    var buried = Lbm(24, 16, 16, Real(0.03), BC_TUNNEL)
    buried.init_uniform(1.0, 0.04, 0, 0)
    buried.inlet_u = 0.04
    buried.set_solid_box(Vec3(0, 0, 0), Vec3(23, 15, 15))
    for _ in range(30):
        buried.step()
    s.check(
        Float64(buried.fx) == 0.0,
        "a solid with no fluid neighbours feels nothing: there are no links",
    )

    var zero_u = Lbm(32, 16, 16, Real(0.03), BC_TUNNEL)
    zero_u.init_uniform(1.0, 0, 0, 0)
    zero_u.inlet_u = 0
    zero_u.set_solid_sphere(10, 7.5, 7.5, 3)
    for _ in range(200):
        zero_u.step()
    print("  zero free stream — Fx", zero_u.fx,
          " Cd", zero_u.drag_coefficient(0, 28.3))
    s.check(
        abs(Float64(zero_u.fx)) < 1e-5,
        "a tunnel with no inflow exerts no drag",
    )
    s.check(
        Float64(zero_u.drag_coefficient(0, 28.3)) == 0.0,
        "and the coefficient is reported as zero rather than dividing by it",
    )

    # blockage approaching one: the body nearly fills the tunnel
    var blocked = Lbm(32, 12, 12, Real(0.03), BC_TUNNEL)
    blocked.init_uniform(1.0, 0.04, 0, 0)
    blocked.inlet_u = 0.04
    blocked.set_solid_sphere(12, 5.5, 5.5, 5.0)
    for _ in range(300):
        blocked.step()
    var cd_blocked = blocked.drag_coefficient(0.04, Real(pi) * 25)
    print("  blockage ~55% — Cd", cd_blocked)
    s.check(
        Float64(cd_blocked) > 0,
        "a nearly-plugged tunnel still reports a finite positive drag",
    )
    s.check(
        Float64(cd_blocked) > 2.0 * Float64(cd_lo),
        "and a far larger one than the unblocked case: blockage inflates Cd,"
        " which is exactly what a real tunnel has to correct for",
    )

    s.finish()
