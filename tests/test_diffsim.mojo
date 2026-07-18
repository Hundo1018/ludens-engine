from harness.runner import Suite
from geometry.vec import Real
from geometry.field import RealF, DualReal, DualBatch, Tape, RevReal, rev_seed
from geometry.gmv import GMV
from physics.diffsim import rollout2, rollout_ctrl

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

    # 5. Reverse-mode tape (ROADMAP 4.2): ONE rollout + ONE backward sweep
    #    yields BOTH gradient components, through the same bounce. Three-way
    #    parity: reverse == forward duals == central differences.
    var tape = Tape()
    var rvx = rev_seed(tape, vx0)
    var rvy = rev_seed(tape, vy0)
    var rr = rollout2[RevReal](rvx, rvy, 1.0, STEPS, DT)
    var adj = tape.grad(rr.x.idx)
    print(
        "  reverse: d(x)/d(vx0) =", adj[rvx.idx],
        "d(x)/d(vy0) =", adj[rvy.idx],
        "tape nodes =", len(tape.nodes),
    )
    s.check(abs(Float64(rr.x.v - dvx.x.a)) < 1e-5, "reverse value parity")
    s.check(
        abs(Float64(adj[rvx.idx] - dvx.x.b)) < 1e-4,
        "reverse == forward: d(x)/d(vx0)",
    )
    s.check(
        abs(Float64(adj[rvy.idx] - dvy.x.b)) < 1e-4,
        "reverse == forward: d(x)/d(vy0)",
    )
    s.check(abs(Float64(adj[rvx.idx]) - fd_x) < 0.02, "reverse vs FD: d/dvx0")
    s.check(abs(Float64(adj[rvy.idx]) - fd_y) < 0.02, "reverse vs FD: d/dvy0")

    # 6. One sweep per output: the SAME tape answers d(y_final)/d(inputs)
    #    without re-running the rollout.
    var adjy = tape.grad(rr.y.idx)
    var dvy_y = rollout2[DualReal](
        DualReal.const(vx0), DualReal.seed(vy0), 1.0, STEPS, DT
    )
    s.check(
        abs(Float64(adjy[rvy.idx] - dvy_y.y.b)) < 1e-4,
        "second sweep: d(y)/d(vy0) parity",
    )

    # 7. Reverse-mode through the GA motor sandwich (GMV[3,0,1,RevReal]):
    #    same translator scenario as #4, gradient read off the tape.
    var tape2 = Tape()
    var th2 = rev_seed(tape2, 0.7)
    var m2 = GMV[3, 0, 1, RevReal]()
    m2.c[0] = RevReal.const(1)
    m2.c[B10] = th2 * RevReal.const(0.5)
    var pt2 = GMV[3, 0, 1, RevReal]()
    pt2.c[E123] = RevReal.const(1)
    pt2.c[T230] = RevReal.const(-2)
    var moved2 = m2 * pt2 * m2.reverse()
    var xo2 = RevReal.zero() - moved2.c[T230]
    var adj2 = tape2.grad(xo2.idx)
    print("  reverse motor sandwich: x =", xo2.v, "dx/dt =", adj2[th2.idx])
    s.check(abs(Float64(xo2.v) - 2.7) < 1e-5, "reverse translator value")
    s.check(
        abs(Float64(adj2[th2.idx]) - 1.0) < 1e-5,
        "reverse d(x)/d(t) == 1 through GMV",
    )

    # 8. N = 8 control parameters (`rollout_ctrl`, through a bounce): the
    #    direction count exceeds DualBatch's 4 lanes, so batch needs TWO
    #    chunked rollouts while the tape still needs one. All three methods
    #    must agree on all 8 components.
    comptime NP = 8
    comptime BURST = 60
    var base = List[Real]()
    for k in range(NP):
        base.append(0.3 + 0.05 * Real(k))
    var t8 = Tape()
    var u8 = List[RevReal]()
    for k in range(NP):
        u8.append(rev_seed(t8, base[k]))
    var s8 = rollout_ctrl[RevReal](u8, BURST, DT)
    var a8 = t8.grad(s8.x.idx)
    var g_batch = List[Real]()
    for _ in range(NP):
        g_batch.append(0)
    for chunk in range(2):
        var ub = List[DualBatch]()
        for j in range(NP):
            if j // 4 == chunk:
                ub.append(DualBatch.seed(base[j], j % 4))
            else:
                ub.append(DualBatch.const(base[j]))
        var sb = rollout_ctrl[DualBatch](ub, BURST, DT)
        for l in range(4):
            g_batch[chunk * 4 + l] = sb.x.b[l]
    var u0 = List[RealF]()
    for j in range(NP):
        u0.append(RealF(base[j]))
    var s0 = rollout_ctrl[RealF](u0, BURST, DT)
    comptime H8: Real = 1e-2
    var worst_rb = Float64(0)
    var worst_rf = Float64(0)
    for k in range(NP):
        var up = List[RealF]()
        for j in range(NP):
            up.append(RealF(base[j] + (H8 if j == k else Real(0))))
        var sp = rollout_ctrl[RealF](up, BURST, DT)
        var fd = Float64((sp.x.v - s0.x.v) / H8)
        var rev_k = Float64(a8[u8[k].idx])
        if abs(rev_k - Float64(g_batch[k])) > worst_rb:
            worst_rb = abs(rev_k - Float64(g_batch[k]))
        if abs(rev_k - fd) > worst_rf:
            worst_rf = abs(rev_k - fd)
    print("  8-param: worst |rev-batch| =", worst_rb, "|rev-fd| =", worst_rf)
    s.check(Float64(s8.x.v) == Float64(s0.x.v), "8-param primal bit parity")
    s.check(worst_rb < 1e-4, "8-param: reverse == chunked batch")
    s.check(worst_rf < 0.05, "8-param: reverse vs forward differences")

    s.finish()
