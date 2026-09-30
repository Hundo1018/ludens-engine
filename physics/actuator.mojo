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


struct ActuatorBank(Movable):
    """Actuators plus their internal state, applied to a joint torque vector."""

    var acts: List[Actuator]
    var ctrl: List[Real]  # commanded signal per actuator
    var state: List[Real]  # internal state (filter output / muscle activation)

    def __init__(out self):
        self.acts = List[Actuator]()
        self.ctrl = List[Real]()
        self.state = List[Real]()

    def add(mut self, a: Actuator) -> Int:
        self.acts.append(a)
        self.ctrl.append(0)
        self.state.append(0)
        return len(self.acts) - 1

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
            if a.has_clamp():
                if f < a.f_min:
                    f = a.f_min
                if f > a.f_max:
                    f = a.f_max
            tau[j] += f * a.gear
