"""Actuators: transmission, force generation, internal dynamics.

`Chain.step` takes a torque vector, which means every control loop outside the
engine has to compute torques itself and the engine has no idea what is driving
it. An actuator is the missing abstraction, and MuJoCo's three-way split is the
right one because each part varies independently:

  transmission     WHERE the force lands — which joint coordinate, and with
                   what gear ratio. (Tendon transmission is `tendon.mojo`.)
  force generation HOW MUCH force, as an affine function of the actuator's
                   state: `f = gain·(input or measurement) + bias`. One pair of
                   coefficient vectors covers a plain motor, a position servo
                   and a velocity servo — they differ only in which term is
                   non-zero, not in code path.
  internal dynamics WHAT LAG sits between command and force: none (direct), a
                   first-order filter (pneumatics, hydraulics), or muscle
                   activation.

The affine form is why this is one struct rather than three. A position servo
is `f = -kp·(q - target) - kd·q̇`, a velocity servo is `f = -kv·(q̇ - target)`,
a motor is `f = ctrl`; all three are `gain_ctrl·u + gain_q·q + gain_qd·q̇ + bias`
with different coefficients. `test_actuator` checks the servos against a
hand-written PD loop precisely because they must agree — the abstraction is
supposed to be a repackaging, not a different controller.
"""

from std.math import exp
from geometry.vec import Real, Vec3

comptime DYN_NONE = 0
comptime DYN_FILTER = 1
comptime DYN_MUSCLE = 2


@fieldwise_init
struct Actuator(Copyable, ImplicitlyCopyable, Movable):
    var joint: Int  # transmission target
    var gear: Real  # transmission ratio
    var gain_ctrl: Real  # affine force generation
    var gain_q: Real
    var gain_qd: Real
    var bias: Real
    var dyn: Int  # internal dynamics kind
    var tau_act: Real  # filter/activation time constant
    var f_min: Real  # force clamp (f_min >= f_max disables)
    var f_max: Real

    @staticmethod
    def motor(joint: Int, gear: Real = 1) -> Self:
        """Force IS the control signal."""
        return Self(joint, gear, 1, 0, 0, 0, DYN_NONE, 0, 1, -1)

    @staticmethod
    def position(joint: Int, kp: Real, kd: Real, gear: Real = 1) -> Self:
        """PD servo: control is the TARGET position, not a force."""
        return Self(joint, gear, kp, -kp, -kd, 0, DYN_NONE, 0, 1, -1)

    @staticmethod
    def velocity(joint: Int, kv: Real, gear: Real = 1) -> Self:
        """Velocity servo: control is the target rate."""
        return Self(joint, gear, kv, 0, -kv, 0, DYN_NONE, 0, 1, -1)

    @staticmethod
    def filtered_motor(joint: Int, tau: Real, gear: Real = 1) -> Self:
        """A motor whose force lags its command by a first-order filter —
        pneumatics, hydraulics, or any drive with a real time constant."""
        return Self(joint, gear, 1, 0, 0, 0, DYN_FILTER, tau, 1, -1)

    @staticmethod
    def muscle(
        joint: Int, f_peak: Real, tau_act: Real, gear: Real = 1
    ) -> Self:
        """Hill-type muscle: activation lags the neural signal asymmetrically
        (contracting is faster than relaxing), and force is one-sided — a
        muscle pulls and never pushes, which is why `f_min` is clamped at 0.

        The asymmetry is the part worth having: a symmetric filter reproduces
        the lag but not the reason a limb driven by antagonist pairs behaves
        differently accelerating than decelerating."""
        return Self(joint, gear, f_peak, 0, 0, 0, DYN_MUSCLE, tau_act, 0, f_peak)

    def clamped(self, lo: Real, hi: Real) -> Self:
        return Self(
            self.joint, self.gear, self.gain_ctrl, self.gain_q, self.gain_qd,
            self.bias, self.dyn, self.tau_act, lo, hi,
        )

    def has_clamp(self) -> Bool:
        return self.f_max > self.f_min


