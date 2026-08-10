"""Sensors: quantities derived from simulation state, evaluated per step.

Every reading here is computed FROM the state the solver already produced
rather than integrated alongside it, which is the property that makes a sensor
consistent with the physics by construction. A controller reading these gets
exactly what the simulation did, not a numerical approximation of it.

The two that are not simply state lookups are worth naming:

  accelerometer  reads PROPER acceleration — what a real accelerometer
                 measures — which is zero in free fall and reads +g when
                 resting on a table. The RNEA forward sweep already produces
                 exactly this, because its gravity trick gives the base -g, so
                 every link's linear acceleration carries the weight term.
  joint torque   is inverse dynamics, not a stored value. The torque a joint
                 actually transmits is `tau = ID(q, q̇, q̈)`, which is why the
                 sensor is exact rather than a filtered estimate.

Rangefinder is deliberately plane-only for now: the engine's raycast lives on
BVH scene geometry, and a chain has no scene. Wiring it to `collision/queries`
is the natural extension and is not done here.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot, length
from geometry.quat import Quat
from physics.chain import Chain


@fieldwise_init
struct ImuReading(Copyable, ImplicitlyCopyable, Movable):
    var accel: Vec3  # proper acceleration, LINK frame
    var gyro: Vec3  # angular velocity, LINK frame


def read_imu(
    c: Chain, link: Int, local: Vec3, qdd: List[Real], gravity: Vec3
) raises -> ImuReading:
    """IMU mounted at `local` on `link`.

    The accelerometer is the spatial linear acceleration corrected to the
    CLASSICAL one at the mount point: `a = va + w x v + wa x r + w x (w x r)`.
    Dropping the `w x v` term is the common mistake and it only shows up when
    the link is both rotating and translating — a sensor at the origin of a
    purely rotating link reads correctly either way, which is why the test
    puts the IMU on the second link of a swinging chain."""
    var m = c.link_motion(qdd, gravity)
    var w = m[0][link].v
    var v = m[1][link].v
    var wa = m[2][link].v
    var va = m[3][link].v
    var a = va + _cross3(w, v)
    if length(local) > 1e-12:
        a = a + _cross3(wa, local) + _cross3(w, _cross3(w, local))
    return ImuReading(a, w)


def read_imu_batch(
    c: Chain, links: List[Int], locals: List[Vec3],
    qdd: List[Real], gravity: Vec3,
) raises -> List[ImuReading]:
    """Every IMU on the body from ONE forward sweep.

    `read_imu` re-runs `link_motion` per call, which is O(links) work to
    service a single mount point. A rig with many sensors on the same body
    pays that repeatedly for motion it already computed, so the batched form
    turns an O(sensors x links) read into O(links + sensors). The readings are
    identical by construction — same sweep, same arithmetic — which is why the
    parity test can demand exact equality rather than a tolerance."""
    var m = c.link_motion(qdd, gravity)
    var out = List[ImuReading]()
    for k in range(len(links)):
        var i = links[k]
        var r = locals[k]
        var w = m[0][i].v
        var v = m[1][i].v
        var a = m[3][i].v + _cross3(w, v)
        if length(r) > 1e-12:
            a = a + _cross3(m[2][i].v, r) + _cross3(w, _cross3(w, r))
        out.append(ImuReading(a, w))
    return out^


def _cross3(a: Vec3, b: Vec3) -> Vec3:
    return Vec3(
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def read_joint_torque(
    c: Chain, qdd: List[Real], gravity: Vec3
) raises -> List[Real]:
    """Torque transmitted by every joint — exact, via inverse dynamics."""
    return c.inverse_dynamics(qdd, gravity)


def read_joint_pos(c: Chain) -> List[Real]:
    return c.q.copy()


def read_joint_vel(c: Chain) -> List[Real]:
    return c.qd.copy()


def read_rangefinder(
    c: Chain, link: Int, local: Vec3, dir_local: Vec3, plane_y: Real,
    max_range: Real = 100,
) raises -> Real:
    """Distance along `dir_local` from the mount point to the plane `y = k`,
    or -1 when nothing is in range — the convention a real rangefinder uses
    for "no return".

    `max_range` is not cosmetic. A ray a hair off parallel still MEETS the
    plane, just absurdly far away: at 3e-8 rad off horizontal the exact answer
    is 6.1e7 metres, which is arithmetically right and useless to a
    controller. Without a range limit the sensor degrades continuously from a
    useful reading to a meaningless one with nothing marking the crossing, so
    the limit is what makes "no return" a decidable state."""
    var poses = c.fk()
    var qt = poses[link].to_quat_translation()
    var origin = poses[link].apply_point(local)
    var d = qt[0].rotate(dir_local)
    if abs(d[1]) < 1e-9:
        return -1
    var t = (plane_y - origin[1]) / d[1]
    if t < 0 or t > max_range:
        return -1
    return t


def read_touch(
    c: Chain, link: Int, local: Vec3, floor_y: Real
) raises -> Real:
    """Penetration depth at a mount point, zero when not in contact — the
    scalar a touch pad integrates into a normal force."""
    var pw = c.point_world(link, local)
    var pen = floor_y - pw[1]
    return pen if pen > 0 else Real(0)
