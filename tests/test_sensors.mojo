"""Robot sensors, gated on facts about what a real instrument reads.

The load-bearing test is the FREE-FALL one. An accelerometer measures proper
acceleration, so a body in free fall reads exactly zero — not `-g`, not `+g`.
A vertical prismatic joint released under gravity free-falls exactly, which
gives an analytic zero to compare against rather than a tolerance chosen to
make the number pass. The sign convention error that would be invisible in a
static test (reading -g instead of +g) inverts this one to 2|g|.

The second independent check is a finite-difference of world-frame velocity on
a swinging two-link chain: `a_proper = dv/dt - g`. That path shares no code
with the RNEA sweep, so it catches the `w x v` term being dropped — a mistake
whose signature is that a purely rotating single link still reads correctly.
"""

from std.math import sqrt, sin, cos
from harness.runner import Suite
from geometry.vec import Real, Vec3, length, normalize, dot
from geometry.quat import Quat
from physics.chain import Chain, ChainLink
from physics.sensors import (
    read_imu, read_joint_torque, read_joint_pos, read_joint_vel,
    read_rangefinder, read_touch, read_imu_batch,
)


def world_vel(cc: Chain, mount: Vec3) raises -> Vec3:
    """World-frame velocity of a mount point, assembled one axis at a time."""
    return Vec3(
        cc.point_velocity(1, mount, Vec3(1, 0, 0)),
        cc.point_velocity(1, mount, Vec3(0, 1, 0)),
        cc.point_velocity(1, mount, Vec3(0, 0, 1)),
    )


def zeros(n: Int) -> List[Real]:
    var v = List[Real]()
    for _ in range(n):
        v.append(0)
    return v^


