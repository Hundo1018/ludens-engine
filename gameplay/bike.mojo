"""A single-track vehicle as a force element (ROADMAP 17.74).

Two wheels on the body's centre line, one at each end of the wheelbase, each
touching the ground at one point `contact_depth` below the centre of mass.
Each wheel gives

  * a vertical spring-damper (stiffness `ks`, damping `cs`), only when its
    contact point is below `ground_y`;
  * no sideways slip: -`c_lat` x the contact point's velocity across the
    wheel's heading, capped by `mu` x the vertical force;
  * on the rear wheel a drive toward `drive_speed`, `k_drive` (v_target - v),
    capped the same way. The front wheel rolls free.

The wheel heading is the body's forward axis flattened onto the ground
plane (a leaned wheel still rolls along the ground), turned by `steer`
about the world up axis on the front wheel. Two contact points on one line
give no roll support: the bike falls over unless it is steered. Steering
into the lean turns the contact points under the centre of mass
(`BikeBalance`); the bike only stays up above a minimum speed.
"""

from std.math import sqrt, atan2
from geometry.vec import Real, Vec3, dot, cross, length
from physics.body_set import BodyId
from physics.rigid6 import QuatBody6
from physics.solver6 import ContactScene6
from .force_element import ForceElement


def _flat_forward(fwd: Vec3) -> Vec3:
    var f = Vec3(fwd[0], 0, fwd[2], 0)
    var n = length(f)
    if n < 1e-6:
        return Vec3(0, 0, 1, 0)
    return f * (1 / n)


@fieldwise_init
struct Bike(ForceElement, Copyable, Movable):
    var wheelbase: Real
    var contact_depth: Real  # contact points below the centre of mass
    var ground_y: Real
    var ks: Real  # N / m per wheel
    var cs: Real  # N s / m per wheel
    var c_lat: Real  # N s / m, sideways slip resistance per wheel
    var k_drive: Real  # N s / m, rear wheel
    var mu: Real
    var drive_speed: Real
    var steer: Real  # front wheel angle, radians, positive turns toward the body's +x

    @staticmethod
    def standard(wheelbase: Real, contact_depth: Real, mass: Real) -> Bike:
        # springs sized for 5 cm of compression under the bike's own weight
        var ks = mass * 9.8 / (2 * 0.05)
        return Bike(wheelbase, contact_depth, 0, ks, 0.3 * 2 * sqrt(ks * mass / 2), 4000.0, 3000.0, 1.0, 0.0, 0.0)

    def apply(mut self, mut sc: ContactScene6[QuatBody6], id: BodyId, t: Real) raises -> Vec3:
        var pose = sc.pose(id)
        var v = sc.velocity(id)
        var w = sc.angular_velocity(id)
        var fwd = _flat_forward(pose.rot.rotate(Vec3(0, 0, 1, 0)))
        var total = Vec3(0, 0, 0, 0)
        for i in range(2):
            var z = -0.5 * self.wheelbase if i == 0 else 0.5 * self.wheelbase
            var p = pose.pos + pose.rot.rotate(Vec3(0, -self.contact_depth, z, 0))
            var pen = self.ground_y - p[1]
            if pen <= 0:
                continue
            var vp = v + cross(w, p - pose.pos)
            var normal_f = max(Real(0), self.ks * pen - self.cs * vp[1])
            var heading = fwd
            if i == 1:
                # turn about world y by the steer angle: (x, z) rotated
                var cs_ = Real(1) - self.steer * self.steer * 0.5
                var sn_ = self.steer - self.steer * self.steer * self.steer / 6
                heading = Vec3(fwd[0] * cs_ + fwd[2] * sn_, 0, -fwd[0] * sn_ + fwd[2] * cs_, 0)
            var side = Vec3(heading[2], 0, -heading[0], 0)
            var cap = self.mu * normal_f
            var fl = Real(0)
            if i == 0:
                fl = min(max(self.k_drive * (self.drive_speed - dot(vp, heading)), -cap), cap)
            var fs = min(max(-self.c_lat * dot(vp, side), -cap), cap)
            var f = Vec3(0, normal_f, 0, 0) + heading * fl + side * fs
            sc.add_force_at(id, f, p)
            total = total + f
        return total


def lean_angle(sc: ContactScene6[QuatBody6], id: BodyId) raises -> Real:
    """Roll of the bike from upright, positive toward its +x side."""
    var pose = sc.pose(id)
    var up = pose.rot.rotate(Vec3(0, 1, 0, 0))
    var fwd = _flat_forward(pose.rot.rotate(Vec3(0, 0, 1, 0)))
    var side = Vec3(fwd[2], 0, -fwd[0], 0)
    return atan2(dot(up, side), up[1])


@fieldwise_init
struct BikeBalance(Copyable, Movable):
    """Steer into the lean: steer = kp lean + kd lean_rate (+x steering for
    +x lean), limited to +-max_steer."""

    var kp: Real
    var kd: Real
    var max_steer: Real

    def command(self, sc: ContactScene6[QuatBody6], id: BodyId) raises -> Real:
        var lean = lean_angle(sc, id)
        var pose = sc.pose(id)
        var fwd = _flat_forward(pose.rot.rotate(Vec3(0, 0, 1, 0)))
        var rate = -dot(sc.angular_velocity(id), fwd)  # d lean / dt: a positive spin about the heading tips toward -x
        var d = self.kp * lean + self.kd * rate
        return min(max(d, -self.max_steer), self.max_steer)
