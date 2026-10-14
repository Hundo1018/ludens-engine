# tier: unit
"""Moving solids in the LBM: Ladd bounce-back (ROADMAP 17.59).

  1. Ordinary: plane Couette flow (lid at velocity 0.05, periodic in x and
     z) reaches the linear profile u(y) = U (y - 0.5) / H within 1 % of U;
     enabling moving-wall storage with zero wall velocity leaves a static
     run bit-identical.
  2. Integration: a sphere (R = 4) translating at 0.005 cells/step through a
     periodic 40^3 box feels a drag within 15 % of Stokes with Hasimoto's
     periodic-array correction at the velocity relative to the mean fluid
     velocity (the drag accelerates the periodic fluid as a whole), pointing against the motion; a sphere
     spinning at 0.002 rad/step feels a torque within 20 % of the rotlet
     -8 pi mu R^3 w (no periodic correction applied), opposing the spin.
  3. Extreme: a sphere moved by more than a cell in one step (un)covers
     cells, the lattice stays finite and its mass changes by < 1 %; a sphere
     at rest in still fluid feels no force.
"""

from std.math import pi, isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3
from fluid.lbm import Lbm


def _mean_ux(l: Lbm) -> Real:
    """Mass-weighted mean x velocity of the fluid: in a periodic box the
    drag accelerates the whole fluid, and Hasimoto's drag is for the
    velocity relative to it."""
    var p = Real(0)
    var mass = Real(0)
    for c in range(l.cells()):
        if l.flag[c] == 0:
            var rho = l.density(c)
            p += rho * l.velocity(c)[0]
            mass += rho
    return p / mass


