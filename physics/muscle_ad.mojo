"""Differentiable muscle control (ROADMAP 17.57).

`hill_force_f[F]` is `HillParams`' force (fl fv a + fp, normalised) written
against `SolverField`, so the same code runs on `RealF`, carries forward
derivatives (`DualReal`) or records a reverse tape (`RevReal`): the
force-velocity branches are selected with `positive` (zero derivative at
the switch, the `SolverField` convention), the exponentials with
`SolverField.exp`.

`arm_rollout[F]` drives a 1-DOF arm (inertia `inertia`, viscous damping)
with an antagonist pair, a flexor (fiber l = l_mt0 - arm q) and an
extensor (l = l_mt0 + arm q), through first-order activation dynamics
a += (u - a) dt / tau, the controls u piecewise constant over `segments`
windows per muscle. With `RevReal` controls, one rollout and one tape
sweep give d(final angle) / d(every control): `test_muscle_ad` checks it
with `harness.gradcheck` and optimises a reach with it.
"""

from geometry.vec import Real
from geometry.field import SolverField
from .actuator import HillParams


def hill_force_f[F: SolverField](h: HillParams, a: F, l: F, v: F) -> F:
    """Normalised Hill force for fiber length `l` (m) and velocity `v`
    (m/s, positive lengthening) at activation `a`."""
    var one = F.const(1)
    var x = l * F.const(1 / h.l_opt) - one
    var fl = (F.zero() - x * x * F.const(1 / h.width)).exp()
    var vn = v * F.const(1 / (h.vmax * h.l_opt))
    var short = (F.zero() - vn).positive()
    var opv = one + vn
    var fs = opv * opv.positive() * (one - vn * F.const(4)).recip()
    var fe = one + vn * F.const(0.8) * (vn + F.const(0.18)).recip()
    var fv = fe + (fs - fe) * short
    var fp = ((x * F.const(4 / h.e0)).exp() - one) * F.const(1 / 53.598150033144236) * x.positive()
    return a * fl * fv + fp


struct ArmParams(Copyable, ImplicitlyCopyable, Movable):
    var flex: HillParams
    var ext: HillParams
    var f_peak: Real
    var inertia: Real
    var damping: Real
    var tau: Real  # activation time constant
    var dt: Real
    var steps: Int

    def __init__(out self, flex: HillParams, ext: HillParams, f_peak: Real, inertia: Real, damping: Real, tau: Real, dt: Real, steps: Int):
        self.flex = flex
        self.ext = ext
        self.f_peak = f_peak
        self.inertia = inertia
        self.damping = damping
        self.tau = tau
        self.dt = dt
        self.steps = steps


def arm_rollout[F: SolverField](p: ArmParams, u: List[F], q0: Real) -> F:
    """Final joint angle after `p.steps` steps; `u` holds `2 * segments`
    controls (flexor windows, then extensor windows)."""
    var seg = len(u) // 2
    var q = F.const(q0)
    var qd = F.zero()
    var af = F.zero()
    var ae = F.zero()
    var dt = F.const(p.dt)
    var k_act = F.const(p.dt / p.tau)
    var arm_f = F.const(p.flex.arm)
    var arm_e = F.const(p.ext.arm)
    var inv_i = F.const(1 / p.inertia)
    var fpk = F.const(p.f_peak)
    for k in range(p.steps):
        var w = min(k * seg // p.steps, seg - 1)
        af = af + (u[w] - af) * k_act
        ae = ae + (u[seg + w] - ae) * k_act
        var lf = F.const(p.flex.l_mt0 - p.flex.tendon_slack) - arm_f * q
        var le = F.const(p.ext.l_mt0 - p.ext.tendon_slack) + arm_e * q
        var ff = hill_force_f(p.flex, af, lf, F.zero() - arm_f * qd)
        var fe = hill_force_f(p.ext, ae, le, arm_e * qd)
        var tau = fpk * (arm_f * ff - arm_e * fe) - F.const(p.damping) * qd
        qd = qd + tau * inv_i * dt
        q = q + qd * dt
    return q
