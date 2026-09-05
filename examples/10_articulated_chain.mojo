"""Example 10 — reduced-coordinate articulated dynamics (CRBA+RNEA vs ABA).

A `Chain` carries only its joint coordinates `q`/`qd`; there are no constraint
forces to project because the coordinates cannot represent a violated joint.

  1. Single revolute pendulum, small release angle. `c.step` advances it with
     the dense composite-rigid-body mass matrix + recursive Newton-Euler
     (CRBA+RNEA). We count zero crossings to recover the swing period and
     compare it to the analytic small-angle value
     T = 2*pi*sqrt(I_pivot / (m g d)) = 1.6392 s.

  2. A 3-link chain (mixed joint axes, offset pivots, varying masses)
     integrated from one shared state by `c.step` (CRBA+RNEA, O(n^3) solve) and
     by `c.step_aba` (Featherstone's articulated-body algorithm, O(n)). Two
     independent algorithms, one mechanics: the joint angles must track.

Run:

    pixi run mojo run -I build examples/10_articulated_chain.mojo
"""

from std.math import pi
from geometry.vec import Real, Vec3
from physics.chain import Chain, ChainLink

comptime G = Vec3(0, -9.8, 0, 0)


def _pendulum() -> Chain:
    """Slim rod, length 1, pivot at the end: I_pivot = 1/12 + 1/4 = 1/3."""
    var c = Chain()
    c.add_link(
        ChainLink.revolute(
            Vec3(0, 0, 1, 0), Vec3(0, 0, 0, 0), Vec3(0, -0.5, 0, 0), 1.0,
            Vec3(1.0 / 12.0, 1e-6, 1.0 / 12.0, 0),
        )
    )
    return c^


def _mixed_chain() raises -> Chain:
    """3 links, cycling axes / offset pivots / rising masses — no symmetry for
    the two integrators to agree on by accident."""
    var ch = Chain()
    for i in range(3):
        var ax = Vec3(0, 0, 1, 0)
        if i % 3 == 1:
            ax = Vec3(1, 0, 0, 0)
        if i % 3 == 2:
            ax = Vec3(0, 1, 0, 0)
        _ = ch.add_link_to(
            i - 1,
            ChainLink.revolute(
                ax, Vec3(0.1 * Real(i % 2), -0.5, 0.05 * Real(i % 3), 0),
                Vec3(0.02, -0.25, 0.01, 0), 1.0 + 0.2 * Real(i),
                Vec3(0.02 + 0.01 * Real(i), 0.015, 0.025, 0),
            ),
        )
    for i in range(3):
        ch.q[i] = 0.3 * Real(i) - 0.5
        ch.qd[i] = 0.7 - 0.15 * Real(i)
    return ch^


def main() raises:
    # --- 1. single pendulum period vs analytic ---
    comptime DT1: Real = 1.0 / 600.0
    var p = _pendulum()
    p.q[0] = 0.1  # small release angle
    var tau: List[Real] = [0.0]
    var prev = p.q[0]
    var crossings = List[Int]()
    for t in range(3000):
        p.step(DT1, tau, G)
        if prev > 0 and p.q[0] <= 0:
            crossings.append(t)
        prev = p.q[0]
    var analytic = 2.0 * pi * (1.0 / 3.0 / (1.0 * 9.8 * 0.5)) ** 0.5
    print("== single revolute pendulum: swing period ==")
    if len(crossings) >= 2:
        var period = Float64(crossings[1] - crossings[0]) * Float64(DT1)
        print("  measured period =", period, "s")
        print("  analytic period =", analytic, "s")
        print("  relative error  =", abs(period - analytic) / analytic)
    else:
        print("  FAIL: pendulum did not oscillate")

    # --- 2. CRBA+RNEA (step) vs ABA (step_aba) parity over N steps ---
    comptime DT2: Real = 1.0 / 240.0
    comptime N = 200
    var a = _mixed_chain()
    var b = _mixed_chain()
    var tau3: List[Real] = [0.1, -0.05, 0.2]
    for _ in range(N):
        a.step(DT2, tau3, G)
        b.step_aba(DT2, tau3, G)
    print("== 3-link chain: step (CRBA+RNEA) vs step_aba (ABA),", N, "steps ==")
    var worst = Float64(0)
    for i in range(3):
        var d = abs(Float64(a.q[i]) - Float64(b.q[i]))
        if d > worst:
            worst = d
        print("  joint", i, " step q =", Float64(a.q[i]), " aba q =", Float64(b.q[i]), " |d| =", d)
    print("  worst joint-angle delta =", worst, "->", "MATCH" if worst < 1e-3 else "DIVERGED")
