"""More vehicles as force elements (ROADMAP 17.74): quadrotor, tracked
vehicle, trailer hitch.

  * `QuadRotor`: four rotors at (+-arm, 0, +-arm) in the body frame,
    thrust along body +y, spinning alternately (front-left / back-right one
    way), each reacting on the body with a yaw torque `drag_ratio` x its
    thrust. `mix(collective, roll, pitch, yaw)` turns the four commands
    into per-rotor thrusts (clamped to [0, max_thrust]); `apply` adds the
    thrusts at the rotor positions and the summed reaction torque.
    `QuadController.command` is a PD hover / attitude loop giving those four
    commands from a target height and yaw.
  * `TrackDrive`: two tracks (left / right, `half_width` from the centre
    line, length `length`, `samples` contact points each) on a body that
    rests on the ground through its collider. Where a track point is within
    `reach` of the ground plane y = `ground_y`, it pushes along the track
    direction toward the track speed, k (v_track - v_fwd), and resists
    sliding sideways, -c v_side, both capped by mu x the body's share of
    weight per point. The tracks carry all the traction: give the hull's
    collider friction 0 (`set_friction`), or its contact friction fights
    them (2 m/s tracks moved a mu 0.5 hull at 1.59 m/s and could not turn
    it on the spot). Equal speeds drive straight; opposite speeds turn
    the vehicle on the spot (skid steering).
  * `hitch(sc, tractor, trailer, point)`: a ball joint at a world point
    (the tow ball) between two bodies.
"""

from std.math import sqrt, atan2
from geometry.vec import Real, Vec3, dot, cross
from geometry.quat import Quat
from physics.body_set import BodyId
from physics.rigid6 import QuatBody6
from physics.solver6 import ContactScene6
from physics.joints6 import Joint6
from .force_element import ForceElement


struct QuadRotor(ForceElement, Copyable, Movable):
    var arm: Real
    var max_thrust: Real  # per rotor, N
    var drag_ratio: Real  # yaw reaction torque per newton of thrust, m
    var thrust: List[Real]  # current per-rotor thrust

    def __init__(out self, arm: Real, max_thrust: Real, drag_ratio: Real) raises:
        if not (arm > 0 and max_thrust > 0 and drag_ratio >= 0):
            raise Error("QuadRotor: arm > 0, max_thrust > 0, drag_ratio >= 0")
        self.arm = arm
        self.max_thrust = max_thrust
        self.drag_ratio = drag_ratio
        self.thrust = List[Real](length=4, fill=0)

    @staticmethod
    def rotor_pos(i: Int, arm: Real) -> Vec3:
        """Rotor i: 0 front-left (-x, +z), 1 front-right, 2 back-right, 3 back-left."""
        var xs: List[Real] = [-1, 1, 1, -1]
        var zs: List[Real] = [1, 1, -1, -1]
        return Vec3(xs[i] * arm, 0, zs[i] * arm, 0)

    def mix(mut self, collective: Real, roll: Real, pitch: Real, yaw: Real):
        """Set the rotor thrusts. Collective: total thrust (N); roll / pitch: torque about body z /
        x (N m); yaw: torque about body y (N m)."""
        var spin: List[Real] = [1, -1, 1, -1]
        for i in range(4):
            var p = QuadRotor.rotor_pos(i, self.arm)
            # thrust T along +y at (x, 0, z): torque (-z T, 0, x T)
            var t = collective / 4 + roll * p[0] / (4 * self.arm * self.arm) - pitch * p[2] / (4 * self.arm * self.arm)
            if self.drag_ratio > 0:
                t += yaw * spin[i] / (4 * self.drag_ratio)
            self.thrust[i] = min(max(t, Real(0)), self.max_thrust)

    def apply(self, mut sc: ContactScene6[QuatBody6], id: BodyId, t: Real) raises -> Vec3:
        var pose = sc.pose(id)
        var up = pose.rot.rotate(Vec3(0, 1, 0, 0))
        var total = Vec3(0, 0, 0, 0)
        var spin: List[Real] = [1, -1, 1, -1]
        var yaw_t = Real(0)
        for i in range(4):
            var f = up * self.thrust[i]
            sc.add_force_at(id, f, pose.pos + pose.rot.rotate(QuadRotor.rotor_pos(i, self.arm)))
            total = total + f
            yaw_t += spin[i] * self.drag_ratio * self.thrust[i]
        sc.add_torque(id, up * yaw_t)
        return total


