"""LBM validation against known values (roadmap 14.6).

The other LBM tests check that the code does what the code was written to do.
This one checks that what it does is PHYSICS, by holding it to numbers that
exist independently of this engine: closed-form solutions, a lattice constant
fixed by the velocity set, and an empirical correlation fitted to experiment.

Each case names its reference and its tolerance, and the tolerances are set by
what the method can actually deliver at these resolutions rather than by what
happened to pass.

  1. SHEAR WAVE DECAY -- the sharpest test available. A sinusoidal velocity
     profile decays as exp(-nu k^2 t). Fitting that rate recovers the viscosity
     the solver ACTUALLY has, which Chapman-Enskog says must be (tau-0.5)/3.
     Nothing about the implementation is assumed; the number comes out of the
     simulation and is compared to theory.
  2. SPEED OF SOUND -- cs = 1/sqrt(3) in lattice units, fixed by the second
     moment of the weights. A pressure pulse must travel at it.
  3. POISEUILLE -- the closed-form parabola, at two resolutions to show the
     error falling.
  4. STOKES DRAG -- as Re goes to zero, Cd must approach 24/Re. This is the
     limit Schiller-Naumann reduces to and it is exact.
"""

from std.math import sqrt, pi, sin, log
from harness.runner import Suite
from geometry.vec import Real, Vec3
from fluid.lbm import Lbm, BC_PERIODIC, BC_TUNNEL, CELL_SOLID
from fluid.d3q19 import viscosity_from_tau, equilibrium


def shear_amplitude(l: Lbm, ny: Int) -> Real:
    """Amplitude of the sin(2 pi y / ny) mode in u_x, by projection."""
    var acc = Real(0)
    for y in range(ny):
        acc += l.velocity(l.idx(2, y, 2))[0] * Real(sin(Float64(2) * pi * Float64(y) / Float64(ny)))
    return acc * 2 / Real(ny)


