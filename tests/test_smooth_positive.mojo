# tier: integration
"""Smooth contact switch (ROADMAP 17.84, `SolverField.smooth_positive`,
`SphereWorld.contact_k`).

  1. Ordinary: the logistic 1 / (1 + exp(-k x)) has derivative
     k s (1 - s) in every AD scalar: `DualReal`, `DualBatch` and `RevReal`
     agree with each other and with central differences (1e-3); with
     k = 1e4 it is within 1e-4 of `positive` at x = +-0.01.
  2. Integration: a 0.5 m sphere dropped from 0.2 m above the ground at
     3 m/s with friction 0.5; d(x after 1 s)/d(drop height) from the sharp
     switch, from the smooth one at k = 30, 100, 300, 1000, 1e4, and from
     central differences of the sharp model (printed: the bias of each).
     Measured: the sharp gradient is 0.5 against 0.271 from differences;
     the smooth presence switch moves it only at k = 30 (0.497) and gives
     exactly the sharp value from k = 100 up, so this bias does not come
     from the presence switch (the impulse clamp and friction cone stay
     sharp). Asserted: small k changes the gradient, large k reproduces
     the sharp one bit for bit. The same scan for `clamp_k` (smooth
     impulse clamp and friction cone): the gradient moves (0.39 / 0.45 /
     0.55 at clamp_k 10 / 30 / 100) without settling on the differences
     (which themselves read 0.27 / 0.40 / 0.41 at h = 1e-3 / 3e-3 / 1e-2,
     against 0.433 from the continuous-time landing-time argument), and
     is the sharp value from 1000 up -- the clamps are not the bias
     source either.
  3. Extreme: large |k x| saturates without overflow (finite at k x = +-1e4).
"""

from std.math import isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3, WorldType
from geometry.field import SolverField, RealF, DualReal, DualBatch, RevReal, Tape, rev_seed
from physics.diffsolver import SphereWorld, V3

comptime DT: Real = 1.0 / 60.0


def _world[F: SolverField](y0: F, k: Real, ck: Real = 0) -> SphereWorld[F]:
    var w = SphereWorld[F]()
    w.mu = F.const(0.5)
    w.contact_k = k
    w.clamp_k = ck
    _ = w.add_plane(Vec3(0, 1, 0, 0), 0)
    _ = w.add_sphere(V3[F](F.zero(), y0, F.zero()), V3[F](F.const(3), F.zero(), F.zero()), F.const(0.5), F.const(1))
    return w^


def _x_end(y0: Real, k: Real, ck: Real = 0) -> Real:
    var w = _world[RealF](RealF(y0), k, ck)
    for _ in range(60):
        w.step(DT)
    return w.bodies[0].pos.x.v


def _dx_dy0(y0: Real, k: Real, ck: Real = 0) -> Real:
    var w = _world[DualReal](DualReal.seed(y0), k, ck)
    for _ in range(60):
        w.step(DT)
    return w.bodies[0].pos.x.b


def main() raises:
    var s = Suite("smooth_positive")

    # ---- the scalar ----------------------------------------------------------------------------------
    var k = Real(20)
    var ok = True
    for x in [Real(-0.2), Real(-0.03), Real(0), Real(0.05), Real(0.3)]:
        var d = DualReal.seed(x).smooth_positive(k)
        var db = DualBatch(x, SIMD[WorldType, 4](1, 2, 0, 0)).smooth_positive(k)
        var tape = Tape()
        var r = rev_seed(tape, x)
        var out = r.smooth_positive(k)
        var g = tape.grad(out.idx)[r.idx]
        var h = Real(1e-3)
        var fd = (RealF(x + h).smooth_positive(k).v - RealF(x - h).smooth_positive(k).v) / (2 * h)
        ok = ok and abs(d.b - fd) <= 1e-3 * max(Real(1), abs(fd)) and abs(g - d.b) <= 1e-6 and abs(db.b[1] - 2 * d.b) <= 1e-5
    s.check(ok, "Dual, DualBatch and Rev derivatives agree with central differences")
    var hi = RealF(0.01).smooth_positive(1e4).v
    var lo = RealF(-0.01).smooth_positive(1e4).v
    s.check(abs(hi - 1) < 1e-4 and abs(lo) < 1e-4, "k = 1e4: within 1e-4 of the sharp switch at +-0.01")
    var big = RealF(1).smooth_positive(1e4).v
    var neg = RealF(-1).smooth_positive(1e4).v
    s.check(isfinite(big) and isfinite(neg) and big == 1 and neg == 0, "saturates without overflow at k x = +-1e4")

    # ---- the sphere ----------------------------------------------------------------------------------
    var y0 = Real(0.7)
    var hfd = Real(1e-3)
    var fd = (_x_end(y0 + hfd, 0) - _x_end(y0 - hfd, 0)) / (2 * hfd)
    var sharp = _dx_dy0(y0, 0)
    print("  d x(1 s) / d drop height: central differences", fd, ";  sharp switch", sharp, "(bias", sharp - fd, ")")
    var ks: List[Real] = [30, 100, 300, 1000, 10000]
    var grads = List[Real]()
    for kk in ks:
        var g = _dx_dy0(y0, kk)
        grads.append(g)
        print("    smooth k", kk, ": gradient", g, " bias vs differences", g - fd, " x(1 s)", _x_end(y0, kk))
    s.check(grads[0] != sharp and grads[4] == sharp and isfinite(fd), "k = 30 changes the gradient; k = 1e4 gives the sharp one bit for bit")
    var all_fin = True
    for g in grads:
        all_fin = all_fin and isfinite(g)
    s.check(all_fin, "smooth gradients are finite for every k")

    # ---- smoothing the impulse clamp and the friction cone (`clamp_k`) -------------------------------
    var fd3 = (_x_end(y0 + 3e-3, 0) - _x_end(y0 - 3e-3, 0)) / 6e-3
    var fd10 = (_x_end(y0 + 1e-2, 0) - _x_end(y0 - 1e-2, 0)) / 2e-2
    print("  sharp model central differences at h = 1e-3 / 3e-3 / 1e-2:", fd, fd3, fd10, ";  continuous-time estimate 0.433")
    var cks: List[Real] = [10, 30, 100, 1000, 10000]
    var cg = List[Real]()
    for ck in cks:
        var g = _dx_dy0(y0, 0, ck)
        cg.append(g)
        var own = (_x_end(y0 + 3e-3, 0, ck) - _x_end(y0 - 3e-3, 0, ck)) / 6e-3
        print("    clamp_k", ck, ": gradient", g, " own central difference (h 3e-3)", own, " x(1 s)", _x_end(y0, 0, ck))
    s.check(cg[0] != sharp and cg[3] == sharp and cg[4] == sharp, "clamp_k = 10 changes the gradient; clamp_k >= 1000 gives the sharp one bit for bit")
    s.finish()
