"""Actuators: the affine force law, the transmission, and the internal lag.

The servo checks are the important ones and they are deliberately checks of
EQUIVALENCE, not of behaviour. A position actuator is supposed to be a
repackaging of `f = -kp(q - target) - kd*qd`, so it must agree with that loop
written by hand, step for step. If it merely "converges to the target" it could
be any controller at all, and the abstraction would be hiding a difference
rather than expressing one.

The internal-dynamics checks pin the part that is not a repackaging. A filter's
response must be exact in dt — a caller halving the timestep must get the same
trajectory, which a naive `state += (u-state)*dt/tau` does not give — and the
muscle's activation must be ASYMMETRIC, since a symmetric filter reproduces the
lag but not the reason antagonist-driven limbs accelerate and decelerate
differently.
"""

from std.math import sqrt, exp
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.chain import Chain, ChainLink
from physics.actuator import Actuator, ActuatorBank

comptime INER = Vec3(1.0 / 12.0, 1e-6, 1.0 / 12.0)
comptime DT: Real = 1.0 / 480.0
comptime NOG = Vec3(0, 0, 0)


def _arm() -> Chain:
    var c = Chain()
    c.add_link(
        ChainLink.revolute(Vec3(0, 0, 1), Vec3(0, 0, 0), Vec3(0, -0.5, 0), 1.0, INER)
    )
    return c^


def main() raises:
    var s = Suite("actuator")

    # ---- 1. a motor actuator is exactly the torque you asked for ----
    var m = _arm()
    var bank = ActuatorBank()
    _ = bank.add(Actuator.motor(0))
    bank.ctrl[0] = 2.5
    var tau = List[Real]()
    tau.append(0)
    bank.apply(m.q, m.qd, DT, tau)
    s.check(abs(tau[0] - 2.5) < 1e-6, "motor torque == control signal")

    # gear multiplies it
    var geared = ActuatorBank()
    _ = geared.add(Actuator.motor(0, 3.0))
    geared.ctrl[0] = 2.0
    var tau_g = List[Real]()
    tau_g.append(0)
    geared.apply(m.q, m.qd, DT, tau_g)
    s.check(abs(tau_g[0] - 6.0) < 1e-6, "gear ratio scales the transmission")

    # ---- 2. the position servo IS the hand-written PD loop ----
    comptime KP: Real = 40.0
    comptime KD: Real = 4.0
    comptime TARGET: Real = 0.6
    var a_arm = _arm()
    var a_bank = ActuatorBank()
    _ = a_bank.add(Actuator.position(0, KP, KD))
    a_bank.ctrl[0] = TARGET
    var h_arm = _arm()
    var worst = Real(0)
    for _ in range(960):
        var at = List[Real]()
        at.append(0)
        a_bank.apply(a_arm.q, a_arm.qd, DT, at)
        a_arm.step(DT, at, NOG)
        var ht = List[Real]()
        ht.append(-KP * (h_arm.q[0] - TARGET) - KD * h_arm.qd[0])
        h_arm.step(DT, ht, NOG)
        var e = abs(a_arm.q[0] - h_arm.q[0])
        if e > worst:
            worst = e
    print("  servo vs hand-written PD, worst divergence:", worst,
          " final q =", a_arm.q[0])
    s.check(worst < 1e-6, "position actuator == hand-written PD, step for step")
    s.check(abs(a_arm.q[0] - TARGET) < 0.02, "and it reaches the target")

    # ---- 3. the velocity servo holds a rate ----
    var v_arm = _arm()
    var v_bank = ActuatorBank()
    _ = v_bank.add(Actuator.velocity(0, 25.0))
    v_bank.ctrl[0] = 1.5
    for _ in range(960):
        var vt = List[Real]()
        vt.append(0)
        v_bank.apply(v_arm.q, v_arm.qd, DT, vt)
        v_arm.step(DT, vt, NOG)
    print("  velocity servo settled rate:", v_arm.qd[0], " (want 1.5)")
    s.check(abs(v_arm.qd[0] - 1.5) < 0.05, "velocity actuator holds its rate")

    # ---- 4. the filter response is EXACT in dt ----
    #     A caller halving the timestep must get the same trajectory; a naive
    #     state += (u - state) * dt/tau does not, and the error is invisible at
    #     any single dt.
    comptime TAU: Real = 0.05
    var coarse = ActuatorBank()
    _ = coarse.add(Actuator.filtered_motor(0, TAU))
    coarse.ctrl[0] = 1.0
    var fine = ActuatorBank()
    _ = fine.add(Actuator.filtered_motor(0, TAU))
    fine.ctrl[0] = 1.0
    var zq = List[Real]()
    zq.append(0)
    for _ in range(100):
        var t1 = List[Real]()
        t1.append(0)
        coarse.apply(zq, zq, 0.002, t1)
    for _ in range(200):
        var t2 = List[Real]()
        t2.append(0)
        fine.apply(zq, zq, 0.001, t2)
    print("  filter after 0.2 s: dt=2ms", coarse.state[0], " dt=1ms", fine.state[0])
    s.check(
        abs(coarse.state[0] - fine.state[0]) < 1e-5,
        "filter response does not depend on the timestep",
    )
    var want = 1.0 - Real(exp(-0.2 / Float64(TAU)))
    s.check(abs(coarse.state[0] - want) < 1e-4, "filter matches 1 - exp(-t/tau)")

    # ---- 5. muscle activation is ASYMMETRIC and one-sided ----
    var mus = ActuatorBank()
    _ = mus.add(Actuator.muscle(0, 100.0, 0.02))
    mus.ctrl[0] = 1.0
    var rise_steps = 0
    for _ in range(2000):
        var t3 = List[Real]()
        t3.append(0)
        mus.apply(zq, zq, DT, t3)
        rise_steps += 1
        if mus.state[0] > 0.632:  # one time constant
            break
    var at_top = mus.state[0]
    mus.ctrl[0] = 0.0
    var fall_steps = 0
    for _ in range(4000):
        var t4 = List[Real]()
        t4.append(0)
        mus.apply(zq, zq, DT, t4)
        fall_steps += 1
        if mus.state[0] < at_top * 0.368:
            break
    print("  muscle rise steps", rise_steps, " fall steps", fall_steps)
    s.check(
        Float64(fall_steps) > Float64(rise_steps) * 1.5,
        "muscle relaxes markedly slower than it contracts",
    )

    # a muscle pulls and never pushes
    mus.ctrl[0] = -1.0
    for _ in range(2000):
        var t5 = List[Real]()
        t5.append(0)
        mus.apply(zq, zq, DT, t5)
    var t6 = List[Real]()
    t6.append(0)
    mus.apply(zq, zq, DT, t6)
    print("  muscle force at negative command:", t6[0])
    s.check(t6[0] >= 0, "a muscle never produces negative force")

    s.finish()
