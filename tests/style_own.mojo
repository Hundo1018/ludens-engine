# tier: unit
# The numbers behind two of the engine's own pipelines (app/styles_own.mojo), without a GPU:
#   screw_axes         draws the axis each body turned about between two frames. Checked here against cases whose axis
#                      is known in closed form: a ball rolling without slipping, a turn with a slide along its axis,
#                      a pure slide; and that the screw raised to 1 is the motion and to 1/2 twice is the motion.
#   state_fingerprint  colours each body by a hash of the bits of its pose. Checked here: the same list hashes the
#                      same; moving one coordinate of one body by one unit in the last place changes that body's hash
#                      and the frame's, and no other body's.
from std.math import tan, sin, cos, sqrt
from harness.runner import Suite
from game.draw_item import DrawItem
from geometry.motor import Motor3
from geometry.quat import Quat
from geometry.vec import Real, Vec3
from app.screw import Screw, screw_of, screw_pow, foot_on_axis
from app.styles_own import item_screw, item_hash, frame_hash, hash_user, hash_color


def _v(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), Real(0))


def _dist(a: Vec3, b: Vec3) -> Float64:
    var d = a - b
    return Float64(sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]))


def _ball(x: Float64, r: Float64, roll: Float64) -> DrawItem:
    """A ball of radius r resting on y = 0 at x, turned by `roll` radians about -z (what rolling toward +x does)."""
    var q = Quat.from_axis_angle(_v(0, 0, -1), Real(roll))
    return DrawItem(1, _v(x, r, 2.0), Float64(q.x), Float64(q.y), Float64(q.z), Float64(q.w), _v(r, r, r), _v(1, 1, 1))


def _same_motion(a: Motor3, b: Motor3) -> Float64:
    """The largest distance between where a and b send four points."""
    var worst = 0.0
    for p in [_v(0, 0, 0), _v(1, 0, 0), _v(0, 1, 0), _v(-2, 0.5, 3)]:
        worst = max(worst, _dist(a.apply_point(p), b.apply_point(p)))
    return worst


