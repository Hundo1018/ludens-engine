# tier: integration
"""SPH <-> rigid body two-way coupling (ROADMAP 17.59, `physics.sph_rigid`).

Units as test_sph_boundary: spacing 5 cm, kernel 10 cm, dt 1/2000 s; water
density 1000, so a fluid particle stands for 1000 / rho0 kg. This SPH is
soft (stiffness 8): the settled tank is about 1500 kg/m^3 on average and
denser at the floor, so Archimedes is checked against the measured density
profile, not against 1000.

  1. Ordinary: with no coupled body `sph_rigid_step` moves the fluid
     exactly as `sph_step_boundary`. A static 10 cm box held under the
     surface feels an upward force within 5 % of the weight of the fluid
     it displaces (density profile measured before it was put in; 0.98).
     Before the body force was a surface integral of the Adami-
     extrapolated wall pressure, Akinci's pairwise term gave 2.3x: with a
     10 cm kernel on a 10 cm box its one-sided pressure term also pushes
     vertical faces up (measured +9.4 N per side face).
  2. Integration: a 15 cm box of density 500 dropped into the tank floats
     after 2 s: speed < 1 cm/s, fluid force within 3 % of its weight, top
     above the surface. A box of density 3000 rides more than 8 cm deeper
     (11 cm measured) and is still sinking (fluid squeezed under it carries
     part of its weight and leaves slowly: 2.8 cm/s at 2 s, 7.5 mm/s at
     4 s). No fluid particle ends
     inside either box (push-out, momentum handed to the body).
  3. Extreme: non-positive density / rho0 / spacing / extents raise.
"""


from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from physics.pbf import PbfFluid
from physics.sph import sph_step_boundary, box_floor_boundary, BoundaryParticles
from physics.sph_rigid import SphRigidCoupler, sph_rigid_step
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig

comptime SP: Real = 0.05
comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 2000.0
comptime HALF: Real = 0.075


def _tank() -> PbfFluid:
    var f = PbfFluid(Vec3(0, 0, 0, 0), Vec3(0.6, 1.0, 0.6, 0))
    f.calibrate(SP)
    for i in range(12):
        for j in range(8):
            for k in range(12):
                f.add(Vec3(0.025 + Real(i) * SP, 0.025 + Real(j) * SP, 0.025 + Real(k) * SP, 0))
    return f^


def _surface(f: PbfFluid) -> Real:
    """Mean height of the top 10 % of particles."""
    var ys = List[Real]()
    for i in range(f.count()):
        ys.append(f.y[i])
    sort(ys)
    var acc = Real(0)
    var m = len(ys) // 10
    for k in range(len(ys) - m, len(ys)):
        acc += ys[k]
    return acc / Real(m)


def _cfg() -> SolverConfig:
    var c = SolverConfig()
    c.substeps = 1
    return c^


def _clone(f: PbfFluid) -> PbfFluid:
    var g = PbfFluid(f.lo, f.hi)
    g.rho0 = f.rho0
    for i in range(f.count()):
        g.add(Vec3(f.x[i], f.y[i], f.z[i], 0))
        g.vx[i] = f.vx[i]
        g.vy[i] = f.vy[i]
        g.vz[i] = f.vz[i]
    return g^


def _inside(f: PbfFluid, c: Vec3, sc: ContactScene6[QuatBody6], i_body: Int, half: Real) -> Int:
    var n = 0
    for i in range(f.count()):
        var lp = sc.bset.bodies[i_body].to_local(Vec3(f.x[i], f.y[i], f.z[i], 0))
        if abs(lp[0]) < half - SP * 0.5 and abs(lp[1]) < half - SP * 0.5 and abs(lp[2]) < half - SP * 0.5:
            n += 1
    _ = c
    return n


struct Drop(Movable):
    var y: Real
    var v: Real
    var force: Real
    var weight: Real
    var inside: Int

    def __init__(out self, settled: PbfFluid, density: Real, surf: Real, steps: Int) raises:
        var f = _clone(settled)
        var floor = box_floor_boundary(f.lo, f.hi, SP, f.rho0)
        var sc = ContactScene6[QuatBody6]()
        _ = sc.add(QuatBody6.at_rest(Vec3(0.3, -0.05, 0.3, 0), Inertia3.box(1, 1, 0.05, 1)), Vec3(1, 0.05, 1, 0), True)
        var cp = SphRigidCoupler(1000, f.rho0)
        var cfg = _cfg()
        var m = density * (2 * HALF) * (2 * HALF) * (2 * HALF)
        self.weight = m * 9.8
        var id = sc.add(QuatBody6.at_rest(Vec3(0.3, surf + HALF + 0.05, 0.3, 0), Inertia3.box(m, HALF, HALF, HALF)), Vec3(HALF, HALF, HALF, 0), False)
        sc.set_sleep_thresholds(id, 0, 0)
        _ = cp.add_box(id, Vec3(HALF, HALF, HALF, 0), SP * 0.5, f.rho0)
        for _ in range(steps):
            sph_rigid_step(f, floor, cp, sc, DT, G, cfg)
        self.y = sc.pose(id).pos[1]
        self.v = sc.velocity(id)[1]
        self.force = cp.force[0][1]
        self.inside = _inside(f, sc.pose(id).pos, sc, id.index(), HALF)