def main() raises:
    var s = Suite("sensors")
    var g = Vec3(0, -9.81, 0)

    # ---- 1. FREE FALL READS ZERO ----------------------------------------
    # a vertical prismatic joint, no actuation: the link free-falls
    var fall = Chain()
    fall.add_link(
        ChainLink.prismatic(
            Vec3(0, 1, 0), Vec3(0, 0, 0), Vec3(0, 0, 0), 2.0, Vec3(0.1, 0.1, 0.1)
        )
    )
    var qdd_f = fall.dynamics(zeros(1), g)
    print("  free-fall qdd:", qdd_f[0], " (expect", g[1], ")")
    s.check(abs(Float64(qdd_f[0] - g[1])) < 1e-4, "vertical prismatic free-falls at g")

    var imu_f = read_imu(fall, 0, Vec3(0, 0, 0), qdd_f, g)
    print("  free-fall accel magnitude:", length(imu_f.accel))
    s.check(length(imu_f.accel) < 1e-4, "accelerometer reads ZERO in free fall")

    # ---- 2. AT REST IT READS +g -----------------------------------------
    # the same link held still: proper acceleration is the support force
    var support = zeros(1)
    support[0] = 2.0 * 9.81  # exactly cancels the weight
    var held = fall.dynamics(support, g)
    var imu_h = read_imu(fall, 0, Vec3(0, 0, 0), held, g)
    print("  held accel:", imu_h.accel[1], " |g| =", -g[1])
    s.check(
        abs(Float64(imu_h.accel[1] + g[1])) < 1e-3 and abs(Float64(imu_h.accel[0])) < 1e-6,
        "held against gravity reads +g along the support axis",
    )

    # ---- 3. GYRO == joint rate for a single revolute --------------------
    var pend = Chain()
    pend.add_link(
        ChainLink.revolute(
            Vec3(0, 0, 1), Vec3(0, 0, 0), Vec3(0.5, 0, 0), 1.0,
            Vec3(0.02, 0.02, 0.02)
        )
    )
    pend.qd[0] = 1.7
    var imu_g = read_imu(pend, 0, Vec3(0, 0, 0), zeros(1), g)
    print("  gyro z:", imu_g.gyro[2], " qd:", pend.qd[0])
    s.check(
        abs(Float64(imu_g.gyro[2] - 1.7)) < 1e-5
        and abs(Float64(imu_g.gyro[0])) < 1e-9,
        "gyro == joint rate about the joint axis",
    )

    # ---- 4. FINITE-DIFFERENCE PARITY on a swinging 2-link chain ---------
    #      independent of the RNEA sweep: differentiate world velocity
    var c = Chain()
    c.add_link(
        ChainLink.revolute(
            Vec3(0, 0, 1), Vec3(0, 0, 0), Vec3(0.4, 0, 0), 1.5,
            Vec3(0.05, 0.05, 0.05)
        )
    )
    _ = c.add_link_to(
        0,
        ChainLink.revolute(
            Vec3(0, 0, 1), Vec3(0.8, 0, 0), Vec3(0.3, 0, 0), 0.9,
            Vec3(0.02, 0.02, 0.02)
        ),
    )
    c.q[0] = 0.6
    c.q[1] = -0.9
    c.qd[0] = 1.1
    c.qd[1] = -0.7
    var mount = Vec3(0.25, 0.05, 0)

    var h = Real(1e-4)
    var qdd_c = c.dynamics(zeros(2), g)
    var v0 = world_vel(c, mount)
    var cp = Chain()
    cp.add_link(c.links[0])
    _ = cp.add_link_to(0, c.links[1])
    for k in range(2):
        cp.q[k] = c.q[k] + c.qd[k] * h
        cp.qd[k] = c.qd[k] + qdd_c[k] * h
    var v1 = world_vel(cp, mount)
    var a_fd = (v1 - v0) * (1.0 / h) - g  # proper = classical - g

    var imu_c = read_imu(c, 1, mount, qdd_c, g)
    # rotate the link-frame reading into world to compare
    var poses = c.fk()
    var qt = poses[1].to_quat_translation()
    var a_world = qt[0].rotate(imu_c.accel)
    var err = length(a_world - a_fd) / (length(a_fd) + 1e-9)
    print("  imu (world):", a_world[0], a_world[1], a_world[2])
    print("  fd  (world):", a_fd[0], a_fd[1], a_fd[2])
    print("  relative error:", err)
    s.check(err < 2e-3, "accelerometer == finite-differenced world velocity - g")

    # ---- 5. JOINT TORQUE SENSOR at static equilibrium -------------------
    #      a horizontal single link: tau must be -m*g*x_com
    var st = Chain()
    st.add_link(
        ChainLink.revolute(
            Vec3(0, 0, 1), Vec3(0, 0, 0), Vec3(0.7, 0, 0), 3.0,
            Vec3(0.01, 0.01, 0.01)
        )
    )
    var tau_s = read_joint_torque(st, zeros(1), g)
    var expect = Real(-3.0 * (-9.81) * 0.7)
    print("  joint torque:", tau_s[0], " analytic:", expect)
    s.check(abs(Float64(tau_s[0] - expect)) < 1e-4, "joint torque == m*g*lever")

    # ---- 6. joint pos/vel passthrough -----------------------------------
    var jp = read_joint_pos(c)
    var jv = read_joint_vel(c)
    s.check(
        abs(Float64(jp[1] - c.q[1])) < 1e-12 and abs(Float64(jv[0] - c.qd[0])) < 1e-12,
        "joint pos/vel sensors report the state",
    )

    # ---- 7. rangefinder --------------------------------------------------
    var rf = Chain()
    rf.add_link(
        ChainLink.revolute(
            Vec3(0, 0, 1), Vec3(0, 2.0, 0), Vec3(0, 0, 0), 1.0,
            Vec3(0.01, 0.01, 0.01)
        )
    )
    var d_down = read_rangefinder(rf, 0, Vec3(0, 0, 0), Vec3(0, -1, 0), Real(0.0))
    print("  rangefinder down from y=2:", d_down)
    s.check(abs(Float64(d_down - 2.0)) < 1e-5, "rangefinder measures height above the plane")
    var d_up = read_rangefinder(rf, 0, Vec3(0, 0, 0), Vec3(0, 1, 0), Real(0.0))
    s.check(d_up < 0, "pointing away returns no-return")
    var d_side = read_rangefinder(rf, 0, Vec3(0, 0, 0), Vec3(1, 0, 0), Real(0.0))
    s.check(d_side < 0, "parallel to the plane returns no-return")
    # rotating the mount by 90 deg makes local -y point along world +x -> no return
    rf.q[0] = Real(1.5707963)
    var d_rot = read_rangefinder(rf, 0, Vec3(0, 0, 0), Vec3(0, -1, 0), Real(0.0))
    print("  rangefinder after a 90-deg turn:", d_rot)
    s.check(d_rot < 0, "the ray follows the link's orientation")
    # a near-parallel ray meets the plane 6e7 m away: right, and out of range
    var d_short = read_rangefinder(
        rf, 0, Vec3(0, 0, 0), Vec3(0, -1, 0), Real(0.0), Real(1.0)
    )
    rf.q[0] = 0
    var d_inrange = read_rangefinder(
        rf, 0, Vec3(0, 0, 0), Vec3(0, -1, 0), Real(0.0), Real(1.0)
    )
    s.check(
        d_short < 0 and d_inrange < 0,
        "a target beyond max_range reads as no-return",
    )

    # ---- 8. touch --------------------------------------------------------
    var tc = Chain()
    tc.add_link(
        ChainLink.revolute(
            Vec3(0, 0, 1), Vec3(0, 0.3, 0), Vec3(0, 0, 0), 1.0,
            Vec3(0.01, 0.01, 0.01)
        )
    )
    var t_free = read_touch(tc, 0, Vec3(0, 0, 0), Real(0.0))
    var t_hit = read_touch(tc, 0, Vec3(0, -0.5, 0), Real(0.0))
    print("  touch free:", t_free, " touch pressed:", t_hit)
    s.check(t_free == 0, "no reading when clear of the floor")
    s.check(abs(Float64(t_hit - 0.2)) < 1e-5, "touch reports penetration depth")

    # ---- 9. batched reads are BIT-IDENTICAL to individual ones ----------
    #      the batch shares one forward sweep; if it diverged at all, the
    #      cheap path would be computing something else
    var ls = List[Int]()
    var ms = List[Vec3]()
    ls.append(0); ms.append(Vec3(0.1, 0.2, -0.1))
    ls.append(1); ms.append(mount)
    ls.append(1); ms.append(Vec3(0, 0, 0))
    var batch = read_imu_batch(c, ls, ms, qdd_c, g)
    var exact = True
    for k in range(len(ls)):
        var one = read_imu(c, ls[k], ms[k], qdd_c, g)
        if (
            one.accel[0] != batch[k].accel[0]
            or one.accel[1] != batch[k].accel[1]
            or one.accel[2] != batch[k].accel[2]
            or one.gyro[2] != batch[k].gyro[2]
        ):
            exact = False
    s.check(exact, "batched IMU reads are bit-identical to individual reads")

    s.finish()
