"""Example 12 — a differentiable projectile rollout.

`rollout2[F]` integrates a projectile (gravity + drag + a smooth spring-damper
ground contact) and is generic over the scalar field `F`. Swapping the field
swaps what the same code computes:

  * `rollout2[RealF]`     — a plain forward simulation.
  * `rollout2[DualReal]`  — forward-mode AD: seed one input with a unit
    derivative and the final state carries d(output)/d(that input) in ONE pass.
  * `rollout2[DualBatch]` — four derivative lanes at once, so d(final x)/d(vx0)
    AND d(final x)/d(vy0) come out of a single rollout.

We take d(final x)/d(vx0) from a `DualReal` pass and cross-check it against a
central finite difference of two `RealF` passes. Then a short gradient descent
steers the launch velocity onto a mid-air target.

Run:

    pixi run mojo run -I build examples/12_diffsim_gradient.mojo
"""

from geometry.vec import Real
from geometry.field import RealF, DualReal, DualBatch
from physics.diffsim import rollout2

comptime DT: Real = 1.0 / 240.0
comptime STEPS = 480  # ~2 s, includes a smooth ground bounce


def main() raises:
    var vx0 = Real(3)
    var vy0 = Real(2)

    # --- forward-mode gradient in one rollout ---
    var dx = rollout2[DualReal](DualReal.seed(vx0), DualReal.const(vy0), 1.0, STEPS, DT)
    var dy = rollout2[DualReal](DualReal.const(vx0), DualReal.seed(vy0), 1.0, STEPS, DT)

    # --- central finite difference of the plain real rollout ---
    comptime EPS: Real = 1e-2
    var xp = rollout2[RealF](RealF(vx0 + EPS), RealF(vy0), 1.0, STEPS, DT)
    var xm = rollout2[RealF](RealF(vx0 - EPS), RealF(vy0), 1.0, STEPS, DT)
    var fd_x = Float64((xp.x.v - xm.x.v) / (2 * EPS))

    print("== d(final x) / d(vx0), through a smooth bounce ==")
    print("  forward-mode dual :", Float64(dx.x.b))
    print("  central difference :", fd_x)
    print("  relative error     :", abs(Float64(dx.x.b) - fd_x) / abs(fd_x))
    print("  final x =", Float64(dx.x.a), " (both rollouts share this primal)")

    # --- both partials from one DualBatch pass ---
    var b = rollout2[DualBatch](DualBatch.seed(vx0, 0), DualBatch.seed(vy0, 1), 1.0, STEPS, DT)
    print("== one DualBatch rollout, two partials ==")
    print("  lane0 d/d(vx0) =", Float64(b.x.b[0]), " (dual said", Float64(dx.x.b), ")")
    print("  lane1 d/d(vy0) =", Float64(b.x.b[1]), " (dual said", Float64(dy.x.b), ")")
    # Lane 1 is exactly 0, and that is the right answer rather than a dead seed:
    # in `_step2` the x-chain is x += vx*dt with vx -= drag*vx, and neither term
    # reads y or vy (drag is per-axis, and the ground penalty only touches vy).
    # So final x is structurally independent of vy0 -- both AD paths agree on a
    # zero the physics actually has.

    # --- gradient descent onto a mid-air target (3, 1.5) after 1 s ---
    var gx = Real(1)
    var gy = Real(4)
    var loss = Float64(1e30)
    for _ in range(100):
        var r = rollout2[DualBatch](DualBatch.seed(gx, 0), DualBatch.seed(gy, 1), 1.0, 240, DT)
        var ex = r.x.a - 3.0
        var ey = r.y.a - 1.5
        loss = Float64(ex * ex + ey * ey)
        if loss < 1e-6:
            break
        var glx = 2 * (ex * r.x.b[0] + ey * r.y.b[0])
        var gly = 2 * (ex * r.x.b[1] + ey * r.y.b[1])
        gx -= 0.05 * glx
        gy -= 0.05 * gly
    print("== gradient descent onto (3, 1.5) ==")
    print("  final loss =", loss, "  v0 = (", Float64(gx), ",", Float64(gy), ")")