@fieldwise_init
struct HillParams(Copyable, ImplicitlyCopyable, Movable):
    """Hill-type force curves for a `DYN_MUSCLE` actuator (ROADMAP 17.57).

    Muscle-tendon length is linear in the joint angle through a constant
    moment arm, l_mt = l_mt0 - arm * q (a positive arm: the muscle shortens
    as q grows, and its pull drives q up); the tendon is rigid, so fiber
    length l = l_mt - tendon_slack and its velocity v = -arm * qd. Forces,
    normalised by f_peak (Thelen 2003 shapes):

      force-length   fl(l~) = exp(-(l~ - 1)^2 / width),   l~ = l / l_opt
      force-velocity v~ = v / (vmax * l_opt); shortening (v~ < 0):
                     (1 + v~) / (1 - v~ / 0.25), 0 below v~ = -1;
                     lengthening: 1 + 0.8 v~ / (v~ + 0.18) (-> 1.8)
      passive        fp(l~) = (exp(4 (l~ - 1) / e0) - 1) / (exp(4) - 1)
                     for l~ > 1, else 0

    F = f_peak (a fl fv + fp). Each curve has its own switch; with all three
    off, fl = fv = 1 and fp = 0 exactly and the actuator is bit-identical
    to the plain `Actuator.muscle` (`test_muscle_hill`)."""

    var use_fl: Bool
    var use_fv: Bool
    var use_fp: Bool
    var arm: Real
    var l_mt0: Real
    var tendon_slack: Real
    var l_opt: Real
    var width: Real
    var vmax: Real  # optimal fiber lengths per second
    var e0: Real  # passive strain at f_peak

    @staticmethod
    def identity() -> Self:
        return Self(False, False, False, 0, 1, 0, 1, 0.45, 10, 0.6)

    @staticmethod
    def thelen(arm: Real, l_opt: Real, tendon_slack: Real, l_mt0: Real, vmax: Real = 10) -> Self:
        return Self(True, True, True, arm, l_mt0, tendon_slack, l_opt, 0.45, vmax, 0.6)

    def fiber_length(self, q: Real) -> Real:
        return self.l_mt0 - self.arm * q - self.tendon_slack

    def fl(self, q: Real) -> Real:
        if not self.use_fl:
            return 1
        var x = self.fiber_length(q) / self.l_opt - 1
        return Real(exp(-Float64(x * x / self.width)))

    def fv(self, qd: Real) -> Real:
        if not self.use_fv:
            return 1
        var v = -self.arm * qd / (self.vmax * self.l_opt)
        if v <= -1:
            return 0
        if v < 0:
            return (1 + v) / (1 - v / 0.25)
        return 1 + 0.8 * v / (v + 0.18)

    def fp(self, q: Real) -> Real:
        if not self.use_fp:
            return 0
        var x = self.fiber_length(q) / self.l_opt - 1
        if x <= 0:
            return 0
        return Real((exp(Float64(4 * x / self.e0)) - 1) / (exp(4.0) - 1))


struct ActuatorBank(Movable):
    """Actuators plus their internal state, applied to a joint torque vector."""

    var acts: List[Actuator]
    var ctrl: List[Real]  # commanded signal per actuator
    var state: List[Real]  # internal state (filter output / muscle activation)
    var hill: List[HillParams]  # per actuator; identity unless `add_hill`

    def __init__(out self):
        self.acts = List[Actuator]()
        self.ctrl = List[Real]()
        self.state = List[Real]()
        self.hill = List[HillParams]()

    def add(mut self, a: Actuator) -> Int:
        self.acts.append(a)
        self.ctrl.append(0)
        self.state.append(0)
        self.hill.append(HillParams.identity())
        return len(self.acts) - 1

    def add_hill(mut self, a: Actuator, h: HillParams) -> Int:
        """A `DYN_MUSCLE` actuator with Hill curves (17.57)."""
        # one-sided still, but no f_peak cap: lengthening (up to 1.8) and the
        # passive term legitimately exceed it
        var i = self.add(a.clamped(0, 1e30))
        self.hill[i] = h
        return i

    def muscle_force(self, i: Int, q: Real, qd: Real) -> Real:
        """Current force of actuator `i` if it is a muscle (before gear)."""
        var a = self.acts[i]
        var h = self.hill[i]
        return a.gain_ctrl * self.state[i] * h.fl(q) * h.fv(qd) + a.gain_ctrl * h.fp(q)

    def count(self) -> Int:
        return len(self.acts)

    def _advance(mut self, i: Int, dt: Real):
        """Step the internal dynamics toward the command."""
        var a = self.acts[i]
        if a.dyn == DYN_NONE:
            self.state[i] = self.ctrl[i]
            return
        if a.dyn == DYN_FILTER:
            # exact first-order response, so the result does not depend on how
            # the caller chose dt
            var k = Real(1) - Real(exp(-Float64(dt / a.tau_act)))
            self.state[i] += (self.ctrl[i] - self.state[i]) * k
            return
        # muscle: asymmetric activation, faster to contract than to relax
        var u = self.ctrl[i]
        if u < 0:
            u = 0
        if u > 1:
            u = 1
        var t = a.tau_act if u > self.state[i] else a.tau_act * 2.5
        var k = Real(1) - Real(exp(-Float64(dt / t)))
        self.state[i] += (u - self.state[i]) * k

    def apply(
        mut self,
        q: List[Real],
        qd: List[Real],
        dt: Real,
        mut tau: List[Real],
    ):
        """Advance internal dynamics and accumulate joint torques.

        Accumulates rather than overwrites, so actuator torque adds to whatever
        the caller already put there — gravity compensation from inverse
        dynamics being the obvious companion."""
        for i in range(len(self.acts)):
            self._advance(i, dt)
            var a = self.acts[i]
            var j = a.joint
            var f = (
                a.gain_ctrl * self.state[i]
                + a.gain_q * q[j]
                + a.gain_qd * qd[j]
                + a.bias
            )
            if a.dyn == DYN_MUSCLE:
                ref h = self.hill[i]
                f = f * h.fl(q[j]) * h.fv(qd[j]) + a.gain_ctrl * h.fp(q[j])
            if a.has_clamp():
                if f < a.f_min:
                    f = a.f_min
                if f > a.f_max:
                    f = a.f_max
            tau[j] += f * a.gear
