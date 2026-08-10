"""Gradients through RIGID contact: where they are exact, and where the whole
idea stops being well posed.

Differentiable simulation papers usually demonstrate a smooth contact model
and report that the gradient matches finite differences. That is true and it
skips the problem. An impulsive contact makes the trajectory a piecewise
smooth function of the initial state, with pieces separated by configurations
where a bounce appears or disappears. Within a piece the gradient is exact.
Across a boundary there is no gradient — the map jumps — and finite
differences straddling the boundary return an average of two unrelated
branches, which is a number, but not a derivative.

So this file does three things:

  1. checks the rigid gradient against finite differences INSIDE one piece —
     and to do that it has to first FIND one, by shrinking the probe until
     the contact step indices match on both sides. The bounce count matching
     is not enough and the first version of this test was wrong for exactly
     that reason: it compared a dual of -1.0 against a difference of 0.33 and
     the two were derivatives of different functions.
  2. measures how small the probe has to get, which is the practical finding:
     a step boundary sits every dt of flight time, so the usable epsilon
     shrinks with the timestep and with how fast the body is moving.
  3. records what the soft model's gradient does instead — it does not
     converge to the rigid one, because critical damping is restitution zero
     and no amount of stiffness turns it into 0.6.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real
from geometry.field import RealF, DualReal
from physics.diffrigid import rollout_rigid, rollout_soft

comptime DT: Real = 1.0 / 480.0
comptime STEPS = 720  # 1.5 s
comptime E: Real = 0.6


def _rigid_y(vx0: Real, vy0: Real, y0: Real) -> Tuple[Real, Int, Int]:
    """Final HEIGHT, not final x. Without drag `x = vx0 * t` with `t` fixed by
    the step count, so `d(x)/d(y0)` is identically zero and would make every
    comparison below trivially true. The height is what the bounces act on."""
    var r = rollout_rigid[RealF](
        RealF(vx0), RealF(vy0), RealF(y0), STEPS, DT, E
    )
    return (r.y.v, r.bounces, r.schedule)


def main() raises:
    var s = Suite("diffrigid")

    # ---- 1. inside one piece: dual == finite differences -----------------
    var vx0 = Real(2.5)
    var vy0 = Real(1.0)
    var y0 = Real(1.0)
    var d = rollout_rigid[DualReal](
        DualReal.const(vx0), DualReal.const(vy0), DualReal.seed(y0),
        STEPS, DT, E,
    )
    # shrink the probe until BOTH sides fire their contacts on the same steps
    var eps = Real(2e-3)
    var ok = False
    print("  probe      same count?   same schedule?")
    for _ in range(30):
        var hp = _rigid_y(vx0, vy0, y0 + eps)
        var hm = _rigid_y(vx0, vy0, y0 - eps)
        var same_n = hp[1] == d.bounces and hm[1] == d.bounces
        var same_s = hp[2] == d.schedule and hm[2] == d.schedule
        print("   ", eps, "     ", same_n, "        ", same_s)
        if same_s:
            ok = True
            break
        eps = eps * 0.25
    s.check(ok, "a probe small enough to stay on one smooth piece exists")

    var hp2 = _rigid_y(vx0, vy0, y0 + eps)
    var hm2 = _rigid_y(vx0, vy0, y0 - eps)
    var fd = (hp2[0] - hm2[0]) / (2 * eps)
    print("  d(y)/d(y0): dual", d.y.b, " fd", fd, " at eps", eps)
    s.check(
        abs(Float64(d.y.b - fd)) < 1e-3 * (abs(Float64(fd)) + 1.0),
        "rigid gradient == finite differences inside one piece",
    )
    s.check(abs(Float64(fd)) > 1e-3, "the gradient is not trivially zero")

    # the point of the loop: the naive probe passed the bounce-COUNT check
    # and was still comparing two different functions
    var np_ = _rigid_y(vx0, vy0, y0 + Real(2e-3))
    var nm = _rigid_y(vx0, vy0, y0 - Real(2e-3))
    var fd_naive = (np_[0] - nm[0]) / Real(4e-3)
    print("  naive eps=2e-3: same count", np_[1] == nm[1],
          " same schedule", np_[2] == nm[2], " fd", fd_naive)
    s.check(
        np_[1] == nm[1] and np_[2] != nm[2],
        "bounce count can match while the schedule differs",
    )
    s.check(
        abs(Float64(fd_naive - d.y.b)) > 0.5,
        "and then the difference is not the derivative",
    )

    var dv = rollout_rigid[DualReal](
        DualReal.seed(vx0), DualReal.const(vy0), DualReal.const(y0),
        STEPS, DT, E,
    )
    # d(x)/d(vx0) is exactly the total flight time: x = vx0 * t, no drag
    var t_total = Real(STEPS) * DT
    print("  d(x)/d(vx0): dual", dv.x.b, "  flight time", t_total)
    s.check(
        abs(Float64(dv.x.b - t_total)) < 1e-3,
        "d(x)/d(vx0) equals the flight time exactly",
    )

    # ---- 2. find a schedule boundary and show it breaks ------------------
    #      sweep y0 until the bounce count changes; the gradient is a
    #      one-sided derivative there and FD averages two branches
    # how dense are the boundaries? count schedule changes across a sweep
    var changes = 0
    var prev = _rigid_y(vx0, vy0, 0.50)
    for k in range(1, 500):
        var yk = Real(0.50) + Real(k) * 0.001
        var cur = _rigid_y(vx0, vy0, yk)
        if cur[2] != prev[2]:
            changes += 1
        prev = cur
    print("  schedule changes over y0 in [0.5, 1.0]:", changes, "of 499 samples")
    s.check(
        changes > 50,
        "schedule boundaries are dense, not isolated pathologies",
    )

    # ---- 3. the soft model converges to the rigid one, and is biased ----
    #      away from the boundary, raise stiffness and watch the gap close
    var rigid_ref = d.y.b  # rigid d(x)/d(y0) at the well-posed point
    var prev_gap = Real(1e30)
    var decays = True
    print("  stiffness      soft d(y)/d(y0)      gap to rigid")
    for k in range(5):
        var kk = Real(200.0) * Real(1 << (2 * k))
        var cc = Real(2.0) * Real(sqrt(Float64(kk)))  # near-critical damping
        var sd = rollout_soft[DualReal](
            DualReal.const(vx0), DualReal.const(vy0), DualReal.seed(y0),
            STEPS, DT, kk, cc,
        )
        var gap = Real(abs(Float64(sd.y.b - rigid_ref)))
        print("   ", kk, "     ", sd.y.b, "     ", gap)
        if Float64(abs(Float64(sd.y.b))) > 1e-3:
            decays = False
        prev_gap = gap
    # NOT a convergence: a critically damped spring is restitution zero, so
    # the ball stops instead of bouncing and the final height forgets where it
    # started. The gradient going to zero is that model being different, not
    # that model being close. Substituting soft contact for rigid contact
    # changes the gradient by O(1) here, and stiffness does not fix it.
    s.check(decays, "the soft gradient decays to zero, it does not converge")
    s.check(
        Float64(prev_gap) > 0.5 * abs(Float64(rigid_ref)),
        "critical damping is restitution zero: an O(1) gradient difference",
    )

    s.finish()
