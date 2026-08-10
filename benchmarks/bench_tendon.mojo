"""Tendons: analytic moment arms against the obvious alternative.

A tendon needs `dL/dq`. The straightforward way to get it is to difference the
length function — perturb each joint, re-measure the path, divide. It is easy
to write, needs no Jacobians, and is what a first implementation reaches for.
So it is the control group, and it is given its best case: at ONE degree of
freedom it costs two length evaluations against three Jacobian columns per
site, which is the regime where it should win. The rows sweep DOF count to
find where that stops being true.

The accuracy column is the part that does not move with N. The difference is
CENTRAL, so its truncation error falls as h^2 — the sweep shows the expected
4x per halving — but in f32 it still bottoms out well short of exact. What is
worth noticing is WHERE: the best step is around 1e-2 rad, close to a degree
of joint travel, and every smaller step is worse. The intuition that a finer
difference is a better one is exactly backwards here, and there is no step
size that reaches the analytic answer. For a tendon that floor matters more
than it does for a sensor, because the arms feed straight into the torques, so
the error is a force error the integrator then accumulates.

The last table is the wrap. Routing costs an acos-and-rotate per segment
whether or not the obstacle engages, so the question is what a disengaged
obstacle costs a path that does not need one.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3, length
from physics.chain import Chain, ChainLink
from physics.tendon import FixedTendon, SpatialTendon, WrapSphere

comptime REPS = 3
comptime ITERS = 400


def _chain(n: Int) -> Chain:
    var c = Chain()
    for _ in range(n):
        c.add_link(
            ChainLink.revolute(
                Vec3(0, 0, 1), Vec3(0.6, 0, 0), Vec3(0.3, 0, 0), 1.0,
                Vec3(0.02, 0.02, 0.02),
            )
        )
    for i in range(n):
        c.q[i] = 0.15 + Real(i) * 0.03
    return c^


def _tendon(n: Int, sites: Int, wrap: Bool) raises -> SpatialTendon:
    var t = SpatialTendon()
    for k in range(sites):
        t.add_site(k % n, Vec3(0.1 + Real(k) * 0.02, 0.25, 0))
    if wrap and len(t.wraps) > 0:
        for k in range(len(t.wraps)):
            t.wraps[k] = WrapSphere(Vec3(0.7, 0.9, 0), 0.05)
    return t^


def _fd_arms(t: SpatialTendon, mut c: Chain, h: Real) raises -> List[Real]:
    """Central difference of the length function — the control implementation."""
    var n = len(c.links)
    var out = List[Real]()
    for i in range(n):
        var save = c.q[i]
        c.q[i] = save + h
        var lp = t.length(c)
        c.q[i] = save - h
        var lm = t.length(c)
        c.q[i] = save
        out.append((lp - lm) / (2 * h))
    return out^


def _arm_rows(mut tab: BenchTable, n: Int, sites: Int) raises:
    var c = _chain(n)
    var t = _tendon(n, sites, False)

    var best_a = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        for _ in range(ITERS):
            var m = t.moment_arms(c)
            keep(m[0])
        var dt = Int(perf_counter_ns()) - t0
        if dt < best_a:
            best_a = dt
    tab.add(
        "analytic arms, " + String(sites) + " sites", n, "eval", best_a, ITERS
    )

    var best_f = Int.MAX
    for _ in range(REPS):
        var cc = _chain(n)
        var t0 = Int(perf_counter_ns())
        for _ in range(ITERS):
            var m = _fd_arms(t, cc, Real(2e-4))
            keep(m[0])
        var dt = Int(perf_counter_ns()) - t0
        if dt < best_f:
            best_f = dt
    tab.add(
        "finite-difference arms, " + String(sites) + " sites",
        n, "eval", best_f, ITERS,
    )


def _wrap_rows(mut tab: BenchTable, n: Int) raises:
    var c = _chain(n)
    for wi in range(2):
        var t = _tendon(n, 4, wi == 1)
        var best = Int.MAX
        for _ in range(REPS):
            var t0 = Int(perf_counter_ns())
            for _ in range(ITERS):
                var m = t.moment_arms(c)
                keep(m[0])
            var dt = Int(perf_counter_ns()) - t0
            if dt < best:
                best = dt
        var nm = "4 sites, obstacle present" if wi == 1 else "4 sites, no obstacle"
        tab.add(nm, n, "eval", best, ITERS)


def _fixed_rows(mut tab: BenchTable, n: Int) raises:
    var ft = FixedTendon()
    for i in range(n):
        ft.add(i, 1.0 - Real(i) * 0.1)
    var q = List[Real]()
    for i in range(n):
        q.append(0.2 + Real(i) * 0.01)
    var tau = List[Real]()
    for _ in range(n):
        tau.append(0)

    var best = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        for _ in range(ITERS):
            ft.apply_tension(1.0, tau)
            keep(tau[0])
        var dt = Int(perf_counter_ns()) - t0
        if dt < best:
            best = dt
    tab.add("fixed tendon (arms are the coefficients)", n, "apply", best, ITERS)

    var c = _chain(n)
    var st = _tendon(n, n, False)
    var best_s = Int.MAX
    for _ in range(REPS):
        var t2 = List[Real]()
        for _ in range(n):
            t2.append(0)
        var t0 = Int(perf_counter_ns())
        for _ in range(ITERS):
            st.apply_tension(c, 1.0, t2)
            keep(t2[0])
        var dt = Int(perf_counter_ns()) - t0
        if dt < best_s:
            best_s = dt
    tab.add("spatial tendon (path + Jacobians)", n, "apply", best_s, ITERS)


def _accuracy() raises:
    """The gap that does not close with more compute."""
    var c = _chain(4)
    var t = _tendon(4, 4, False)
    var exact = t.moment_arms(c)
    print("  analytic arm[1] =", exact[1])
    for hi in range(11):
        var h = Real(1.28e-1) / Real(1 << hi)
        var cc = _chain(4)
        var fd = _fd_arms(t, cc, h)
        var worst = Real(0)
        for i in range(4):
            var e = Real(abs(Float64(fd[i] - exact[i])))
            if e > worst:
                worst = e
        print("  h =", h, " worst FD arm error:", worst)


def main() raises:
    var t = BenchTable("Tendon moment arms: analytic vs finite differences")
    comptime for li in range(4):
        comptime NL = 1 if li == 0 else (2 if li == 1 else (8 if li == 2 else 24))
        _arm_rows(t, NL, 2)
        _arm_rows(t, NL, 8)
    t.print_report()

    var w = BenchTable("Wrap routing: what a disengaged obstacle costs")
    comptime for li in range(3):
        comptime NL = 2 if li == 0 else (8 if li == 1 else 24)
        _wrap_rows(w, NL)
    w.print_report()

    var f = BenchTable("Fixed vs spatial tendons at the same joint count")
    comptime for li in range(3):
        comptime NL = 2 if li == 0 else (8 if li == 1 else 24)
        _fixed_rows(f, NL)
    f.print_report()

    print("")
    print("Moment-arm accuracy: the finite-difference floor")
    _accuracy()
