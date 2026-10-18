"""Musculotendon unit: a Hill fiber in series with an elastic tendon, along
any path (ROADMAP 17.57).

`ActuatorBank.add_hill` models a rigid tendon and a constant moment arm:
fiber length is the musculotendon length minus the slack, a linear function
of one joint angle. `MuscleTendon` drops both simplifications:

  * the tendon is a spring in series: tendon strain eps = (l_t - slack) /
    slack, l_t = l_mt - l_m, and normalised tendon force ft = eps / eps0
    (linear, eps0 = strain at peak force; Thelen 2003 uses 0.04), 0 when
    slack. `eps0 = 0` keeps the tendon rigid.
  * the fiber length l_m is a state, advanced by the equilibrium model
    (Millard 2013, without pennation): the fiber and the tendon carry the
    same force, a fl(l_m) fv(v) + fp(l_m) = ft, so fv = (ft - fp) / (a fl)
    and the fiber velocity is fv's inverse (the shortening and lengthening
    branches of `HillParams.fv`, fv capped below 1.8; a fl floored at 1e-3
    so the inverse exists at zero activation).
  * l_mt comes from the caller: a `SpatialTendon`'s `length(chain)` routes
    the muscle through via points and wrap spheres, and
    `SpatialTendon.apply_tension(chain, F, tau)` puts -F dL/dq on every
    joint it crosses: the moment arms of the path, not a constant.

Curves are `HillParams`' (force-length width, passive e0, vmax, l_opt).
`test_muscle_tendon` checks the rigid-tendon limit against `HillParams`,
the force balance, the series-elastic delay and the path-based arms.
"""

from std.math import exp
from geometry.vec import Real
from .actuator import HillParams


struct MuscleTendon(Copyable, Movable):
    var h: HillParams
    var f_peak: Real
    var slack: Real  # tendon slack length
    var eps0: Real  # tendon strain at f_peak; 0 = rigid
    var l_m: Real  # fiber length (state)
    var v_m: Real  # fiber velocity of the last step (m/s)
    var force: Real  # tendon force of the last step (N)

    def __init__(out self, h: HillParams, f_peak: Real, slack: Real, eps0: Real) raises:
        if not (f_peak > 0) or not (slack > 0) or not (eps0 >= 0):
            raise Error("MuscleTendon: f_peak > 0, slack > 0, eps0 >= 0")
        self.h = h
        self.f_peak = f_peak
        self.slack = slack
        self.eps0 = eps0
        self.l_m = h.l_opt
        self.v_m = 0
        self.force = 0

    def fl(self, l: Real) -> Real:
        var x = l / self.h.l_opt - 1
        return Real(exp(-Float64(x * x / self.h.width)))

    def fp(self, l: Real) -> Real:
        var x = l / self.h.l_opt - 1
        if x <= 0:
            return 0
        return Real((exp(Float64(4 * x / self.h.e0)) - 1) / (exp(4.0) - 1))

    def ft(self, l_mt: Real, l_m: Real) -> Real:
        """Normalised tendon force."""
        var eps = (l_mt - l_m - self.slack) / self.slack
        return eps / self.eps0 if eps > 0 else Real(0)

    @staticmethod
    def fv_inverse(f: Real) -> Real:
        """Normalised fiber velocity (fiber lengths per second / vmax) for
        force-velocity value f (the inverse of `HillParams.fv`)."""
        if f <= 0:
            return -1
        if f < 1:
            return (f - 1) / (4 * f + 1)
        var c = min(f, Real(1.79))
        return 0.18 * (c - 1) / (1.8 - c)

    def equilibrate(mut self, a: Real, l_mt: Real):
        """Set l_m so the fiber at rest (v = 0) balances the tendon (bisection
        on a fl + fp - ft over (0, l_mt - slack]); a rigid tendon has
        l_m = l_mt - slack."""
        if self.eps0 == 0:
            self.l_m = l_mt - self.slack
            return
        var lo = Real(1e-4) * self.h.l_opt
        var hi = l_mt - self.slack
        for _ in range(60):
            var mid = (lo + hi) * 0.5
            var r = a * self.fl(mid) + self.fp(mid) - self.ft(l_mt, mid)
            # r grows with l_m (ft falls, fl / fp rise past the peak region)
            if r > 0:
                hi = mid
            else:
                lo = mid
        self.l_m = (lo + hi) * 0.5

    def step(mut self, a: Real, l_mt: Real, l_mt_dot: Real, dt: Real) -> Real:
        """Advance the fiber over dt at activation `a`; returns the tendon
        force F (N). With a rigid tendon the fiber follows l_mt and F is the
        rigid Hill force at fiber velocity l_mt_dot."""
        var scale = self.h.vmax * self.h.l_opt
        if self.eps0 == 0:
            self.l_m = l_mt - self.slack
            self.v_m = l_mt_dot
            var v = l_mt_dot / scale
            var fv: Real
            if v <= -1:
                fv = 0
            elif v < 0:
                fv = (1 + v) / (1 - v / 0.25)
            else:
                fv = 1 + 0.8 * v / (v + 0.18)
            self.force = self.f_peak * (a * self.fl(self.l_m) * fv + self.fp(self.l_m))
            return self.force
        var ft = self.ft(l_mt, self.l_m)
        var afl = max(a * self.fl(self.l_m), Real(1e-3))
        var fvv = (ft - self.fp(self.l_m)) / afl
        self.v_m = MuscleTendon.fv_inverse(fvv) * scale
        self.l_m = max(self.l_m + self.v_m * dt, Real(1e-4) * self.h.l_opt)
        self.force = self.f_peak * self.ft(l_mt, self.l_m)
        return self.force
