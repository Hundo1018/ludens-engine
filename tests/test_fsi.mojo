# tier: integration
"""LBM <-> rigid body coupling through `ContactScene6` (ROADMAP 17.59).

Units: dx = 1 mm, dt = 1 ms, water-like rho = 1000 kg/m^3, lattice
viscosity 0.16 (1.6e-4 m^2/s). Gravity along -x so the periodic lattice's
uniform body force (`force_x`) can carry the mean pressure gradient that
holds the fluid up (Hasimoto's setting); without it the sinking sphere
would drag the whole periodic fluid down.

  1. Ordinary: a sphere (R = 3 mm, density 1500) settles to a terminal
     velocity, relative to the mean fluid velocity, within 15 % of
     (rho_s - rho_f) V g / (6 pi mu R K) with Hasimoto's K; its spin
     stays ~0 (no torque from symmetric flow).
  2. Integration: the coupled sphere still collides with a static plate in
     the scene (the plate is not in the lattice): it comes to rest on it.
  3. Extreme: density ratios 1.0 and 0.5 launched at 5 cm/s: at 1.0 the
     sphere stays finite and slows down; at 0.5 explicit partitioned
     coupling diverges (added mass). The fix is opt-in on the port,
     `LbmSpherePort.set_implicit` (test_fsi_added_mass); `LbmCoupler`
     stays explicit.
"""

from std.math import pi, isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from physics.rigid6 import QuatBody6, Inertia3
from physics.body_set import BodyId
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.fsi import LbmCoupler
from fluid.lbm import Lbm

comptime DX: Real = 1e-3
comptime DT: Real = 1e-3
comptime RHO: Real = 1000
comptime NU_LAT: Real = 0.16
comptime N = 24
comptime R: Real = 3e-3


def _mean_ux(l: Lbm) -> Real:
    var p = Real(0)
    var mass = Real(0)
    for c in range(l.cells()):
        if l.flag[c] == 0:
            var rho = l.density(c)
            p += rho * l.velocity(c)[0]
            mass += rho
    return p / mass


def _scene(ratio: Real, v0: Vec3, plate: Bool) -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var vol = Real(4.0 / 3.0 * pi) * R * R * R
    var b = QuatBody6.at_rest(Vec3(18.5e-3, 11.5e-3, 11.5e-3, 0), Inertia3.sphere(ratio * RHO * vol, R))
    b.vel = v0
    _ = sc.add_sphere(b^, R, False)
    if plate:
        _ = sc.add(QuatBody6.at_rest(Vec3(6e-3, 11.5e-3, 11.5e-3, 0), Inertia3.box(1, 1e-3, 10e-3, 10e-3)), Vec3(1e-3, 10e-3, 10e-3, 0), True)
    return sc^


def _coupler(mut sc: ContactScene6[QuatBody6], ratio: Real, g: Real) raises -> LbmCoupler:
    var lbm = Lbm(N, N, N, NU_LAT)
    lbm.init_uniform(1, 0, 0, 0)
    var cp = LbmCoupler(lbm^, DX, DT, RHO, Vec3(0, 0, 0, 0))
    _ = cp.add_sphere(sc, sc.bset.id_of(0), R)
    # Hasimoto: a uniform body force on the fluid carries the sphere's net
    # weight, so the periodic fluid as a whole does not accelerate
    var vol = Real(4.0 / 3.0 * pi) * R * R * R
    var w_net = (ratio - 1) * RHO * vol * g
    var f_lat = w_net * DT * DT / (RHO * DX * DX * DX * DX)
    cp.lbm.force_x = f_lat / Real(N * N * N - cp.lbm.solid_count())
    return cp^


def main() raises:
    var s = Suite("fsi")
    var cfg = SolverConfig()
    cfg.substeps = 1
    cfg.iters = 4

    # ---- terminal velocity --------------------------------------------------------------------
    var g = Real(0.68)
    var grav = Vec3(-g, 0, 0, 0)
    var sc = _scene(1.5, Vec3(0, 0, 0, 0), False)
    var cp = _coupler(sc, 1.5, g)
    var id = sc.bset.id_of(0)
    var vs = Real(0)
    var uf = Real(0)
    var k = 0
    var spin = Real(0)
    for st in range(1600):
        cp.step(sc, grav, cfg)
        if st >= 1200 and st % 50 == 0:
            vs += sc.velocity(id)[0]
            uf += _mean_ux(cp.lbm) * DX / DT
            k += 1
        spin = max(spin, length(sc.angular_velocity(id)))
    vs /= Real(k)
    uf /= Real(k)
    var vol = Real(4.0 / 3.0 * pi) * R * R * R
    var rl = R / DX
    var conc = Real(4.0 / 3.0 * pi) * rl * rl * rl / Real(N * N * N)
    var kh = 1 / (1 - 1.7601 * conc ** (1.0 / 3.0) + conc - 1.5593 * conc * conc)
    var mu = RHO * NU_LAT * DX * DX / DT
    var vt = (1.5 - 1) * RHO * vol * g / (6 * Real(pi) * mu * R * kh)
    print("  settling sphere: velocity", vs, " mean fluid", uf, " relative", vs - uf, " Stokes-Hasimoto", -vt, " ratio", (uf - vs) / vt, " max spin", spin)
    s.check(abs((uf - vs) / vt - 1) < 0.15, "terminal velocity within 15 % of Stokes-Hasimoto")
    s.check(spin < 0.5, "no spin from symmetric flow")

    # ---- collides with a scene body -----------------------------------------------------------
    var sp = _scene(1.5, Vec3(0, 0, 0, 0), True)
    var cpp = _coupler(sp, 1.5, 6.8)
    var idp = sp.bset.id_of(0)
    for _ in range(1200):
        cpp.step(sp, Vec3(-6.8, 0, 0, 0), cfg)
    var px = sp.pose(idp).pos[0]
    print("  sphere over a static plate (top at x = 7 mm): centre x", px * 1000, "mm  velocity", sp.velocity(idp)[0])
    s.check(abs(px - 10e-3) < 0.3e-3 and abs(sp.velocity(idp)[0]) < 1e-3, "the coupled sphere comes to rest on the plate")

    # ---- added mass: light bodies ---------------------------------------------------------------
    for ri in range(2):
        var ratio = Real(1.0) if ri == 0 else Real(0.5)
        var sl = _scene(ratio, Vec3(-0.05, 0, 0, 0), False)
        var cl = _coupler(sl, ratio, 0)
        var il = sl.bset.id_of(0)
        var fin = True
        var vmax = Real(0)
        for _ in range(300):
            cl.step(sl, Vec3(0, 0, 0, 0), cfg)
            var v = sl.velocity(il)
            if not isfinite(v[0]):
                fin = False
                break
            vmax = max(vmax, length(v))
        var v_end = sl.velocity(il)[0]
        print("  density ratio", ratio, ": launched at -0.05 m/s, after 0.3 s v =", v_end, " max |v|", vmax, " finite", fin)
        if ri == 0:
            s.check(fin and abs(v_end) < 0.05, "ratio 1.0: finite and slowing")
        else:
            s.check(vmax > 1, "ratio 0.5: explicit coupling diverges (added-mass instability, measured; needs the 17.59 strong-coupling iteration)")
    s.finish()