def main() raises:
    var s = Suite("lbm_validation")

    # ---- 1. shear wave decay recovers the viscosity ----
    comptime NY = 32
    var nu_in = Real(0.03)
    var l = Lbm(4, NY, 4, nu_in, BC_PERIODIC)
    var u0 = Real(0.01)
    for z in range(4):
        for y in range(NY):
            var uy = u0 * Real(sin(Float64(2) * pi * Float64(y) / Float64(NY)))
            for x in range(4):
                var c = l.idx(x, y, z)
                for i in range(19):
                    l.f[i * l.cells() + c] = equilibrium(i, 1.0, uy, 0, 0)
    var a0 = shear_amplitude(l, NY)
    var steps = 400
    for _ in range(steps):
        l.step()
    var a1 = shear_amplitude(l, NY)
    var k = Real(2) * Real(pi) / Real(NY)
    var nu_measured = -Real(log(Float64(a1 / a0))) / (k * k * Real(steps))
    print("  shear wave — amplitude", a0, "->", a1)
    print("    nu measured", nu_measured, " input", nu_in,
          " tau-derived", viscosity_from_tau(l.tau),
          " rel err", abs(nu_measured - nu_in) / nu_in)
    s.check(
        Float64(abs(nu_measured - nu_in) / nu_in) < 0.05,
        "the decay rate recovers the input viscosity within 5%:"
        " Chapman-Enskog nu = (tau - 0.5)/3 holds in the actual solver",
    )
    s.check(
        abs(Float64(viscosity_from_tau(l.tau) - nu_in)) < 1e-6,
        "and the tau it stored matches the viscosity it was asked for",
    )

    # ---- 2. speed of sound ----
    comptime NX = 64
    var snd = Lbm(NX, 4, 4, Real(0.001), BC_PERIODIC)
    snd.init_uniform(1.0, 0, 0, 0)
    var c0 = snd.idx(NX // 2, 2, 2)
    for i in range(19):
        snd.f[i * snd.cells() + c0] = equilibrium(i, 1.02, 0, 0, 0)
    var travel = 20
    for _ in range(travel):
        snd.step()
    # The PEAK of the outgoing wave, not its leading edge. A single-cell
    # density perturbation contains every wavelength, and the fastest lattice
    # velocity is one cell per step, so a vanishing amount of signal always
    # runs ahead ballistically at speed 1. Thresholding on "has anything
    # arrived" measures that instead of the sound speed -- it read 0.95 against
    # a theory of 0.577, which is the ballistic limit and not a bug in the
    # solver.
    var front = NX // 2 + 1
    var best = Real(0)
    for x in range(NX // 2 + 1, NX - 1):
        var amp = abs(snd.density(snd.idx(x, 2, 2)) - 1)
        if amp > best:
            best = amp
            front = x
    var cs_measured = Real(front - NX // 2) / Real(travel)
    var cs_theory = Real(1) / Real(sqrt(3.0))
    print("  sound peak at x =", front, " after", travel,
          " steps -> cs", cs_measured, " theory", cs_theory)
    s.check(
        Float64(abs(cs_measured - cs_theory) / cs_theory) < 0.15,
        "a pressure pulse travels at cs = 1/sqrt(3), the lattice sound speed",
    )

    # ---- 3. Poiseuille at two resolutions ----
    var errs = List[Real](capacity=2)
    var sizes = List[Int](capacity=2)
    sizes.append(11)
    sizes.append(31)
    for si in range(2):
        var n = sizes[si]
        var nu = Real(0.1)
        var ch = Lbm(4, n, 4, nu, BC_PERIODIC)
        for z in range(4):
            for x in range(4):
                ch.flag[ch.idx(x, 0, z)] = CELL_SOLID
                ch.flag[ch.idx(x, n - 1, z)] = CELL_SOLID
        ch.init_uniform(1.0, 0, 0, 0)
        ch.force_x = Real(1e-5)
        for _ in range(8000):
            ch.step()
        var hw = Real(n - 2) * 0.5
        var umax = ch.force_x * hw * hw / (Real(2) * nu)
        var worst = Real(0)
        for y in range(1, n - 1):
            var yy = Real(y) - Real(n - 1) * 0.5
            var ua = ch.force_x * (hw * hw - yy * yy) / (Real(2) * nu)
            var e = abs(ch.velocity(ch.idx(2, y, 2))[0] - ua)
            if e > worst:
                worst = e
        errs.append(worst / umax)
        print("  Poiseuille ny =", n, " relative error", worst / umax)
    s.check(
        Float64(errs[0]) < 0.05 and Float64(errs[1]) < 0.01,
        "the analytic parabola is reproduced at both resolutions",
    )
    s.check(
        Float64(errs[1]) < Float64(errs[0]),
        "and more accurately on the finer grid",
    )

    # ---- 4. Stokes limit ----
    # As Re -> 0 the sphere drag coefficient approaches 24/Re exactly. Run it
    # slow and viscous enough that the inertial correction is small.
    var r = Real(4.0)
    var u = Real(0.004)
    var nu4 = Real(0.16)
    var t = Lbm(64, 32, 32, nu4, BC_TUNNEL)
    t.init_uniform(1.0, u, 0, 0)
    t.inlet_u = u
    t.set_solid_sphere(20, 15.5, 15.5, r)
    var acc = Real(0)
    var m = 0
    for kk in range(1200):
        t.step()
        if kk >= 900:
            acc += t.fx
            m += 1
    var re = u * 2 * r / nu4
    var cd = (acc / Real(m)) / (Real(0.5) * u * u * Real(pi) * r * r)
    var stokes = 24 / re
    print("  Stokes limit — Re", re, " Cd", cd, " 24/Re", stokes,
          " ratio", cd / stokes)
    s.check(
        Float64(cd / stokes) > 0.7 and Float64(cd / stokes) < 2.0,
        "at Re < 1 the drag coefficient is within a factor of the Stokes law"
        " 24/Re -- the limit every sphere correlation reduces to",
    )
    s.check(Float64(re) < 1.0, "and the case really is in the Stokes regime")

    s.finish()
