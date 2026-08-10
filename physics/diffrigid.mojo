"""Differentiable RIGID contact — the part of differentiable simulation that
is actually hard.

`diffsim` differentiates a soft ground: a spring-damper penalty, smooth in
every argument, so the gradient exists everywhere and finite differences agree
with it. Real rigid-body solvers do not work that way. They detect a contact
and apply an impulse, and that is a SWITCH: the trajectory is a smooth
function of the initial state only as long as the sequence of contacts does
not change. Cross a configuration where a bounce appears or disappears and the
map is genuinely discontinuous — not stiff, not badly conditioned,
discontinuous.

Both are here because the difference is the whole subject:

  `rollout_rigid`  mirror-and-reflect impulse with restitution. Exact, no
                   stiffness parameter, and its gradient is correct almost
                   everywhere — with the "almost" carrying real weight.
  `rollout_soft`   the penalty model. It has a gradient everywhere, at the
                   price of being a DIFFERENT model: a spring-damper's
                   effective restitution is set by its damping, so matching it
                   to a given `e` is its own calibration problem and not a
                   limit you reach by turning stiffness up.

What `test_diffrigid` measures, rather than asserts: within one contact
schedule the rigid gradient is the exact derivative of the discrete map. The
catch is what "one schedule" means. It is not the same NUMBER of bounces — it
is the same STEPS at which they fire, and a finite-difference probe small
enough to be accurate is usually still large enough to move a contact across
a step boundary. That is why the schedule hash exists: without it a test can
report agreement on bounce count and then compare two different functions.
"""

from geometry.vec import Real
from geometry.field import Field

comptime _G: Real = 9.8


@fieldwise_init
struct RigidState[F: Field](Copyable, ImplicitlyCopyable, Movable):
    var x: Self.F
    var y: Self.F
    var vx: Self.F
    var vy: Self.F
    var bounces: Int
    var schedule: Int  # hash of the STEP INDICES at which contacts fired


def rollout_rigid[
    F: Field
](vx0: F, vy0: F, y0: F, steps: Int, dt: Real, restitution: Real) -> RigidState[
    F
]:
    """Ballistic flight with impulsive ground contact.

    On contact the position is MIRRORED rather than clamped. Clamping to the
    plane discards how far past it the step went, which turns every contact
    into a small, state-dependent loss of energy and puts a spurious term in
    the gradient. Mirroring is the exact reflection of the sub-step
    trajectory to first order, so the derivative it carries is the derivative
    of the physics rather than of the collision handling."""
    var s = RigidState[F](F.zero(), y0, vx0, vy0, 0, 0)
    var gdt = F.const(_G * dt)
    var dtf = F.const(dt)
    var e = F.const(restitution)
    for k in range(steps):
        s.vy = s.vy - gdt
        s.x = s.x + s.vx * dtf
        s.y = s.y + s.vy * dtf
        if s.y.value() < 0:
            s.y = F.zero() - s.y  # mirror
            s.vy = F.zero() - e * s.vy
            s.bounces += 1
            # the schedule is the set of STEPS at which contact fired, not how
            # many times. Two trajectories with the same bounce count but a
            # contact one step apart are on different smooth pieces, and a
            # finite difference between them is not a derivative of anything.
            s.schedule = s.schedule * 131 + k
    return s


def rollout_soft[
    F: Field
](
    vx0: F, vy0: F, y0: F, steps: Int, dt: Real, k: Real, c: Real
) -> RigidState[F]:
    """The same flight with a spring-damper ground of stiffness `k`.

    Differentiable everywhere by construction. The gradient it reports is the
    gradient of THIS model, and the model differs from the rigid one by an
    amount set by `k` — which is the bias the test measures as `k` grows."""
    var s = RigidState[F](F.zero(), y0, vx0, vy0, 0, 0)
    var gdt = F.const(_G * dt)
    var dtf = F.const(dt)
    var kdt = F.const(k * dt)
    var cdt = F.const(c * dt)
    for _ in range(steps):
        s.vy = s.vy - gdt
        if s.y.value() < 0:
            s.vy = s.vy + kdt * (F.zero() - s.y) - cdt * s.vy
            s.bounces += 1
        s.x = s.x + s.vx * dtf
        s.y = s.y + s.vy * dtf
    return s
