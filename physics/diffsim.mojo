"""Differentiable simulation: a Field-generic rollout you can take d/dθ of.

The same projectile-with-smooth-ground trajectory runs with any `Field`
coefficient: `RealF` gives the plain simulation, `DualReal` carries one
derivative direction, `DualBatch` carries FOUR (SIMD lanes) — one rollout then
yields the full gradient of the landing point w.r.t. the launch velocity, the
Warp/MJX-style differentiable-rollout capability at toy scale (ROADMAP 3.1).

Contact is a SMOOTH penalty (spring-damper active when below ground): branch
on the primal value, derivatives flow through the penalty force — the standard
first step before differentiating hard contact.

Dynamics per step (semi-implicit Euler):
    v += g·dt − cd·v·dt                       (gravity + linear drag)
    if y < 0:  vy += (k·(−y) − c·vy)·dt       (smooth ground penalty)
    x += v·dt
"""

from geometry.vec import Real
from geometry.field import Field

comptime _G: Real = 9.8
comptime _DRAG: Real = 0.1
comptime _K: Real = 400.0  # ground spring
comptime _C: Real = 8.0  # ground damper


@fieldwise_init
struct DiffState2[F: Field](Copyable, ImplicitlyCopyable, Movable):
    var x: Self.F
    var y: Self.F
    var vx: Self.F
    var vy: Self.F


def _step2[F: Field](
    mut s: DiffState2[F], gdt: F, drag: F, kdt: F, cdt: F, dtf: F
):
    s.vy = s.vy - gdt - drag * s.vy
    s.vx = s.vx - drag * s.vx
    if s.y.value() < 0:
        # spring-damper penalty: fy = k·(−y) − c·vy
        s.vy = s.vy + kdt * (F.zero() - s.y) - cdt * s.vy
    s.x = s.x + s.vx * dtf
    s.y = s.y + s.vy * dtf


def rollout2[F: Field](
    vx0: F, vy0: F, y0: Real, steps: Int, dt: Real
) -> DiffState2[F]:
    """Launch from (0, y0) with velocity (vx0, vy0); integrate `steps` frames
    of gravity + drag + smooth ground contact. Fully Field-generic."""
    var s = DiffState2[F](F.zero(), F.const(y0), vx0, vy0)
    var gdt = F.const(_G * dt)
    var drag = F.const(_DRAG * dt)
    var kdt = F.const(_K * dt)
    var cdt = F.const(_C * dt)
    var dtf = F.const(dt)
    for _ in range(steps):
        _step2(s, gdt, drag, kdt, cdt, dtf)
    return s


def rollout_ctrl[F: Field](
    u: List[F], burst: Int, dt: Real
) -> DiffState2[F]:
    """N-parameter control rollout: len(u) horizontal thrust impulses, one at
    the start of each `burst`-step window (same dynamics as `rollout2`).
    This is the workload where the gradient-method costs separate: forward
    differences pay N+1 rollouts, `DualBatch` ⌈N/4⌉ (lane cap), the reverse
    tape ONE rollout regardless of N (ROADMAP 4.2)."""
    var s = DiffState2[F](F.zero(), F.const(1.0), F.zero(), F.const(2))
    var gdt = F.const(_G * dt)
    var drag = F.const(_DRAG * dt)
    var kdt = F.const(_K * dt)
    var cdt = F.const(_C * dt)
    var dtf = F.const(dt)
    for k in range(len(u)):
        s.vx = s.vx + u[k]
        for _ in range(burst):
            _step2(s, gdt, drag, kdt, cdt, dtf)
    return s
