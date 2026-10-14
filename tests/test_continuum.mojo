# tier: integration
"""The continuum stepping contract (ROADMAP 17.55).

FEM, MPM, PBF and an LBM adapter are driven by one generic function written
against `physics.continuum.ContinuumSolver` only.

  1. Ordinary: each solver (and a 20-segment rope and a soft lattice, 17.55) runs 40 steps through `step_checked`, writes its
     state, a fresh copy reads it back, and both run 40 more steps -- their
     written states are byte-identical (snapshot participation).
  2. Integration: an injected NaN (FEM node, MPM / PBF particle, LBM
     population) is counted in `CONTINUUM_NAN`, quarantined before it
     spreads, and the run stays finite for 60 more steps (control: without
     the pre-step check one NaN MPM particle poisons all 64 in one step); an MPM particle placed outside the grid
     is counted in `CONTINUUM_ESCAPED` and removed instead of being frozen.
  3. Extreme: LBM unit conversion -- 60 advances of 1/60 s at 1 ms per
     lattice step run 1000 lattice steps (within one); a zero lattice step
     raises; reading a state into a differently sized solver raises.
"""

from std.math import isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3
from diag.counters import Counters, CONTINUUM_NAN, CONTINUUM_ESCAPED
from physics.serialize import BinWriter, BinReader
from physics.fem import FemBody, make_beam
from physics.mpm import MpmSolver
from physics.pbf import PbfFluid
from fluid.lbm import Lbm, BC_PERIODIC
from physics.rope import Rope
from physics.softbody import SoftBody
from physics.continuum import (
    ContinuumSolver, ContinuumHealth, step_checked,
    FemContinuum, MpmContinuum, PbfContinuum, LbmContinuum,
)

comptime G = Vec3(0, -9.8, 0, 0)


def _fem() -> FemContinuum:
    var b = FemBody(young=5000.0, poisson=0.3)
    make_beam(b, 3, 2, 2, 0.1, 0.05)
    return FemContinuum(b^, -0.05)


def _mpm() -> MpmContinuum:
    var m = MpmSolver(Vec3(0, 0, 0, 0), 0.05, 24, 20000.0, 0.2)
    for i in range(4):
        for j in range(4):
            for k in range(4):
                m.add(Vec3(0.5 + Real(i) * 0.03, 0.4 + Real(j) * 0.03, 0.5 + Real(k) * 0.03, 0), 0.03, 2.7e-5)
    return MpmContinuum(m^)


def _pbf() -> PbfContinuum:
    var f = PbfFluid(Vec3(0, 0, 0, 0), Vec3(0.5, 0.8, 0.5, 0))
    for i in range(5):
        for j in range(5):
            for k in range(5):
                f.add(Vec3(0.1 + Real(i) * 0.05, 0.1 + Real(j) * 0.05, 0.1 + Real(k) * 0.05, 0))
    return PbfContinuum(f^, 3)


def _lbm() raises -> LbmContinuum:
    var l = Lbm(6, 6, 6, Real(0.05), BC_PERIODIC)
    l.init_uniform(1.0, 0.03, 0, 0)
    return LbmContinuum(l^, 0.001)


def _rope() -> Rope:
    var r = Rope(Vec3(0, 2, 0, 0), Vec3(2, 2, 0, 0), 20, 0.5, 1e-5)
    r.pin(0, Vec3(0, 2, 0, 0))
    return r^


def _soft() raises -> SoftBody:
    return SoftBody.box_lattice(Vec3(0, 1, 0, 0), Vec3(0.2, 0.2, 0.2, 0), 3, 1.0, 1e-4)


def _bytes[S: ContinuumSolver](s: S) -> List[UInt8]:
    var w = BinWriter()
    s.write_state(w)
    return w.b.copy()


def _run[S: ContinuumSolver](mut s: S, steps: Int, dt: Real, mut c: Counters) -> Bool:
    """The generic driver: every solver goes through this. False if any
    step left a non-finite item after quarantine."""
    var ok = True
    for _ in range(steps):
        _ = step_checked(s, dt, G, c)
        if s.health().nonfinite > 0:
            ok = False
    return ok


def _roundtrip[S: ContinuumSolver](mut a: S, mut b: S, dt: Real) raises -> Bool:
    var c = Counters()
    _ = _run(a, 40, dt, c)
    var r = BinReader(_bytes(a))
    b.read_state(r)
    _ = _run(a, 40, dt, c)
    _ = _run(b, 40, dt, c)
    return _bytes(a) == _bytes(b)


