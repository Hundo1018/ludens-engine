"""Actuators: what the abstraction costs, and where it earns its keep.

Cost first, because it has to be near zero for the abstraction to be worth
having: an actuator is an affine evaluation plus one optional filter step, so
a bank of them should be invisible next to a dynamics step. The rows sweep
actuator count against a bare torque vector to show that.

Then the regime the roadmap predicted: HIGH GAIN. A direct PD servo has to be
stable at the caller's timestep, and its stability limit falls as the gain
rises — past it the joint oscillates and then diverges. An actuator with
internal dynamics low-passes its own command, so the same gain stays usable.
The error column is peak |q| over the run: a stable servo settles near its
target, an unstable one grows without bound, and the number says which.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.chain import Chain, ChainLink
from physics.actuator import Actuator, ActuatorBank

comptime INER = Vec3(1.0 / 12.0, 1e-6, 1.0 / 12.0)
comptime NOG = Vec3(0, 0, 0)
comptime STEPS = 400
comptime REPS = 3


def _chain(n: Int) -> Chain:
    var c = Chain()
    for _ in range(n):
        c.add_link(
            ChainLink.revolute(
                Vec3(0, 0, 1), Vec3(0, -1, 0), Vec3(0, -0.5, 0), 1.0, INER
            )
        )
    return c^


def _cost(mut t: BenchTable, n: Int, with_acts: Bool) raises:
    var best = Int.MAX
    for _ in range(REPS):
        var c = _chain(n)
        var bank = ActuatorBank()
        if with_acts:
            for i in range(n):
                _ = bank.add(Actuator.position(i, 20.0, 2.0))
                bank.ctrl[i] = 0.2
        var t0 = Int(perf_counter_ns())
        for _ in range(STEPS):
            var tau = List[Real]()
            for _ in range(n):
                tau.append(0)
            if with_acts:
                bank.apply(c.q, c.qd, 1.0 / 480.0, tau)
            c.step(1.0 / 480.0, tau, NOG)
        var dt = Int(perf_counter_ns()) - t0
        keep(c.q[0])
        if dt < best:
            best = dt
    var name = "step + n position actuators" if with_acts else "step + bare torque vector"
    t.add(name, n, "step", best, STEPS)


def _peak(kp: Real, dt: Real, filtered: Bool) raises -> Real:
    """Peak |q| over the run — bounded when stable, unbounded when not."""
    var c = _chain(1)
    var bank = ActuatorBank()
    if filtered:
        # same PD law, but the command passes through a first-order lag
        _ = bank.add(Actuator.position(0, kp, kp * 0.1))
        bank.acts[0] = Actuator.position(0, kp, kp * 0.1)
    else:
        _ = bank.add(Actuator.position(0, kp, kp * 0.1))
    bank.ctrl[0] = 0.3
    var lag = ActuatorBank()
    _ = lag.add(Actuator.filtered_motor(0, 0.02))
    var peak = Real(0)
    for _ in range(1200):
        var tau = List[Real]()
        tau.append(0)
        if filtered:
            # servo law -> filtered drive: the actuator's internal dynamics
            # low-pass the command instead of applying it instantly
            var want = -kp * (c.q[0] - 0.3) - kp * 0.1 * c.qd[0]
            lag.ctrl[0] = want
            lag.apply(c.q, c.qd, dt, tau)
        else:
            bank.apply(c.q, c.qd, dt, tau)
        c.step(dt, tau, NOG)
        var a = abs(c.q[0])
        if a > peak:
            peak = a
        if not (peak < 1e6):
            return peak
    return peak


def _fmt(v: Real) -> String:
    if not (v < 1e6):
        return "DIVERGED"
    var x = Int(Float64(v) * 100.0 + 0.5)
    var f = x % 100
    var fs = String(f)
    if f < 10:
        fs = "0" + fs
    return String(x // 100) + "." + fs


def main() raises:
    var t = BenchTable("Actuator bank: cost against a bare torque vector")
    comptime for ni in range(3):
        comptime NL = 2 if ni == 0 else (8 if ni == 1 else 16)
        _cost(t, NL, False)
        _cost(t, NL, True)
    t.print_report()

    var st = BenchTable(
        "High-gain stability: direct PD vs an actuator with internal dynamics"
    )
    comptime DT: Real = 1.0 / 240.0
    comptime for gi in range(4):
        comptime KP: Real = Real(50.0 if gi == 0 else (500.0 if gi == 1 else (2000.0 if gi == 2 else 8000.0)))
        var d = _peak(KP, DT, False)
        var f = _peak(KP, DT, True)
        st.add("direct PD   kp=" + String(Int(KP)) + " peak|q|=" + _fmt(d), 1, "run", 1, 1)
        st.add("filtered    kp=" + String(Int(KP)) + " peak|q|=" + _fmt(f), 1, "run", 1, 1)
    st.print_report()
