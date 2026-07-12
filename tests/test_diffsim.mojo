from harness.runner import Suite
from geometry.vec import Real
from geometry.field import RealF, DualReal, DualBatch
from geometry.gmv import GMV
from physics.diffsim import rollout2

comptime DT: Real = 1.0 / 240.0
comptime STEPS = 480  # 2 seconds, includes at least one ground bounce


def main() raises:
    var s = Suite("diffsim")

    # 1. Forward-mode gradient vs central finite differences, THROUGH the
    #    smooth bounce: d(final x)/d(vx0) and d(final x)/d(vy0).
    var vx0 = Real(3)
    var vy0 = Real(2)
    var dvx = rollout2[DualReal](
        DualReal.seed(vx0), DualReal.const(vy0), 1.0, STEPS, DT
    )
    var dvy = rollout2[DualReal](
        DualReal.const(vx0), DualReal.seed(vy0), 1.0, STEPS, DT
    )
    comptime EPS: Real = 1e-2
    var xp = rollout2[RealF](RealF(vx0 + EPS), RealF(vy0), 1.0, STEPS, DT)
    var xm = rollout2[RealF](RealF(vx0 - EPS), RealF(vy0), 1.0, STEPS, DT)
    var fd_x = Float64((xp.x.v - xm.x.v) / (2 * EPS))
    var yp = rollout2[RealF](RealF(vx0), RealF(vy0 + EPS), 1.0, STEPS, DT)
    var ym = rollout2[RealF](RealF(vx0), RealF(vy0 - EPS), 1.0, STEPS, DT)
    var fd_y = Float64((yp.x.v - ym.x.v) / (2 * EPS))
    print("  d(x)/d(vx0): dual", dvx.x.b, "fd", fd_x)
    print("  d(x)/d(vy0): dual", dvy.x.b, "fd", fd_y)
    s.check(abs(Float64(dvx.x.b) - fd_x) < 0.02, "dual vs FD: d(x)/d(vx0)")
    s.check(abs(Float64(dvy.x.b) - fd_y) < 0.02, "dual vs FD: d(x)/d(vy0)")
    s.check(abs(fd_x) > 0.1, "gradient is nontrivial (not zero)")

    # 2. Batch lanes reproduce the sequential duals in ONE rollout.
    var b = rollout2[DualBatch](
        DualBatch.seed(vx0, 0), DualBatch.seed(vy0, 1), 1.0, STEPS, DT
    )
    s.check(
        abs(Float64(b.x.b[0] - dvx.x.b)) < 1e-5, "batch lane0 == dual d/dvx"
    )
    s.check(
        abs(Float64(b.x.b[1] - dvy.x.b)) < 1e-5, "batch lane1 == dual d/dvy"
    )
    s.check(abs(Float64(b.x.a - dvx.x.a)) < 1e-5, "batch value parity")

    # 3. Toy control: gradient-descend the launch velocity so the projectile
    #    is at (3, 1.5) after 1 s of flight (mid-air target, reachable).
    #    One batch rollout per descent step gives the full gradient.
    #    NOTE the initial guess must not settle on the ground before t=1s:
    #    a settled trajectory has dy/dv ~ 0 — the classic contact-gradient
    #    plateau (cf. Brax's pathological gradients, SOTA_GAP_ANALYSIS).
    var gx = Real(1)
    var gy = Real(4)
    var loss = Float64(1e30)
    for _ in range(100):
        var r = rollout2[DualBatch](
            DualBatch.seed(gx, 0), DualBatch.seed(gy, 1), 1.0, 240, DT
        )
        var ex = r.x.a - 3.0
        var ey = r.y.a - 1.5
        loss = Float64(ex * ex + ey * ey)
        if loss < 1e-6:
            break
        var glx = 2 * (ex * r.x.b[0] + ey * r.y.b[0])
        var gly = 2 * (ex * r.x.b[1] + ey * r.y.b[1])
        gx -= 0.05 * glx
        gy -= 0.05 * gly
    print("  control task: final loss =", loss, "v0 = (", gx, ",", gy, ")")
    s.check(loss < 1e-4, "gradient descent hits the target")

    # 4. GA-native AD: differentiate a motor sandwich through GMV[3,0,1].
    #    Translator M = 1 + (t/2)·e10 moves the PGA3 point x-coordinate by t:
    #    d/dt of the transformed coordinate must be exactly 1.
    comptime E123 = 0b0111
    comptime T230 = 0b1110
    comptime B10 = 0b1001
    var th = DualReal.seed(0.7)
    var m = GMV[3, 0, 1, DualReal]()
    m.c[0] = DualReal.const(1)
    m.c[B10] = th * DualReal.const(0.5)
    # embed P(x=2, y=0, z=0) = e123 - x·e230 (motor.mojo convention)
    var pt = GMV[3, 0, 1, DualReal]()
    pt.c[E123] = DualReal.const(1)
    pt.c[T230] = DualReal.const(-2)
    var moved = m * pt * m.reverse()
    var x_out = DualReal.zero() - moved.c[T230]  # x = -coeff(e230)
    print("  motor sandwich: x =", x_out.a, "dx/dt =", x_out.b)
    s.check(abs(Float64(x_out.a) - 2.7) < 1e-5, "translator moves x by t")
    s.check(abs(Float64(x_out.b) - 1.0) < 1e-5, "d(x)/d(t) == 1 through GMV")

    s.finish()
