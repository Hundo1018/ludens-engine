"""Lattice Boltzmann: core, bounce-back obstacles, and tunnel boundaries (v3).

Covers roadmap 14.1 (D3Q19 collide/stream), 14.2 (half-way bounce-back with
voxelised obstacles) and 14.3 (fixed-velocity inlet, zero-gradient outlet),
which live in one module because a boundary condition is not separable from the
streaming step it modifies.

ORDINARY    the velocity set satisfies the moment conditions the equilibrium
            rests on; equilibrium reproduces the density and momentum it was
            built from; a uniform flow is preserved exactly; a forced channel
            reproduces the analytic Poiseuille parabola.
INTEGRATION mass is conserved with an obstacle in the flow; a symmetric
            obstacle in a symmetric tunnel produces a symmetric field; the
            tunnel reaches a steady state and stays there.
EXTREME     a single cell, a domain one cell thick, tau driven to the stability
            boundary, a zero initial field, an obstacle filling the domain, a
            one-cell-thick plate, and an obstacle flush against the inlet.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from fluid.d3q19 import (
    Q, cx, cy, cz, weight, opposite, equilibrium, tau_from_viscosity,
    viscosity_from_tau,
)
from fluid.lbm import Lbm, CELL_SOLID, CELL_FLUID, BC_PERIODIC, BC_TUNNEL


def main() raises:
    var s = Suite("lbm")

    # ---- ORDINARY: the velocity set ----
    var sw = Real(0)
    var m_x = Real(0)
    var m_xx = Real(0)
    var m_xy = Real(0)
    for i in range(Q):
        sw += weight(i)
        m_x += weight(i) * Real(cx(i))
        m_xx += weight(i) * Real(cx(i)) * Real(cx(i))
        m_xy += weight(i) * Real(cx(i)) * Real(cy(i))
    print("  moments — sum w", sw, " w*cx", m_x, " w*cx^2", m_xx, " w*cx*cy", m_xy)
    s.check(abs(Float64(sw - 1)) < 1e-6, "the weights sum to one")
    s.check(abs(Float64(m_x)) < 1e-6, "the first moment vanishes")
    s.check(
        abs(Float64(m_xx - Real(1.0) / 3.0)) < 1e-6,
        "the second moment is cs^2 = 1/3 -- what makes this Navier-Stokes",
    )
    s.check(abs(Float64(m_xy)) < 1e-6, "and the off-diagonal second moment vanishes")

    var opp_ok = True
    var self_opp = False
    for i in range(Q):
        var j = opposite(i)
        if cx(j) != -cx(i) or cy(j) != -cy(i) or cz(j) != -cz(i):
            opp_ok = False
        if j == i and i != 0:
            self_opp = True
    s.check(opp_ok, "every direction's opposite really is its negation")
    s.check(not self_opp, "and only the rest direction is its own opposite")

    var er = Real(0)
    var eu = Real(0)
    for i in range(Q):
        var fe = equilibrium(i, 1.0, 0.05, -0.02, 0.01)
        er += fe
        eu += fe * Real(cx(i))
    s.check(abs(Float64(er - 1)) < 1e-5, "equilibrium recovers its density")
    s.check(abs(Float64(eu - 0.05)) < 1e-5, "and its momentum")

    s.check(
        abs(Float64(viscosity_from_tau(tau_from_viscosity(0.07)) - 0.07)) < 1e-6,
        "tau and viscosity invert each other",
    )

    # ---- ORDINARY: uniform flow is a fixed point ----
    var uni = Lbm(8, 8, 8, Real(0.05), BC_PERIODIC)
    uni.init_uniform(1.0, 0.05, 0, 0)
    var m0 = uni.total_mass()
    for _ in range(50):
        uni.step()
    var v = uni.velocity(uni.idx(4, 4, 4))
    print("  uniform after 50 steps — mass", uni.total_mass(), " u", v[0])
    s.check(
        abs(Float64(uni.total_mass() - m0)) < 1e-3,
        "a periodic domain conserves mass exactly",
    )
    s.check(
        abs(Float64(v[0] - 0.05)) < 1e-5,
        "and a uniform flow is preserved: it IS the equilibrium",
    )
    s.check(abs(Float64(v[1])) < 1e-6, "with no spurious transverse velocity")

    # ---- ORDINARY: Poiseuille against the analytic parabola ----
    comptime NY = 21
    var nu = Real(0.1)
    var ch = Lbm(4, NY, 4, nu, BC_PERIODIC)
    for z in range(4):
        for x in range(4):
            ch.flag[ch.idx(x, 0, z)] = CELL_SOLID
            ch.flag[ch.idx(x, NY - 1, z)] = CELL_SOLID
    ch.init_uniform(1.0, 0, 0, 0)
    ch.force_x = Real(1e-5)
    for _ in range(6000):
        ch.step()
    # half-way bounce-back puts the no-slip surface midway between the last
    # fluid cell and the solid, so the effective half-width is (NY-2)/2
    var hw = Real(NY - 2) * 0.5
    var umax = ch.force_x * hw * hw / (Real(2) * nu)
    var worst = Real(0)
    for y in range(1, NY - 1):
        var yy = Real(y) - Real(NY - 1) * 0.5
        var ua = ch.force_x * (hw * hw - yy * yy) / (Real(2) * nu)
        var e = abs(ch.velocity(ch.idx(2, y, 2))[0] - ua)
        if e > worst:
            worst = e
    print("  Poiseuille — analytic umax", umax, " worst error", worst,
          " relative", worst / umax)
    s.check(
        Float64(worst / umax) < 0.01,
        "the forced channel reproduces the analytic parabola within 1%",
    )

    # ---- INTEGRATION: an obstacle in a tunnel ----
    var t = Lbm(24, 12, 12, Real(0.02), BC_TUNNEL)
    t.init_uniform(1.0, 0.05, 0, 0)
    t.inlet_u = 0.05
    t.set_solid_sphere(8, 5.5, 5.5, 2.5)
    var nsolid = t.solid_count()
    print("  tunnel obstacle cells:", nsolid)
    s.check(nsolid > 20, "the sphere voxelised to a real obstacle")
    for _ in range(300):
        t.step()
    var mid = t.velocity(t.idx(8, 5, 5))
    var wake = t.velocity(t.idx(14, 5, 5))
    var free = t.velocity(t.idx(14, 1, 1))
    print("  inside solid u", mid[0], " wake u", wake[0], " freestream u", free[0])
    s.check(
        Float64(wake[0]) < Float64(free[0]),
        "the wake behind the obstacle is slower than the freestream",
    )
    s.check(Float64(free[0]) > 0.02, "and the freestream is still moving")

    # symmetry: a sphere centred in y and z must give a field symmetric in y
    var asym = Real(0)
    for y in range(1, 6):
        var a = t.velocity(t.idx(14, y, 5))[0]
        var b = t.velocity(t.idx(14, 11 - y, 5))[0]
        if abs(a - b) > asym:
            asym = abs(a - b)
    print("  worst y-asymmetry in the wake:", asym)
    s.check(
        Float64(asym) < 1e-4,
        "a symmetric obstacle in a symmetric tunnel gives a symmetric field",
    )

    # steady state: the field stops changing
    var before = t.velocity(t.idx(14, 5, 5))[0]
    for _ in range(100):
        t.step()
    var after = t.velocity(t.idx(14, 5, 5))[0]
    print("  wake drift over 100 more steps:", abs(after - before))
    s.check(
        Float64(abs(after - before)) < 0.01 * Float64(free[0]),
        "the tunnel reaches a steady state and stays there",
    )

    # mass with an obstacle present: bounce-back must not leak
    var box = Lbm(16, 16, 16, Real(0.05), BC_PERIODIC)
    box.init_uniform(1.0, 0.03, 0.01, 0)
    box.set_solid_box(Vec3(6, 6, 6), Vec3(9, 9, 9))
    var bm0 = box.total_mass()
    for _ in range(200):
        box.step()
    print("  mass with obstacle — start", bm0, " end", box.total_mass())
    s.check(
        abs(Float64(box.total_mass() - bm0)) / Float64(bm0) < 1e-4,
        "half-way bounce-back leaks no mass",
    )

    # ---- EXTREME ----
    var one = Lbm(1, 1, 1, Real(0.05), BC_PERIODIC)
    one.init_uniform(1.0, 0, 0, 0)
    for _ in range(10):
        one.step()
    s.check(
        abs(Float64(one.density(0) - 1)) < 1e-4,
        "a single periodic cell is its own neighbour and stays put",
    )

    var thin = Lbm(8, 1, 8, Real(0.05), BC_PERIODIC)
    thin.init_uniform(1.0, 0.04, 0, 0)
    var tm = thin.total_mass()
    for _ in range(50):
        thin.step()
    s.check(
        abs(Float64(thin.total_mass() - tm)) < 1e-3,
        "a domain one cell thick still conserves mass",
    )

    # tau at the stability boundary: nu -> 0 means tau -> 0.5
    var edge = Lbm(8, 8, 8, Real(0.0005), BC_PERIODIC)
    print("  tau at nu=5e-4:", edge.tau)
    s.check(
        Float64(edge.tau) > 0.5 and Float64(edge.tau) < 0.52,
        "a tiny viscosity puts tau just above the 0.5 boundary",
    )
    edge.init_uniform(1.0, 0.02, 0, 0)
    for _ in range(200):
        edge.step()
    var ev = edge.velocity(edge.idx(4, 4, 4))
    s.check(
        Float64(ev[0]) > -1e3 and Float64(ev[0]) < 1e3,
        "and the solve stays finite there rather than blowing up",
    )

    var zero = Lbm(6, 6, 6, Real(0.05), BC_PERIODIC)
    zero.init_uniform(1.0, 0, 0, 0)
    for _ in range(20):
        zero.step()
    var zv = zero.velocity(zero.idx(3, 3, 3))
    s.check(
        abs(Float64(zv[0])) < 1e-9 and abs(Float64(zv[1])) < 1e-9,
        "a field at rest stays exactly at rest",
    )

    var full = Lbm(6, 6, 6, Real(0.05), BC_PERIODIC)
    full.init_uniform(1.0, 0.05, 0, 0)
    full.set_solid_box(Vec3(0, 0, 0), Vec3(5, 5, 5))
    s.eqi(full.solid_count(), 216, "an obstacle can fill the whole domain")
    for _ in range(10):
        full.step()
    s.check(
        Float64(full.total_mass()) == 0.0,
        "and then there is no fluid left to conserve",
    )

    var plate = Lbm(16, 12, 6, Real(0.03), BC_TUNNEL)
    plate.init_uniform(1.0, 0.04, 0, 0)
    plate.inlet_u = 0.04
    plate.set_solid_box(Vec3(8, 3, 0), Vec3(8, 8, 5))  # one cell thick
    for _ in range(150):
        plate.step()
    var behind = plate.velocity(plate.idx(10, 5, 3))[0]
    var beside = plate.velocity(plate.idx(10, 1, 3))[0]
    print("  thin plate — behind", behind, " beside", beside)
    s.check(
        Float64(behind) < Float64(beside),
        "a plate one cell thick still blocks the flow",
    )

    var flush = Lbm(16, 8, 8, Real(0.03), BC_TUNNEL)
    flush.init_uniform(1.0, 0.04, 0, 0)
    flush.inlet_u = 0.04
    flush.set_solid_box(Vec3(0, 2, 2), Vec3(1, 5, 5))  # touching the inlet
    var fm0 = flush.total_mass()
    for _ in range(100):
        flush.step()
    var ffin = flush.total_mass()
    print("  obstacle flush with the inlet — mass", fm0, "->", ffin)
    s.check(
        Float64(ffin) > 0.5 * Float64(fm0) and Float64(ffin) < 2.0 * Float64(fm0),
        "an obstacle touching the inlet neither starves nor floods the domain",
    )

    s.finish()
