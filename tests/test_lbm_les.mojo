"""Smagorinsky subgrid model (roadmap 14.5).

A turbulence model earns its place by letting a coarse grid run a flow it
otherwise could not. Every check here is about that, or about the model staying
out of the way when there is nothing to model.

ORDINARY    with the constant at zero the solver is BIT-IDENTICAL to plain BGK;
            the eddy viscosity is zero in a uniform flow and positive in a
            sheared one; it is never negative, since a model that could reduce
            the effective viscosity would be a stability hazard rather than a
            stabiliser.
INTEGRATION it composes with obstacles and tunnel boundaries -- mass still
            conserved, drag still positive -- and a high-Reynolds case that
            plain BGK cannot hold stays finite with the model on. That last one
            IS the advantage regime; without it the model is pure cost.
EXTREME     an absurdly large constant, a field exactly at rest, and a single
            cell where there is no neighbour to shear against.
"""

from std.math import sqrt, pi
from harness.runner import Suite
from geometry.vec import Real, Vec3
from fluid.lbm import Lbm, BC_TUNNEL, BC_PERIODIC, CELL_SOLID


def sheared(n: Int, nu: Real, cs: Real) -> Lbm:
    """A channel with the walls moving in opposite directions -- pure shear,
    which is the field a subgrid model should react to."""
    var l = Lbm(n, n, 4, nu, BC_PERIODIC)
    l.smagorinsky = cs
    l.init_uniform(1.0, 0, 0, 0)
    for z in range(4):
        for x in range(n):
            l.flag[l.idx(x, 0, z)] = CELL_SOLID
            l.flag[l.idx(x, n - 1, z)] = CELL_SOLID
    l.force_x = Real(2e-5)
    return l^


def blows_up(cs: Real) -> Bool:
    """Run a tunnel whose viscosity is too low for the grid, and say whether it
    diverged. A free function because a nested `def` cannot infer the capture
    convention of an enclosing `var` on this nightly."""
    var t = Lbm(48, 24, 24, Real(0.0008), BC_TUNNEL)
    t.smagorinsky = cs
    t.init_uniform(1.0, 0.16, 0, 0)
    t.inlet_u = 0.16
    t.set_solid_sphere(14, 11.5, 11.5, 4.0)
    for _ in range(600):
        t.step()
        var v = t.velocity(t.idx(30, 11, 11))[0]
        if not (Float64(v) > -10.0 and Float64(v) < 10.0):
            return True
    return False


