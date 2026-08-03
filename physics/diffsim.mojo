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


# ---------------------------------------------------------------------------
# Source-to-source style adjoint: the code a Taichi/Dr.Jit-class tool EMITS.
#
# The reverse-mode tape in `geometry/field.mojo` discovers the computation at
# runtime and records one node per operation, then walks that list backwards.
# A source-to-source tool instead differentiates the step function at COMPILE
# time and emits an explicit backward routine — no node list, no indirection,
# no allocation. What follows is that emitted routine, written out by hand for
# `_step2`, so the engine can price the approach without a transformer.
#
# One thing the emitted code still needs, and it is the interesting part: the
# ground penalty is a BRANCH on the primal state, so the backward pass must
# know which side each step took. That is a checkpoint — but it is ONE BIT per
# step, not a node per operation, which is the whole structural difference
# between "source-to-source needs no tape" (false) and "source-to-source needs
# O(steps) bits instead of O(operations) nodes" (true, and ~100x smaller here).


def rollout_ctrl_adjoint(
    u: List[Real], burst: Int, dt: Real, mut grad: List[Real]
) -> Real:
    """Primal + gradient of the landing x w.r.t. every control in `u`.

    Forward pass records only the contact bit per step; the backward pass
    applies the transposed Jacobian of `_step2` in reverse. `grad` is filled
    with d(x_final)/d(u[k]); the return value is x_final, so callers get both
    from one call the way a real adjoint routine provides them."""
    var n = len(u)
    var steps = n * burst
    var gdt = _G * dt
    var drag = _DRAG * dt
    var kdt = _K * dt
    var cdt = _C * dt

    # ---- forward: integrate, checkpointing only the branch decision ----
    var contact = List[Bool](capacity=steps)
    var x = Real(0)
    var y = Real(1.0)
    var vx = Real(0)
    var vy = Real(2.0)
    for k in range(n):
        vx = vx + u[k]
        for _ in range(burst):
            vy = vy - gdt - drag * vy
            vx = vx - drag * vx
            var hit = y < 0
            contact.append(hit)
            if hit:
                vy = vy + kdt * (0 - y) - cdt * vy
            x = x + vx * dt
            y = y + vy * dt
    var x_final = x

    # ---- backward: seed d(x_final)/d(x_final) = 1, sweep in reverse ----
    var gx = Real(1)
    var gy = Real(0)
    var gvx = Real(0)
    var gvy = Real(0)
    grad.clear()
    for _ in range(n):
        grad.append(Real(0))

    var t = steps - 1
    for kk in range(n):
        var k = n - 1 - kk
        for _ in range(burst):
            # x1 = x + vx1*dt ; y1 = y + vy2*dt
            var g_vx1 = gvx + gx * dt
            var g_vy2 = gvy + gy * dt
            # gx, gy pass straight through to the previous x, y
            if contact[t]:
                # vy2 = vy1*(1-cdt) - kdt*y_old
                gy = gy - kdt * g_vy2
                gvy = g_vy2 * (1 - cdt)
            else:
                gvy = g_vy2
            # vy1 = vy_old*(1-drag) - gdt ; vx1 = vx_old*(1-drag)
            gvy = gvy * (1 - drag)
            gvx = g_vx1 * (1 - drag)
            t -= 1
        # vx += u[k] at the start of this burst
        grad[k] = gvx
    return x_final
