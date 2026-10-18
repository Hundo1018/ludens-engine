# tier: integration
"""Projective dynamics for tetrahedral bodies (ROADMAP 17.58,
`physics.fem_pd`).

A 0.6 x 0.2 x 0.2 m beam (6 x 2 x 2 cells, 5 tets each, 0.05 kg per node,
E 2e4, Poisson 0) pinned at x = 0, under gravity, 10 s at 1/60 s.

  1. Parity: with Poisson 0 the as-rigid-as-possible energy is the
     co-rotational one, so PD at 20 iterations settles to the tip height
     `FemBody.step_implicit` settles to (within 0.5 %); 1 and 5 iterations
     are printed with their error and time per step, and the error falls
     with the iteration count.
  2. Integration: pinned nodes do not move; a free body turned by 90
     degrees and left at rest stays at rest (the energy ignores rotation):
     its drift, 1.4e-4 m/s after 1 s, is f32 rounding of the polar
     decomposition, printed beside the unrotated body's.
  3. Extreme: dt = 0.1 (6x the parity step) stays finite and bounded;
     dt = 0 and iters = 0 raise.
"""

from std.math import pi, isfinite
from std.time import perf_counter_ns
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.fem import FemBody, make_beam
from physics.fem_pd import FemPd

comptime G = Vec3(0, -9.8, 0, 0)


def beam(pin: Bool) -> FemBody:
    var b = FemBody(young=20000.0, poisson=0.0)
    make_beam(b, 6, 2, 2, 0.1, 0.05)
    if pin:
        for i in range(b.node_count()):
            if b.x[i] < 1e-6:
                b.pin(i)
    return b^


def tip(b: FemBody) -> Real:
    var m = Real(0)
    for i in range(b.node_count()):
        if b.x[i] > 0.59:
            m = min(m, b.y[i])
    return m


def main() raises:
    var s = Suite("fem_pd")
    var ref_b = beam(True)
    for _ in range(600):
        _ = ref_b.step_implicit(1.0 / 60.0, G)
    var want = tip(ref_b)
    var errs = List[Real]()
    var pinned_moved = Real(0)
    for it in [1, 5, 20]:
        var b = beam(True)
        var x0 = b.x.copy()
        var pd = FemPd(b, 1.0 / 60.0, it)
        var t0 = perf_counter_ns()
        for _ in range(600):
            pd.step(b, G)
        var ms = Float64(perf_counter_ns() - t0) / 600 / 1e6
        var err = abs(tip(b) / want - 1)
        errs.append(err)
        print("  PD", it, "iterations: tip y", tip(b), " vs implicit", want, " relative error", err, " ms/step", ms)
        for i in range(b.node_count()):
            if b.inv_m[i] == 0:
                pinned_moved = max(pinned_moved, abs(b.x[i] - x0[i]))
    s.check(errs[2] < 0.005, "20 iterations: tip within 0.5 % of step_implicit (Poisson 0: same energy)")
    s.check(errs[2] < errs[1] and errs[1] < errs[0], "error falls with the iteration count (1 > 5 > 20)")
    s.check(pinned_moved == 0, "pinned nodes do not move")

    var drift = List[Real]()
    for turn in [0, 1]:
        var r = beam(False)
        var q = Quat.from_axis_angle(Vec3(0, 0, 1, 0), Real(pi) / 2 * Real(turn))
        for i in range(r.node_count()):
            var p = q.rotate(r.pos(i))
            r.x[i] = p[0]
            r.y[i] = p[1]
            r.z[i] = p[2]
        var pr = FemPd(r, 1.0 / 60.0, 10)
        for _ in range(60):
            pr.step(r, Vec3(0, 0, 0, 0))
        var vmax = Real(0)
        for i in range(r.node_count()):
            vmax = max(vmax, abs(r.vx[i]) + abs(r.vy[i]) + abs(r.vz[i]))
        drift.append(vmax)
    print("  free body at rest, 1 s: max |v| unrotated", drift[0], " turned 90 degrees", drift[1])
    s.check(drift[1] < max(10 * drift[0], Real(1e-3)), "a rotated body at rest stays at rest (f32 polar-decomposition drift only)")

    var c = beam(True)
    var big = FemPd(c, 0.1, 10)
    var finite = True
    for _ in range(100):
        big.step(c, G)
    for i in range(c.node_count()):
        finite = finite and isfinite(c.x[i]) and isfinite(c.y[i]) and isfinite(c.z[i])
    print("  dt 0.1, 10 iterations, 10 s: tip y", tip(c), " (not converged per step: one local-global pass per iteration)")
    s.check(finite and tip(c) < 0 and tip(c) > -0.2, "dt 0.1: finite and bounded")

    var raised = 0
    try:
        _ = FemPd(c, 0, 10)
    except:
        raised += 1
    try:
        _ = FemPd(c, 0.1, 0)
    except:
        raised += 1
    s.check(raised == 2, "dt 0 and 0 iterations raise")
    s.finish()
