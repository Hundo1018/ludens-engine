from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.chain import Chain, ChainLink

comptime G = Vec3(0, -9.8, 0)


def _pendulum_1() -> Chain:
    """Slim rod, length 1, pivot at the end: I_pivot = 1/12 + 1/4 = 1/3."""
    var c = Chain()
    c.add_link(
        ChainLink.revolute(
            Vec3(0, 0, 1), Vec3(0, 0, 0), Vec3(0, -0.5, 0), 1.0,
            Vec3(1.0 / 12.0, 1e-6, 1.0 / 12.0),
        )
    )
    return c^


def main() raises:
    var s = Suite("chain")
    comptime DT: Real = 1.0 / 600.0

    # 1. Single pendulum: small-angle period vs the analytic value.
    #    T = 2*pi*sqrt(I_pivot/(m g d)) = 2*pi*sqrt((1/3)/4.9) = 1.6392 s.
    var p = _pendulum_1()
    p.q[0] = 0.1
    var zero = List[Real]()
    var tau = List[Real]()
    tau.append(0)
    var prev_q = p.q[0]
    var crossings = List[Int]()
    for t in range(2400):
        p.step(DT, tau, G)
        if prev_q > 0 and p.q[0] <= 0:
            crossings.append(t)
        prev_q = p.q[0]
    _ = zero
    s.check(len(crossings) >= 2, "pendulum oscillates")
    if len(crossings) >= 2:
        var period = Float64(crossings[1] - crossings[0]) * Float64(DT)
        print("  1-link period:", period, "s (analytic 1.6392)")
        s.check(abs(period - 1.6392) / 1.6392 < 0.01, "period within 1%")

    # 2. Energy conservation over the swing (no applied torque).
    var e = _pendulum_1()
    e.q[0] = 1.0  # large swing
    var e0 = Float64(e.energy(G))
    for _ in range(3000):
        e.step(DT, tau, G)
    var e1 = Float64(e.energy(G))
    print("  1-link energy drift:", abs(e1 - e0) / abs(e0))
    s.check(abs(e1 - e0) / abs(e0) < 5e-3, "single-link energy conserved")

    # 3. Double pendulum (chaotic): energy still conserved.
    var d = Chain()
    d.add_link(
        ChainLink.revolute(
            Vec3(0, 0, 1), Vec3(0, 0, 0), Vec3(0, -0.5, 0), 1.0,
            Vec3(1.0 / 12.0, 1e-6, 1.0 / 12.0),
        )
    )
    d.add_link(
        ChainLink.revolute(
            Vec3(0, 0, 1), Vec3(0, -1, 0), Vec3(0, -0.5, 0), 1.0,
            Vec3(1.0 / 12.0, 1e-6, 1.0 / 12.0),
        )
    )
    d.q[0] = 0.5
    d.q[1] = 0.3
    var tau2 = List[Real]()
    tau2.append(0)
    tau2.append(0)
    var de0 = Float64(d.energy(G))
    for _ in range(3000):
        d.step(DT, tau2, G)
    var de1 = Float64(d.energy(G))
    print("  2-link energy drift:", abs(de1 - de0) / abs(de0), "e0:", de0)
    s.check(abs(de1 - de0) / abs(de0) < 2e-2, "double-pendulum energy conserved")

    # 4. Cross-formulation gate: the SAME physical pendulum that
    #    test_joints6 runs in maximal coordinates (soft ball joint) —
    #    point-ish bob (0.15 cube) on a 1 m arm: analytic 2.0367 s;
    #    the maximal-coordinate run measured 123 frames (2.050 s).
    var b = Chain()
    b.add_link(
        ChainLink.revolute(
            Vec3(0, 0, 1), Vec3(0, 0, 0), Vec3(0, -1, 0), 1.0,
            Vec3(0.03, 0.03, 0.03),  # Inertia3.box(1, .15,.15,.15) half-cube
        )
    )
    b.q[0] = 0.1
    var tb = List[Real]()
    tb.append(0)
    var prev = b.q[0]
    var cr = List[Int]()
    for t in range(3000):
        b.step(DT, tb, G)
        if prev > 0 and b.q[0] <= 0:
            cr.append(t)
        prev = b.q[0]
    s.check(len(cr) >= 2, "bob pendulum oscillates")
    if len(cr) >= 2:
        var period = Float64(cr[1] - cr[0]) * Float64(DT)
        print("  bob-pendulum period:", period, "s (analytic 2.0367, maximal-coord 2.050)")
        s.check(abs(period - 2.0367) / 2.0367 < 0.01, "reduced matches analytic (1%)")
        s.check(
            abs(period - 2.050) / 2.050 < 0.02,
            "reduced matches the maximal-coordinate run (2%)",
        )

    # 5. Determinism.
    var r1 = _pendulum_1()
    var r2 = _pendulum_1()
    r1.q[0] = 0.7
    r2.q[0] = 0.7
    for _ in range(500):
        r1.step(DT, tau, G)
        r2.step(DT, tau, G)
    s.check(Float64(r1.q[0]) == Float64(r2.q[0]), "chain runs bit-identical")

    s.finish()
