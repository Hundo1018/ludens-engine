"""Sensors: what instrumentation costs, and where sharing the sweep pays.

Two questions, both about deployment rather than correctness.

First, can you afford to read them? A control loop that spends more time
measuring than simulating is not usable, so the rows put a full sensor rig
next to the dynamics step it instruments.

Second, the seam: `read_imu` re-runs the forward sweep per call, so a rig of
S sensors on a body of L links costs O(S x L). `read_imu_batch` runs the sweep
once and reads S mount points off it — O(L + S). The predicted advantage
regime is therefore MANY SENSORS ON ONE BODY, and it should widen with both S
and L. The single-sensor row is the control: with S = 1 the batch has nothing
to amortise and must show no advantage, which is what makes the wide rows
mean something.

Finite differencing is the third row because it is the alternative anyone
reaches for first: step the state, difference the velocity, subtract gravity.
It needs a second state evaluation AND is only first-order accurate, so it
loses on both axes at once — the accuracy column is the more interesting half.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3, length
from physics.chain import Chain, ChainLink
from physics.sensors import (
    read_imu, read_imu_batch, read_joint_torque, read_touch, read_rangefinder
)

comptime INER = Vec3(1.0 / 12.0, 1e-6, 1.0 / 12.0)
comptime G = Vec3(0, -9.81, 0)
comptime REPS = 3


def _chain(n: Int) -> Chain:
    var c = Chain()
    for i in range(n):
        c.add_link(
            ChainLink.revolute(
                Vec3(0, 0, 1), Vec3(0, -1, 0), Vec3(0, -0.5, 0), 1.0, INER
            )
        )
    for i in range(n):
        c.q[i] = 0.2 + Real(i) * 0.05
        c.qd[i] = 0.4 - Real(i) * 0.03
    return c^


def _zeros(n: Int) -> List[Real]:
    var v = List[Real]()
    for _ in range(n):
        v.append(0)
    return v^


def _rig(n_links: Int, n_sensors: Int) -> Tuple[List[Int], List[Vec3]]:
    var ls = List[Int]()
    var ms = List[Vec3]()
    for k in range(n_sensors):
        ls.append(k % n_links)
        ms.append(Vec3(0.1, Real(k) * 0.01 - 0.3, 0.05))
    return (ls^, ms^)


def _imu_rows(mut t: BenchTable, n_links: Int, n_sensors: Int) raises:
    var c = _chain(n_links)
    var qdd = _zeros(n_links)
    var rig = _rig(n_links, n_sensors)
    var ls = rig[0].copy()
    var ms = rig[1].copy()
    comptime ITERS = 200

    var best_one = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        for _ in range(ITERS):
            for k in range(n_sensors):
                var r = read_imu(c, ls[k], ms[k], qdd, G)
                keep(r.accel[0])
        var dt = Int(perf_counter_ns()) - t0
        if dt < best_one:
            best_one = dt
    t.add(
        "IMU x" + String(n_sensors) + ", one sweep each",
        n_links, "read", best_one, ITERS * n_sensors,
    )

    var best_batch = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        for _ in range(ITERS):
            var rs = read_imu_batch(c, ls, ms, qdd, G)
            keep(rs[0].accel[0])
        var dt = Int(perf_counter_ns()) - t0
        if dt < best_batch:
            best_batch = dt
    t.add(
        "IMU x" + String(n_sensors) + ", shared sweep",
        n_links, "read", best_batch, ITERS * n_sensors,
    )


def _cost_rows(mut t: BenchTable, n_links: Int) raises:
    """A full rig against the step it instruments."""
    comptime ITERS = 300
    var c = _chain(n_links)
    var qdd = _zeros(n_links)

    var best_step = Int.MAX
    for _ in range(REPS):
        var cc = _chain(n_links)
        var tau = _zeros(n_links)
        var t0 = Int(perf_counter_ns())
        for _ in range(ITERS):
            cc.step(1.0 / 480.0, tau, G)
        var dt = Int(perf_counter_ns()) - t0
        keep(cc.q[0])
        if dt < best_step:
            best_step = dt
    t.add("dynamics step (no sensors)", n_links, "step", best_step, ITERS)

    # a plausible robot rig: an IMU per link, torque on every joint,
    # a touch pad per link and one rangefinder
    var rig = _rig(n_links, n_links)
    var ls = rig[0].copy()
    var ms = rig[1].copy()
    var best_rig = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        for _ in range(ITERS):
            var imus = read_imu_batch(c, ls, ms, qdd, G)
            var tq = read_joint_torque(c, qdd, G)
            for k in range(n_links):
                keep(read_touch(c, k, ms[k], Real(-2.0)))
            keep(read_rangefinder(c, 0, ms[0], Vec3(0, -1, 0), Real(-2.0)))
            keep(imus[0].gyro[2])
            keep(tq[0])
        var dt = Int(perf_counter_ns()) - t0
        if dt < best_rig:
            best_rig = dt
    t.add("full rig (IMU+torque+touch+range)", n_links, "read", best_rig, ITERS)


def _accuracy() raises:
    """Exact sweep vs finite differencing, at the step sizes a rig would use.

    The reference is the exact reading; the FD error is reported relative to
    it. FD is first order, so halving h should halve the error — the point of
    printing three h values is that the trend is the evidence, not the single
    number."""
    var c = _chain(3)
    var qdd = c.dynamics(_zeros(3), G)
    var mount = Vec3(0.1, -0.4, 0.05)
    var exact = read_imu(c, 2, mount, qdd, G)

    print("  exact |a| =", length(exact.accel))
    for hi in range(9):
        var h = Real(4e-3) / Real(1 << hi)
        var cp = Chain()
        for k in range(3):
            cp.add_link(c.links[k])
        for k in range(3):
            cp.q[k] = c.q[k]
            cp.qd[k] = c.qd[k]
        var v0 = Vec3(
            c.point_velocity(2, mount, Vec3(1, 0, 0)),
            c.point_velocity(2, mount, Vec3(0, 1, 0)),
            c.point_velocity(2, mount, Vec3(0, 0, 1)),
        )
        for k in range(3):
            cp.q[k] = c.q[k] + c.qd[k] * h
            cp.qd[k] = c.qd[k] + qdd[k] * h
        var v1 = Vec3(
            cp.point_velocity(2, mount, Vec3(1, 0, 0)),
            cp.point_velocity(2, mount, Vec3(0, 1, 0)),
            cp.point_velocity(2, mount, Vec3(0, 0, 1)),
        )
        # the link frame the exact reading lives in
        var poses = c.fk()
        var qt = poses[2].to_quat_translation()
        var a_fd = (v1 - v0) * (1.0 / h) - G
        var a_ex = qt[0].rotate(exact.accel)
        var rel = length(a_fd - a_ex) / (length(a_ex) + 1e-12)
        print("  h =", h, " FD relative error:", rel)


def main() raises:
    var t = BenchTable("IMU reads: one sweep per sensor vs a shared sweep")
    comptime for li in range(3):
        comptime NL = 2 if li == 0 else (8 if li == 1 else 24)
        _imu_rows(t, NL, 1)  # control: nothing to amortise
        _imu_rows(t, NL, NL)
        _imu_rows(t, NL, NL * 4)
    t.print_report()

    var c = BenchTable("Sensor rig against the dynamics step it instruments")
    comptime for li in range(3):
        comptime NL = 2 if li == 0 else (8 if li == 1 else 24)
        _cost_rows(c, NL)
    c.print_report()

    print("")
    print("Accelerometer: exact sweep vs finite differencing")
    _accuracy()