def main() raises:
    var s = Suite("sph_rigid")
    var cfg = _cfg()

    var a = _tank()
    var b = _tank()
    var floor = box_floor_boundary(a.lo, a.hi, SP, a.rho0)
    var sc = ContactScene6[QuatBody6]()
    var cp = SphRigidCoupler(1000, a.rho0)
    var same = True
    for _ in range(100):
        sph_step_boundary(a, floor, DT, G)
        sph_rigid_step(b, floor, cp, sc, DT, G, cfg)
    for i in range(a.count()):
        same = same and a.x[i] == b.x[i] and a.y[i] == b.y[i] and a.z[i] == b.z[i]
    s.check(same, "no coupled body: sph_step_boundary, bit for bit")

    # settle once (b has run 100 steps already), measure the density profile
    var prof = List[Real](length=20, fill=0)
    for k in range(900):
        sph_rigid_step(b, floor, cp, sc, DT, G, cfg)
        if k >= 400:
            for i in range(b.count()):
                var bin = Int(b.y[i] / 0.025)
                if bin < 20:
                    prof[bin] += 1
    var surf = _surface(b)

    var hb = Real(0.05)
    var yc = Real(0.14)
    var mass_disp = Real(0)
    for bin in range(20):
        var y0 = Real(bin) * 0.025
        var lo = max(y0, yc - hb)
        var hi = min(y0 + 0.025, yc + hb)
        if hi > lo:
            mass_disp += prof[bin] / 500 / (0.36 * 0.025) * cp.particle_mass * (hi - lo) * (2 * hb) * (2 * hb)
    var st = _clone(b)
    var ss = ContactScene6[QuatBody6]()
    var cs = SphRigidCoupler(1000, st.rho0)
    var sid = ss.add(QuatBody6.at_rest(Vec3(0.3, yc, 0.3, 0), Inertia3.box(1, hb, hb, hb)), Vec3(hb, hb, hb, 0), True)
    _ = cs.add_box(sid, Vec3(hb, hb, hb, 0), SP * 0.5, st.rho0)
    var acc = Real(0)
    for k in range(2000):
        sph_rigid_step(st, floor, cs, ss, DT, G, cfg)
        if k >= 1000:
            acc += cs.force[0][1]
    var buoy = acc / 1000
    print("  static 10 cm box under the surface: mean fluid force", buoy, " displaced weight", mass_disp * 9.8, " ratio", buoy / (mass_disp * 9.8), " (1000 g V =", 1000 * 9.8 * (2 * hb) ** 3, ")")
    s.check(abs(buoy / (mass_disp * 9.8) - 1) < 0.05, "buoyancy = weight of the displaced fluid (5 %)")

    var light = Drop(b, 500, surf, 4000)
    var heavy = Drop(b, 3000, surf, 4000)
    print("  box density 500 after 2 s: top", light.y + HALF, " surface", surf, " vy", light.v, " fluid force", light.force, " weight", light.weight, " fluid inside", light.inside)
    print("  box density 3000 after 2 s: top", heavy.y + HALF, " bottom", heavy.y - HALF, " vy", heavy.v, " fluid force", heavy.force, " weight", heavy.weight, " fluid inside", heavy.inside)
    s.check(abs(light.v) < 0.01 and abs(light.force / light.weight - 1) < 0.03 and light.y + HALF > surf, "a light box floats: still, force = weight, top above the surface")
    s.check(heavy.y < light.y - 0.08 and heavy.v < 0, "a heavy box rides more than 8 cm deeper and keeps sinking")
    s.check(light.inside == 0 and heavy.inside == 0, "no fluid particle inside a coupled box")

    var raised = 0
    try:
        _ = SphRigidCoupler(0, 1)
    except:
        raised += 1
    var c2 = SphRigidCoupler(1000, a.rho0)
    var sc2 = ContactScene6[QuatBody6]()
    var id2 = sc2.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
    try:
        _ = c2.add_box(id2, Vec3(0.1, 0.1, 0.1, 0), 0, a.rho0)
    except:
        raised += 1
    try:
        _ = c2.add_sphere(id2, -1, 0.05, a.rho0)
    except:
        raised += 1
    s.check(raised == 3, "bad density, spacing or radius raise")
    s.finish()