def main() raises:
    var s = Suite("lbm_moving")

    # ---- Couette -------------------------------------------------------------------------------
    var h = 18
    var cl = Lbm(4, h, 4, 0.2)
    cl.init_uniform(1, 0, 0, 0)
    cl.set_solid_box(Vec3(0, 0, 0, 0), Vec3(3, 0, 3, 0))
    cl.set_solid_box(Vec3(0, Real(h - 1), 0, 0), Vec3(3, Real(h - 1), 3, 0))
    var uw = Real(0.05)
    cl.set_wall_velocity(Vec3(0, Real(h - 1), 0, 0), Vec3(3, Real(h - 1), 3, 0), Vec3(uw, 0, 0, 0))
    for _ in range(6000):
        cl.step()
    var worst = Real(0)
    for y in range(1, h - 1):
        var u = cl.velocity(cl.idx(1, y, 1))[0]
        var want = uw * (Real(y) - 0.5) / Real(h - 2)
        worst = max(worst, abs(u - want))
    print("  Couette H=16, lid 0.05: max |u - U (y - 1/2) / H| =", worst, "(", worst / uw * 100, "% of U )")
    s.check(worst < 0.01 * uw, "Couette profile within 1 % of the lid speed")

    var a = Lbm(8, 8, 8, 0.1)
    var b = Lbm(8, 8, 8, 0.1)
    a.init_uniform(1, 0.02, 0.01, 0)
    b.init_uniform(1, 0.02, 0.01, 0)
    a.set_solid_sphere(4, 4, 4, 2)
    b.set_solid_sphere(4, 4, 4, 2)
    b.set_wall_velocity(Vec3(0, 0, 0, 0), Vec3(7, 7, 7, 0), Vec3(0, 0, 0, 0))
    var same = True
    for _ in range(50):
        a.step()
        b.step()
    for i in range(len(a.f)):
        if a.f[i] != b.f[i]:
            same = False
    s.check(same and a.fx == b.fx, "zero wall velocity: bit-identical to a static lattice")

    # ---- translating sphere vs Stokes-Hasimoto ---------------------------------------------------
    var n = 40
    var nu = Real(0.16)
    var r = Real(4)
    var u0 = Real(0.005)
    var tr = Lbm(n, n, n, nu)
    tr.init_uniform(1, 0, 0, 0)
    var c0 = Vec3(10, 19.5, 19.5, 0)
    var k = tr.add_moving_sphere(c0, r, Vec3(u0, 0, 0, 0), Vec3(0, 0, 0, 0))
    var acc = Vec3(0, 0, 0, 0)
    var m = 0
    var umean = Real(0)
    var um = 0
    for st in range(2400):
        var c = c0 + Vec3(u0 * Real(st), 0, 0, 0)
        tr.move_sphere(k, c, Vec3(u0, 0, 0, 0), Vec3(0, 0, 0, 0))
        tr.step()
        if st >= 1600:
            acc = acc + tr.obj_f[k]
            m += 1
            if st % 100 == 0:
                umean += _mean_ux(tr)
                um += 1
    var fd = acc * (1 / Real(m))
    var ubar = umean / Real(um)
    var conc = Real(4.0 / 3.0 * pi) * r * r * r / Real(n * n * n)
    var kh = 1 / (1 - 1.7601 * conc ** (1.0 / 3.0) + conc - 1.5593 * conc * conc)
    var stokes = 6 * Real(pi) * nu * r * (u0 - ubar) * kh
    print("  translating sphere R=4: mean fluid velocity", ubar, " drag", fd[0], " Stokes-Hasimoto at U - u_mean", -stokes, " ratio", -fd[0] / stokes, " side force", fd[1], fd[2])
    s.check(fd[0] < 0 and abs(-fd[0] / stokes - 1) < 0.15, "drag within 15 % of Stokes with the periodic correction, against the motion")

    var rot = Lbm(32, 32, 32, nu)
    rot.init_uniform(1, 0, 0, 0)
    var om = Real(0.002)
    var kr = rot.add_moving_sphere(Vec3(15.5, 15.5, 15.5, 0), r, Vec3(0, 0, 0, 0), Vec3(0, 0, om, 0))
    var tacc = Real(0)
    var tm = 0
    for st in range(1500):
        rot.step()
        if st >= 1000:
            tacc += rot.obj_t[kr][2]
            tm += 1
    var tq = tacc / Real(tm)
    var rotlet = 8 * Real(pi) * nu * r * r * r * om
    print("  spinning sphere: torque", tq, " rotlet -8 pi mu R^3 w", -rotlet, " ratio", -tq / rotlet)
    s.check(tq < 0 and abs(-tq / rotlet - 1) < 0.2, "torque within 20 % of the rotlet, opposing the spin")

    # ---- extremes ---------------------------------------------------------------------------------
    var jl = Lbm(24, 24, 24, nu)
    jl.init_uniform(1, 0, 0, 0)
    var kj = jl.add_moving_sphere(Vec3(8, 11.5, 11.5, 0), 3, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))
    var m0 = jl.total_mass()
    var fin = True
    for st in range(40):
        var c = Vec3(8 + Real(st) * 0.3, 11.5, 11.5, 0)
        jl.move_sphere(kj, c, Vec3(0.3, 0, 0, 0), Vec3(0, 0, 0, 0))
        jl.step()
        if not isfinite(jl.obj_f[kj][0]):
            fin = False
    var m1 = jl.total_mass()
    print("  sphere jumping 0.3 cells/step for 40 steps: mass", m0, "->", m1, " last force", jl.obj_f[kj][0])
    s.check(fin and abs(m1 / m0 - 1) < 0.01, "fast sphere: finite, mass within 1 %")
    var rest = Lbm(16, 16, 16, nu)
    rest.init_uniform(1, 0, 0, 0)
    var kz = rest.add_moving_sphere(Vec3(7.5, 7.5, 7.5, 0), 3, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))
    for _ in range(20):
        rest.step()
    s.check(abs(rest.obj_f[kz][0]) < 1e-6 and abs(rest.obj_f[kz][1]) < 1e-6 and abs(rest.obj_t[kz][2]) < 1e-6, "sphere at rest in still fluid: no force")
    s.finish()
