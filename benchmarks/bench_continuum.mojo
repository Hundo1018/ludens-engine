"""ROADMAP 17.55: cost of the continuum failure policy.

Each solver is stepped 100 times through a plain `advance` and through
`step_checked` (a health scan and quarantine check before and after the
step); the difference is the policy's cost. Microseconds per step.
"""

from std.time import perf_counter_ns
from geometry.vec import Real, Vec3
from diag.counters import Counters
from physics.fem import FemBody, make_beam
from physics.mpm import MpmSolver
from physics.pbf import PbfFluid
from fluid.lbm import Lbm, BC_PERIODIC
from physics.continuum import ContinuumSolver, step_checked, FemContinuum, MpmContinuum, PbfContinuum, LbmContinuum

comptime G = Vec3(0, -9.8, 0, 0)


def _time[S: ContinuumSolver](mut a: S, mut b: S, dt: Real, name: String, items: Int):
    var c = Counters()
    var t0 = Int(perf_counter_ns())
    for _ in range(100):
        a.advance(dt, G)
    var t1 = Int(perf_counter_ns())
    for _ in range(100):
        _ = step_checked(b, dt, G, c)
    var t2 = Int(perf_counter_ns())
    var plain = (t1 - t0) // 100000
    var checked = (t2 - t1) // 100000
    print("|", name, "|", items, "|", plain, "|", checked, "|")


def main() raises:
    print("### Continuum stepping contract (17.55): failure-policy cost\n")
    print("| solver | items | advance us | step_checked us |")
    print("|---|---:|---:|---:|")
    var fa = FemBody(young=5000.0, poisson=0.3)
    make_beam(fa, 10, 4, 4, 0.1, 0.05)
    var fb = FemBody(young=5000.0, poisson=0.3)
    make_beam(fb, 10, 4, 4, 0.1, 0.05)
    var n_fem = len(fa.x)
    var f1 = FemContinuum(fa^, -0.05)
    var f2 = FemContinuum(fb^, -0.05)
    _time(f1, f2, 1e-3, "FEM beam (nodes)", n_fem)
    var ma = MpmSolver(Vec3(0, 0, 0, 0), 0.05, 32, 20000.0, 0.2)
    var mb = MpmSolver(Vec3(0, 0, 0, 0), 0.05, 32, 20000.0, 0.2)
    for i in range(10):
        for j in range(10):
            for k in range(10):
                var p = Vec3(0.5 + Real(i) * 0.025, 0.4 + Real(j) * 0.025, 0.5 + Real(k) * 0.025, 0)
                ma.add(p, 0.015, 1.6e-5)
                mb.add(p, 0.015, 1.6e-5)
    var m1 = MpmContinuum(ma^)
    var m2 = MpmContinuum(mb^)
    _time(m1, m2, 5e-4, "MPM (particles)", 1000)
    var pa = PbfFluid(Vec3(0, 0, 0, 0), Vec3(0.6, 1.0, 0.6, 0))
    var pb = PbfFluid(Vec3(0, 0, 0, 0), Vec3(0.6, 1.0, 0.6, 0))
    for i in range(10):
        for j in range(10):
            for k in range(10):
                var q = Vec3(0.05 + Real(i) * 0.05, 0.05 + Real(j) * 0.05, 0.05 + Real(k) * 0.05, 0)
                pa.add(q)
                pb.add(q)
    var p1 = PbfContinuum(pa^, 3)
    var p2 = PbfContinuum(pb^, 3)
    _time(p1, p2, 1.0 / 120.0, "PBF (particles)", 1000)
    var la = Lbm(16, 16, 16, Real(0.05), BC_PERIODIC)
    la.init_uniform(1.0, 0.03, 0, 0)
    var lb = Lbm(16, 16, 16, Real(0.05), BC_PERIODIC)
    lb.init_uniform(1.0, 0.03, 0, 0)
    var l1 = LbmContinuum(la^, 0.001)
    var l2 = LbmContinuum(lb^, 0.001)
    _time(l1, l2, 0.001, "LBM 16^3 (cells), one lattice step per advance", 4096)
    print("")