def main() raises:
    var s = Suite("style_own")

    # a ball of radius 0.5 rolls 0.25 m toward +x without slipping: it turns 0.25 / 0.5 = 0.5 rad about -z. The one
    # line that stays where it is lies along z under the midpoint of the move, at height r - (d / 2) / tan(theta / 2).
    var r = 0.5
    var d = 0.25
    var th = d / r
    var sc = item_screw(_ball(1.0, r, 0.0), _ball(1.0 + d, r, th))
    var want_y = r - (d / 2) / tan(th / 2)
    print("rolling ball: dir", sc.dir[0], sc.dir[1], sc.dir[2], "angle", sc.angle, "slide", sc.slide, "axis at x", sc.point[0], "y", sc.point[1], "(closed form x 1.125 y", want_y, ")")
    s.check(sc.turns, "rolling: the motion turns")
    s.almost(Float64(abs(sc.dir[2])), 1.0, "rolling: the axis is along z", tol=1e-5)
    s.almost(Float64(sc.angle), th, "rolling: the angle is distance / radius", tol=1e-5)
    s.almost(Float64(sc.slide), 0.0, "rolling: no slide along the axis", tol=1e-5)
    s.almost(Float64(sc.point[0]), 1.0 + d / 2, "rolling: the axis is under the midpoint of the move", tol=1e-4)
    s.almost(Float64(sc.point[1]), want_y, "rolling: the axis height matches the closed form", tol=1e-4)
    s.check(Float64(sc.point[1]) > 0.0 and Float64(sc.point[1]) < 0.02, "rolling: the axis is within 2 cm of the ground, where the ball touches it")
    # a shorter step: the axis comes down onto the contact line (y = d^2 / (12 r) to first order: 0.00017 at d = 0.01)
    var sc2 = item_screw(_ball(1.0, r, 0.0), _ball(1.01, r, 0.01 / r))
    print("rolling ball, 1 cm step: axis y", sc2.point[1])
    s.check(abs(Float64(sc2.point[1])) < 2e-3, "rolling, 1 cm step: the axis is on the ground to 2 mm")

    # a turn of 1 rad about the vertical line through (3, *, 1) with a rise of 2 m
    var q = Quat.from_axis_angle(_v(0, 1, 0), Real(1.0))
    var c = _v(3, 0, 1)
    var m = Motor3.from_quat_translation(q, c - q.rotate(c) + _v(0, 2, 0))
    var hs = screw_of(m)
    print("helix: dir", hs.dir[0], hs.dir[1], hs.dir[2], "angle", hs.angle, "slide", hs.slide, "point", hs.point[0], hs.point[1], hs.point[2])
    s.almost(Float64(hs.dir[1]), 1.0, "helix: the axis is vertical", tol=1e-5)
    s.almost(Float64(hs.angle), 1.0, "helix: the angle is 1 rad", tol=1e-5)
    s.almost(Float64(hs.slide), 2.0, "helix: the slide is 2 m", tol=1e-5)
    s.check(_dist(hs.point, c) < 1e-4, "helix: the axis passes through (3, 0, 1)")
    s.check(_dist(foot_on_axis(hs, _v(5, 7, 1)), _v(3, 7, 1)) < 1e-4, "helix: the foot of (5, 7, 1) on the axis is (3, 7, 1)")
    var e1 = _same_motion(screw_pow(hs, 1.0), m)
    var half = screw_pow(hs, 0.5)
    var e2 = _same_motion(half * half, m)
    var e3 = _same_motion(screw_pow(hs, -1.0) * m, Motor3.identity())
    print("helix: screw^1 against the motion", e1, "; screw^(1/2) twice", e2, "; screw^-1 then the motion against identity", e3)
    s.check(e1 < 1e-4, "screw_pow(s, 1) is the motion")
    s.check(e2 < 1e-4, "screw_pow(s, 1/2) applied twice is the motion")
    s.check(e3 < 1e-4, "screw_pow(s, -1) undoes the motion")
    # half way along the helix a point at the axis has risen 1 m and not moved sideways
    s.check(_dist(half.apply_point(c), _v(3, 1, 1)) < 1e-4, "half the screw lifts a point of the axis by half the slide")

    # a pure slide has no axis in space: only a direction and a length
    var ts = screw_of(Motor3.from_translation(_v(0, 3, 4)))
    s.check(not ts.turns, "slide: no turn")
    s.almost(Float64(ts.slide), 5.0, "slide: the length is 5", tol=1e-5)
    s.almost(Float64(ts.dir[2]), 0.8, "slide: the direction is the unit translation", tol=1e-5)
    s.check(_same_motion(screw_pow(ts, 1.0), Motor3.from_translation(_v(0, 3, 4))) < 1e-5, "slide: screw_pow(s, 1) is the translation")
    s.check(not screw_of(Motor3.identity()).turns, "identity: no turn, no slide")

    # the fingerprint
    var a = List[DrawItem]()
    var b = List[DrawItem]()
    for i in range(6):
        a.append(_ball(Float64(i) * 0.7, 0.3 + 0.01 * Float64(i), 0.1 * Float64(i)))
        b.append(_ball(Float64(i) * 0.7, 0.3 + 0.01 * Float64(i), 0.1 * Float64(i)))
    s.check(frame_hash(a) == frame_hash(b), "the same six bodies built twice hash the same")
    var x = b[3].pos[0]
    var nudged = Real(from_bits=x.to_bits() + 1)
    b[3].pos = Vec3(nudged, b[3].pos[1], b[3].pos[2], Real(0))
    print("nudge: body 3 x", x, "->", nudged, "(difference", Float64(nudged) - Float64(x), "); frame hash", frame_hash(a), "->", frame_hash(b))
    s.check(Float64(nudged) - Float64(x) < 3e-7, "the nudge is one unit in the last place (under 3e-7 m)")
    s.check(frame_hash(a) != frame_hash(b), "one unit in the last place of one coordinate changes the frame hash")
    var others = 0
    for i in range(6):
        if item_hash(a[i]) != item_hash(b[i]):
            others += 1 if i != 3 else 100
    s.eqi(others, 100, "it changes that body's hash and no other's")
    var ca = hash_color(item_hash(a[3]))
    var cb = hash_color(item_hash(b[3]))
    print("body 3 colour", ca[0], ca[1], ca[2], "->", cb[0], cb[1], cb[2])
    s.check(_dist(ca, cb) > 0.02, "the body's colour changes visibly")
    var h = frame_hash(a)
    var u = hash_user(h)
    var back = UInt64(Int(u[0])) | (UInt64(Int(u[1])) << 16) | (UInt64(Int(u[2])) << 32) | (UInt64(Int(u[3])) << 48)
    s.check(back == h, "the four 16-bit numbers handed to the stage hold all 64 bits of the hash")
    var ok = True
    for i in range(6):
        var col = hash_color(item_hash(a[i]))
        for k in range(3):
            ok = ok and col[k] >= 0 and col[k] <= 1
    s.check(ok, "hash colours are in 0 .. 1")
    s.finish()