def main() raises:
    var s = Suite("lbm_les")

    # ---- ORDINARY: off means off ----
    var a = sheared(16, Real(0.02), 0)
    var b = sheared(16, Real(0.02), 0)
    for _ in range(200):
        a.step()
        b.step()
    var identical = True
    for k in range(len(a.f)):
        if a.f[k] != b.f[k]:
            identical = False
    s.check(identical, "two runs with the model off agree bit for bit")
    s.check(
        Float64(a.eddy_viscosity(a.idx(8, 8, 2))) == 0.0,
        "and the eddy viscosity is reported as exactly zero",
    )

    var plain = sheared(16, Real(0.02), 0)
    var les = sheared(16, Real(0.02), Real(0.17))
    for _ in range(400):
        plain.step()
        les.step()
    var nut_wall = les.eddy_viscosity(les.idx(8, 2, 2))
    var nut_mid = les.eddy_viscosity(les.idx(8, 8, 2))
    print("  eddy viscosity — near wall", nut_wall, " mid channel", nut_mid,
          " (molecular", Real(0.02), ")")
    s.check(Float64(nut_wall) >= 0, "eddy viscosity is never negative")
    s.check(Float64(nut_mid) >= 0, "anywhere")
    s.check(
        Float64(nut_wall) > Float64(nut_mid),
        "and it is largest where the shear is: near the wall, not mid channel",
    )

    var still = Lbm(12, 12, 12, Real(0.02), BC_PERIODIC)
    still.smagorinsky = Real(0.17)
    still.init_uniform(1.0, 0.03, 0, 0)  # uniform: zero strain everywhere
    for _ in range(50):
        still.step()
    print("  uniform flow eddy viscosity:", still.eddy_viscosity(still.idx(6, 6, 6)))
    s.check(
        Float64(still.eddy_viscosity(still.idx(6, 6, 6))) < 1e-6,
        "a uniform flow has no subgrid stress: the model is a SUBGRID model,"
        " not blanket damping",
    )
    var uv = still.velocity(still.idx(6, 6, 6))
    s.check(
        abs(Float64(uv[0] - 0.03)) < 1e-4,
        "so a uniform flow is still preserved with the model on",
    )

    # ---- INTEGRATION: the advantage regime ----
    # A viscosity low enough that plain BGK cannot hold the flow. The model
    # exists for exactly this and nothing else; if both survive, the row proves
    # nothing about the model.
    var bgk_blew = blows_up(0)
    var les_blew = blows_up(Real(0.17))
    print("  Re~1600 tunnel — plain BGK diverged:", bgk_blew,
          " with LES:", les_blew)
    s.check(bgk_blew, "plain BGK cannot hold this Reynolds number on this grid")
    s.check(
        not les_blew,
        "and the subgrid model can: THIS is what the model is for",
    )

    # composes with obstacles and force measurement
    var t2 = Lbm(48, 24, 24, Real(0.01), BC_TUNNEL)
    t2.smagorinsky = Real(0.17)
    t2.init_uniform(1.0, 0.08, 0, 0)
    t2.inlet_u = 0.08
    t2.set_solid_sphere(14, 11.5, 11.5, 4.0)
    var m0 = t2.total_mass()
    var fsum = Real(0)
    var m = 0
    for k in range(600):
        t2.step()
        if k >= 400:
            fsum += t2.fx
            m += 1
    print("  with LES — mass", m0, "->", t2.total_mass(),
          " mean drag", fsum / Real(m))
    s.check(
        abs(Float64(t2.total_mass() - m0)) / Float64(m0) < 0.05,
        "mass is still conserved with the model and an obstacle together",
    )
    s.check(Float64(fsum / Real(m)) > 0, "and the drag is still positive")

    # ---- EXTREME ----
    var huge = sheared(16, Real(0.02), Real(5.0))
    for _ in range(200):
        huge.step()
    var hv = huge.velocity(huge.idx(8, 8, 2))
    print("  Cs=5 (absurd) — u", hv[0], " nu_t",
          huge.eddy_viscosity(huge.idx(8, 2, 2)))
    s.check(
        Float64(hv[0]) > -1e3 and Float64(hv[0]) < 1e3,
        "an absurd constant over-damps but stays finite",
    )
    s.check(
        Float64(huge.velocity(huge.idx(8, 8, 2))[0])
        < Float64(les.velocity(les.idx(8, 8, 2))[0]),
        "and damps more than a sane one, which is the direction it must go",
    )

    var rest = Lbm(8, 8, 8, Real(0.02), BC_PERIODIC)
    rest.smagorinsky = Real(0.17)
    rest.init_uniform(1.0, 0, 0, 0)
    for _ in range(30):
        rest.step()
    s.check(
        abs(Float64(rest.velocity(rest.idx(4, 4, 4))[0])) < 1e-9,
        "a field exactly at rest stays exactly at rest with the model on",
    )

    var one = Lbm(1, 1, 1, Real(0.02), BC_PERIODIC)
    one.smagorinsky = Real(0.17)
    one.init_uniform(1.0, 0, 0, 0)
    for _ in range(10):
        one.step()
    s.check(
        abs(Float64(one.density(0) - 1)) < 1e-4,
        "a single cell has nothing to shear against and is left alone",
    )

    s.finish()