struct QuadController(Copyable, Movable):
    """Vertical speed comes from the height change between calls (dt
    apart), not the body's velocity: the solver adds accumulated forces once
    per step but gravity per substep, so a hovering body's end-of-step
    velocity reads about -0.06 m/s (17.66) and the damping term held the
    quad 3.8 cm high."""

    var mass: Real
    var kp_h: Real
    var kd_h: Real
    var kp_att: Real
    var kd_att: Real
    var last_y: Real
    var started: Bool

    def __init__(out self, mass: Real, kp_h: Real, kd_h: Real, kp_att: Real, kd_att: Real):
        self.mass = mass
        self.kp_h = kp_h
        self.kd_h = kd_h
        self.kp_att = kp_att
        self.kd_att = kd_att
        self.last_y = 0
        self.started = False

    def command(mut self, sc: ContactScene6[QuatBody6], id: BodyId, target_y: Real, target_yaw: Real, g: Real, dt: Real) raises -> Tuple[Real, Real, Real, Real]:
        """(collective, roll, pitch, yaw) for a level hover at `target_y`,
        heading `target_yaw` (radians about world y); call once per step."""
        var pose = sc.pose(id)
        var w = sc.angular_velocity(id)
        var up = pose.rot.rotate(Vec3(0, 1, 0, 0))
        var vy = (pose.pos[1] - self.last_y) / dt if self.started else Real(0)
        self.last_y = pose.pos[1]
        self.started = True
        var acc = self.kp_h * (target_y - pose.pos[1]) - self.kd_h * vy + g
        var collective = self.mass * acc / max(up[1], Real(0.2))
        # attitude error: tilt from up x world up, yaw from the forward axis
        var tilt = cross(up, Vec3(0, 1, 0, 0))
        var fwd = pose.rot.rotate(Vec3(0, 0, 1, 0))
        var cy = fwd[2]
        var sy = fwd[0]
        var cur = Real(0)
        if cy != 0 or sy != 0:
            cur = atan2(sy, cy)
        var e = target_yaw - cur
        while e > 3.14159265:
            e -= 6.2831853
        while e < -3.14159265:
            e += 6.2831853
        var wl = pose.rot.conjugate().rotate(w)
        var tl = pose.rot.conjugate().rotate(tilt)
        var roll = self.kp_att * tl[2] - self.kd_att * wl[2]
        var pitch = self.kp_att * tl[0] - self.kd_att * wl[0]
        var yaw = self.kp_att * e - self.kd_att * wl[1]
        return (collective, roll, pitch, yaw)


struct TrackDrive(ForceElement, Copyable, Movable):
    var half_width: Real
    var length: Real
    var samples: Int
    var ground_y: Real
    var reach: Real  # contact if within this height of the ground (body-frame bottom offset included)
    var bottom: Real  # track y in the body frame (e.g. -half height)
    var k: Real  # N s / m per point, along the track
    var c: Real  # N s / m per point, sideways
    var mu: Real
    var weight_per_point: Real
    var speed_left: Real
    var speed_right: Real

    def __init__(out self, half_width: Real, length: Real, samples: Int, bottom: Real, ground_y: Real, mass: Real, g: Real, k: Real, c: Real, mu: Real) raises:
        if not (half_width > 0 and length > 0 and samples >= 2 and mass > 0 and mu > 0):
            raise Error("TrackDrive: positive sizes, >= 2 samples per track, mass > 0, mu > 0")
        self.half_width = half_width
        self.length = length
        self.samples = samples
        self.ground_y = ground_y
        self.reach = 0.05
        self.bottom = bottom
        self.k = k
        self.c = c
        self.mu = mu
        self.weight_per_point = mass * g / Real(2 * samples)
        self.speed_left = 0
        self.speed_right = 0

    def apply(self, mut sc: ContactScene6[QuatBody6], id: BodyId, t: Real) raises -> Vec3:
        var pose = sc.pose(id)
        var v = sc.velocity(id)
        var w = sc.angular_velocity(id)
        var fwd = pose.rot.rotate(Vec3(0, 0, 1, 0))
        var side = pose.rot.rotate(Vec3(1, 0, 0, 0))
        var cap = self.mu * self.weight_per_point
        var total = Vec3(0, 0, 0, 0)
        for s in range(2):
            var x = -self.half_width if s == 0 else self.half_width
            var vt = self.speed_left if s == 0 else self.speed_right
            for k in range(self.samples):
                var z = -0.5 * self.length + self.length * Real(k) / Real(self.samples - 1)
                var p = pose.pos + pose.rot.rotate(Vec3(x, self.bottom, z, 0))
                if p[1] > self.ground_y + self.reach:
                    continue
                var vp = v + cross(w, p - pose.pos)
                var fl = self.k * (vt - dot(vp, fwd))
                var fs = -self.c * dot(vp, side)
                fl = min(max(fl, -cap), cap)
                fs = min(max(fs, -cap), cap)
                var f = fwd * fl + side * fs
                sc.add_force_at(id, f, p)
                total = total + f
        return total


def hitch(mut sc: ContactScene6[QuatBody6], tractor: BodyId, trailer: BodyId, point: Vec3) raises -> Int:
    ref a = sc.bset.bodies[tractor.index()]
    ref b = sc.bset.bodies[trailer.index()]
    return sc.add_joint(Joint6.ball(tractor.index(), trailer.index(), a.to_local(point), b.to_local(point)))
