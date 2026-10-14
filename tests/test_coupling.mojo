# tier: system
"""Continuum <-> rigid coupling ports (ROADMAP 17.55, `physics.coupling`,
`Runtime.advance_coupled`).

  1. Ordinary: a 3 mm sphere (density 1500) sinking in an LBM lattice for
     150 steps: `couple_step` with `LbmSpherePort` over an `LbmContinuum`
     gives the same sphere state bit for bit as `LbmCoupler.step`.
  2. Integration: the same scene driven by `Runtime.advance_coupled`
     matches `couple_step` bit for bit (the runtime's tick is the rigid
     step of the same order); `OneWay` steps a second lattice beside the
     scene and leaves the bodies as `advance` does.
  3. Extreme: a NaN written into a lattice cell between frames is isolated
     by the checked step (CONTINUUM_NAN counted in the scene's counters),
     the lattice and the sphere stay finite.
"""

from std.math import pi, isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3
from ecs.sparse_backend import SparseSetBackend
from ecs.transform import Transform
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.fsi import LbmCoupler, LbmSpherePort
from physics.continuum import LbmContinuum
from physics.coupling import couple_step, OneWay
from diag.counters import Counters, CONTINUUM_NAN
from fluid.lbm import Lbm
from gameplay.runtime import Runtime, RigidBodyRef

comptime DX: Real = 1e-3
comptime DT: Real = 1e-3
comptime RHO: Real = 1000
comptime N = 16
comptime R: Real = 3e-3
comptime G = Vec3(-9.8, 0, 0, 0)
comptime Rt = Runtime[SparseSetBackend[Transform, RigidBodyRef], QuatBody6]


def _body() -> QuatBody6:
    var vol = Real(4.0 / 3.0 * pi) * R * R * R
    return QuatBody6.at_rest(Vec3(10.5e-3, 7.5e-3, 7.5e-3, 0), Inertia3.sphere(1.5 * RHO * vol, R))


def _lbm() -> Lbm:
    var l = Lbm(N, N, N, 0.16)
    l.init_uniform(1, 0, 0, 0)
    return l^


def _cfg() -> SolverConfig:
    var c = SolverConfig()
    c.substeps = 1
    c.iters = 4
    return c


def _same(a: QuatBody6, b: QuatBody6) -> Bool:
    return a.pos == b.pos and a.vel == b.vel and a.omega == b.omega and a.q.w == b.q.w and a.q.x == b.q.x


def main() raises:
    var s = Suite("coupling")
    var cfg = _cfg()

    # ---- port vs LbmCoupler -------------------------------------------------------------------------
    var sa = ContactScene6[QuatBody6]()
    _ = sa.add_sphere(_body(), R, False)
    var cp = LbmCoupler(_lbm(), DX, DT, RHO, Vec3(0, 0, 0, 0))
    _ = cp.add_sphere(sa, sa.bset.id_of(0), R)
    var sb = ContactScene6[QuatBody6]()
    _ = sb.add_sphere(_body(), R, False)
    var cont = LbmContinuum(_lbm(), DT)
    var port = LbmSpherePort(DX, RHO, Vec3(0, 0, 0, 0))
    _ = port.add_sphere(sb, cont, sb.bset.id_of(0), R)
    var counters = Counters()
    var same = True
    for _ in range(150):
        cp.step(sa, G, cfg)
        _ = couple_step(sb, port, cont, DT, G, cfg, counters)
        if not _same(sa.bset.bodies[0], sb.bset.bodies[0]):
            same = False
    print("  150 coupled steps: sphere x LbmCoupler", sa.bset.bodies[0].pos[0], " port", sb.bset.bodies[0].pos[0], " vx", sb.bset.bodies[0].vel[0])
    s.check(same and sb.bset.bodies[0].pos[0] < 10.5e-3, "LbmSpherePort + couple_step == LbmCoupler.step, bit for bit (the sphere sinks)")

    # ---- through the runtime ------------------------------------------------------------------------
    var rt = Rt(DT, G)
    rt.cfg = _cfg()
    var e = rt.spawn_sphere(_body(), R, False)
    var rc = LbmContinuum(_lbm(), DT)
    var rp = LbmSpherePort(DX, RHO, Vec3(0, 0, 0, 0))
    _ = rp.add_sphere(rt.scene, rc, rt.body_of(e), R)
    var sc2 = ContactScene6[QuatBody6]()
    _ = sc2.add_sphere(_body(), R, False)
    var c2 = LbmContinuum(_lbm(), DT)
    var p2 = LbmSpherePort(DX, RHO, Vec3(0, 0, 0, 0))
    _ = p2.add_sphere(sc2, c2, sc2.bset.id_of(0), R)
    var rsame = True
    for _ in range(60):
        _ = rt.advance_coupled(Float64(DT), rp, rc)
        _ = couple_step(sc2, p2, c2, DT, G, cfg, counters)
        if not _same(rt.scene.bset.bodies[0], sc2.bset.bodies[0]):
            rsame = False
    s.check(rsame, "Runtime.advance_coupled == couple_step, bit for bit (60 ticks)")

    var ro = Rt(DT, G)
    ro.cfg = _cfg()
    _ = ro.spawn_sphere(_body(), R, False)
    var plain = Rt(DT, G)
    plain.cfg = _cfg()
    _ = plain.spawn_sphere(_body(), R, False)
    var side = LbmContinuum(_lbm(), DT)
    var one = OneWay[LbmContinuum]()
    for k in range(30):
        if k == 10:
            side.lbm.set_at(3, 100, Real(0) / Real(0))  # NaN in one cell, between frames
        _ = ro.advance_coupled(Float64(DT), one, side)
        _ = plain.advance(Float64(DT))
    var lat_ok = side.health().nonfinite == 0
    print("  OneWay: lattice steps", side.steps_run, " CONTINUUM_NAN", ro.scene.counters.get(CONTINUUM_NAN), " lattice finite", lat_ok)
    s.check(_same(ro.scene.bset.bodies[0], plain.scene.bset.bodies[0]) and side.steps_run == 30, "OneWay: the lattice steps beside, bodies move as with advance")
    s.check(ro.scene.counters.get(CONTINUUM_NAN) >= 1 and lat_ok and isfinite(ro.scene.bset.bodies[0].pos[0]), "a NaN cell is isolated and counted; lattice and bodies stay finite")
    s.finish()