def main() raises:
    var s = Suite("continuum")
    var zero = Real(0)
    var nan = zero / zero

    # ---- snapshot round trips ------------------------------------------------
    var fa = _fem()
    var fb = _fem()
    s.check(_roundtrip(fa, fb, 1e-3), "FEM: state written, read into a fresh body, 40 more steps: byte-identical")
    var ma = _mpm()
    var mb = _mpm()
    s.check(_roundtrip(ma, mb, 5e-4), "MPM: round trip, byte-identical after 40 more steps")
    var pa = _pbf()
    var pb = _pbf()
    s.check(_roundtrip(pa, pb, 1.0 / 120.0), "PBF: round trip, byte-identical after 40 more steps")
    var la = _lbm()
    var lb = _lbm()
    s.check(_roundtrip(la, lb, 0.004), "LBM adapter: round trip, byte-identical after 40 more advances")
    var ra = _rope()
    var rb = _rope()
    s.check(_roundtrip(ra, rb, 1.0 / 60.0), "rope: round trip, byte-identical after 40 more steps")
    var sa = _soft()
    var sb2 = _soft()
    s.check(_roundtrip(sa, sb2, 1.0 / 60.0), "soft body: round trip, byte-identical after 40 more steps")
    var sq = _soft()
    var cs = Counters()
    sq.pts[4].v = Vec3(nan, 0, 0, 0)
    var hs = step_checked(sq, 1.0 / 60.0, G, cs)
    var soft_ok = _run(sq, 60, 1.0 / 60.0, cs)
    print("  soft body: NaN particle -> nonfinite", hs.nonfinite, " CONTINUUM_NAN", cs.get(CONTINUUM_NAN), " particle 0 y after 1 s free fall", sq.pts[0].x[1])
    s.check(hs.nonfinite >= 1 and cs.get(CONTINUUM_NAN) >= 1 and soft_ok and sq.pts[4].w == 0, "soft body: NaN particle counted and pinned; the lattice keeps falling, finite")
    var rq = _rope()
    var cr = Counters()
    rq.x[7] = Vec3(nan, 0, 0, 0)
    var hr = step_checked(rq, 1.0 / 60.0, G, cr)
    var rope_ok = _run(rq, 60, 1.0 / 60.0, cr)
    print("  rope: NaN particle -> nonfinite", hr.nonfinite, " CONTINUUM_NAN", cr.get(CONTINUUM_NAN), " pinned at", rq.x[7], " free end y", rq.x[20][1])
    s.check(hr.nonfinite >= 1 and cr.get(CONTINUUM_NAN) >= 1 and rope_ok and rq.w[7] == 0 and rq.x[20][1] < 2, "rope: NaN particle counted, pinned at a neighbour; the rest keeps swinging, finite")

    # ---- failure policy -------------------------------------------------------------
    var c = Counters()
    var f = _fem()
    f.body.x[3] = nan
    var h = step_checked(f, 1e-3, G, c)
    var fem_ok = _run(f, 60, 1e-3, c)
    print("  FEM: NaN node -> nonfinite", h.nonfinite, " CONTINUUM_NAN", c.get(CONTINUUM_NAN), " pinned inv_m", f.body.inv_m[3])
    s.check(h.nonfinite >= 1 and c.get(CONTINUUM_NAN) >= 1 and fem_ok and f.body.inv_m[3] == 0, "FEM: NaN node counted, pinned, run stays finite")

    var cm = Counters()
    var m = _mpm()
    var n0 = len(m.mpm.p)
    m.mpm.p[5].v = Vec3(nan, 0, 0, 0)
    m.mpm.add(Vec3(-1, -1, -1, 0), 0.03, 2.7e-5)  # outside the grid
    var hm = step_checked(m, 5e-4, G, cm)
    var mpm_ok = _run(m, 60, 5e-4, cm)
    print("  MPM: nonfinite", hm.nonfinite, " escaped", hm.escaped, " particles", n0 + 1, "->", len(m.mpm.p))
    s.check(cm.get(CONTINUUM_NAN) >= 1 and cm.get(CONTINUUM_ESCAPED) >= 1 and mpm_ok and len(m.mpm.p) == n0 - 1, "MPM: NaN and out-of-grid particles counted and removed, run finite")

    # control: the same NaN without the pre-step check poisons every particle
    var m2 = _mpm()
    m2.mpm.p[5].v = Vec3(nan, 0, 0, 0)
    m2.advance(5e-4, G)
    print("  MPM control: one NaN particle, plain advance -> nonfinite", m2.health().nonfinite, "of", len(m2.mpm.p))
    s.check(m2.health().nonfinite == len(m2.mpm.p), "control: one NaN particle reaches the grid and poisons all of them in one plain step")

    var cp = Counters()
    var p = _pbf()
    var np0 = len(p.pbf.x)
    p.pbf.vy[7] = nan
    _ = step_checked(p, 1.0 / 120.0, G, cp)
    var pbf_ok = _run(p, 60, 1.0 / 120.0, cp)
    s.check(cp.get(CONTINUUM_NAN) >= 1 and pbf_ok and len(p.pbf.x) < np0, "PBF: NaN particle counted and removed, run finite")

    var cl = Counters()
    var l = _lbm()
    l.lbm.set_at(2, 10, nan)
    var lbm_ok = _run(l, 20, 0.004, cl)
    s.check(cl.get(CONTINUUM_NAN) >= 1 and lbm_ok, "LBM: NaN population counted, cell reset, run finite")

    # ---- extremes ---------------------------------------------------------------------
    var u = _lbm()
    var cu = Counters()
    for _ in range(60):
        _ = step_checked(u, 1.0 / 60.0, G, cu)
    print("  LBM: 60 x 1/60 s at 1 ms per lattice step ->", u.steps_run, "lattice steps")
    s.check(abs(u.steps_run - 1000) <= 1, "LBM: seconds -> lattice steps at the boundary (1000 +- 1)")
    var raised = 0
    try:
        _ = LbmContinuum(Lbm(4, 4, 4, Real(0.05), BC_PERIODIC), 0)
    except:
        raised += 1
    var big = FemBody(young=5000.0, poisson=0.3)
    make_beam(big, 4, 2, 2, 0.1, 0.05)
    var fbig = FemContinuum(big^)
    var rr = BinReader(_bytes(_fem()))
    try:
        fbig.read_state(rr)
    except:
        raised += 1
    s.check(raised == 2, "zero lattice step and a mismatched state raise")
    s.finish()
