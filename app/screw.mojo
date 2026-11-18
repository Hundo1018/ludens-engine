"""The screw of a rigid motion: the logarithm of a motor, in axis form.

Every rigid displacement is a turn about one line in space plus a slide along that same line (Chasles). A `Motor3`
holds it as a product; `screw_of` reads the line back out, and `screw_pow` rebuilds the motor for a fraction (or a
multiple) of the motion, which is the motion's interpolation along its own helix.

    var rel = Motor3.from_quat_translation(q1, p1) * Motor3.from_quat_translation(q0, p0).reverse()
    var s = screw_of(rel)          # the axis the body turned about between the two poses
    var half = screw_pow(s, 0.5)   # half of that motion
"""
from std.math import sqrt, atan2, cos, sin
from geometry.motor import Motor3
from geometry.quat import Quat
from geometry.vec import Real, Vec3


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, Real(0))


def _dot(a: Vec3, b: Vec3) -> Real:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return _v(a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


struct Screw(Copyable, ImplicitlyCopyable, Movable):
    var dir: Vec3  # unit direction of the axis (of the slide when there is no turn)
    var point: Vec3  # a point on the axis: the one nearest the origin; meaningless when `turns` is False
    var angle: Real  # the turn about the axis, radians, >= 0
    var slide: Real  # the distance moved along `dir`
    var turns: Bool  # False for a pure translation: the axis is at infinity, only `dir` and `slide` hold

    def __init__(out self, dir: Vec3, point: Vec3, angle: Real, slide: Real, turns: Bool):
        self.dir = dir
        self.point = point
        self.angle = angle
        self.slide = slide
        self.turns = turns


def screw_of(m: Motor3) -> Screw:
    """The screw axis, angle and slide of a unit motor."""
    var qt = m.to_quat_translation()
    var q = qt[0]
    var t = qt[1]
    var w = q.w
    var ax = _v(q.x, q.y, q.z)
    if w < 0:
        w = -w
        ax = _v(-q.x, -q.y, -q.z)
    var sn = sqrt(_dot(ax, ax))
    if sn < Real(1e-6):
        var tl = sqrt(_dot(t, t))
        if tl < Real(1e-9):
            return Screw(_v(0, 1, 0), _v(0, 0, 0), 0, 0, False)
        return Screw(_v(t[0] / tl, t[1] / tl, t[2] / tl), _v(0, 0, 0), 0, tl, False)
    var u = _v(ax[0] / sn, ax[1] / sn, ax[2] / sn)
    var angle = Real(2) * atan2(sn, w)
    var d = _dot(t, u)
    var tp = _v(t[0] - d * u[0], t[1] - d * u[1], t[2] - d * u[2])
    var cot = w / sn
    var k = _cross(u, tp)
    var c = _v((tp[0] + cot * k[0]) * 0.5, (tp[1] + cot * k[1]) * 0.5, (tp[2] + cot * k[2]) * 0.5)
    return Screw(u, c, angle, d, True)


def screw_pow(s: Screw, f: Real) -> Motor3:
    """The motor of `f` times the screw's motion: f = 0.5 is half way along the helix, f = -1 the motion undone."""
    if not s.turns:
        return Motor3.from_translation(_v(s.dir[0] * s.slide * f, s.dir[1] * s.slide * f, s.dir[2] * s.slide * f))
    var q = Quat.from_axis_angle(s.dir, s.angle * f)
    var rc = q.rotate(s.point)
    var t = _v(
        s.point[0] - rc[0] + s.dir[0] * s.slide * f,
        s.point[1] - rc[1] + s.dir[1] * s.slide * f,
        s.point[2] - rc[2] + s.dir[2] * s.slide * f,
    )
    return Motor3.from_quat_translation(q, t)


def foot_on_axis(s: Screw, p: Vec3) -> Vec3:
    """The point of the screw's axis nearest to p."""
    var k = (p[0] - s.point[0]) * s.dir[0] + (p[1] - s.point[1]) * s.dir[1] + (p[2] - s.point[2]) * s.dir[2]
    return _v(s.point[0] + k * s.dir[0], s.point[1] + k * s.dir[1], s.point[2] + k * s.dir[2])
