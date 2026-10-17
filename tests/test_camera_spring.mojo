# tier: component
"""Pose spring seam, multi-target framing and the dolly rail (ROADMAP 17.68,
`procedural.camera_math`).

  1. Parity (`CamSpring`, SPRING_SPLIT vs SPRING_MOTOR): a pure translation
     of the target (rotation held at 30 degrees about y) and a pure rotation
     (60 degrees about (1, 1, 0), position held) give the same path in both
     over 1 s (1e-4 m: float32 rounding of the motor product after a 3.7 m
     move is 1.4e-5 m; 1e-5 rad). Two steps of dt/2 equal one of dt toward a
     fixed target in both.
  2. Integration: a camera 5 m from a pivot orbits 90 degrees around it (the
     target pose is the camera rotated about the pivot): the motor spring
     stays 5 m from the pivot all the way (screw path), the split spring
     cuts the chord (closest approach printed). `frame_targets` puts three
     spheres inside the view (`Frustum.sphere_inside`); for one sphere,
     2 % closer pushes it out. The dolly on a straight 24 m rail follows a
     target walking at 2 m/s on a parallel line, keeps on the rail, looks at
     it, and stops at the rail end when the target walks past.
  3. Extreme: a bad mode, half-life 0, no targets, a zero direction and
     fov outside (0, pi) raise; dt = 0 and a NaN target change nothing.
"""

from std.math import sqrt, asin
from harness.runner import Suite
from geometry.vec import Real, Vec3, dot, length
from geometry.quat import Quat
from geometry.spline import CatmullRom
from procedural.camera_math import (
    CameraPose, Frustum, look_rotation, CamSpring, SPRING_SPLIT, SPRING_MOTOR, frame_targets, DollyRail,
)

comptime DT: Real = 1.0 / 60.0


def _angle(a: Quat, b: Quat) -> Real:
    """Rotation angle between a and b, chord form (no acos noise near 0)."""
    var c = sqrt((a.x - b.x) ** 2 + (a.y - b.y) ** 2 + (a.z - b.z) ** 2 + (a.w - b.w) ** 2)
    var c2 = sqrt((a.x + b.x) ** 2 + (a.y + b.y) ** 2 + (a.z + b.z) ** 2 + (a.w + b.w) ** 2)
    return 4 * asin(min(min(c, c2) / 2, Real(1)))


def _gap(p0: Vec3, q0: Quat, pt: Vec3, qt: Quat) raises -> Tuple[Real, Real]:
    """Largest (position, rotation) difference between the two modes over 1 s."""
    var a = CamSpring(SPRING_SPLIT, 0.2, p0, q0)
    var b = CamSpring(SPRING_MOTOR, 0.2, p0, q0)
    var dp = Real(0)
    var dq = Real(0)
    for _ in range(60):
        a.update(pt, qt, DT)
        b.update(pt, qt, DT)
        dp = max(dp, length(a.position - b.position))
        dq = max(dq, _angle(a.rotation, b.rotation))
    return (dp, dq)


def main() raises:
    var s = Suite("camera_spring")
    var y30 = Quat.from_axis_angle(Vec3(0, 1, 0, 0), 0.5235988)

    # ---- parity ----------------------------------------------------------------------------------------
    var tr = _gap(Vec3(0, 0, 0, 0), y30, Vec3(3, 1, -2, 0), y30)
    var ax = Vec3(1, 1, 0, 0) / sqrt(Real(2))
    var rt = _gap(Vec3(1, 2, 3, 0), Quat(0, 0, 0, 1), Vec3(1, 2, 3, 0), Quat.from_axis_angle(ax, 1.0471976))
    print("  split vs motor, 1 s: pure translation gap", tr[0], "m", tr[1], "rad;  pure rotation gap", rt[0], "m", rt[1], "rad")
    s.check(tr[0] < 1e-4 and tr[1] < 1e-5 and rt[0] < 1e-4 and rt[1] < 1e-5, "pure translation and pure rotation: the two springs agree")
    var half_ok = True
    for mode in [SPRING_SPLIT, SPRING_MOTOR]:
        var one = CamSpring(mode, 0.2, Vec3(0, 0, 0, 0), Quat(0, 0, 0, 1))
        var two = CamSpring(mode, 0.2, Vec3(0, 0, 0, 0), Quat(0, 0, 0, 1))
        var goal = Quat.from_axis_angle(Vec3(0, 1, 0, 0), 1.2)
        for _ in range(30):
            one.update(Vec3(2, 0, 1, 0), goal, DT)
            two.update(Vec3(2, 0, 1, 0), goal, DT / 2)
            two.update(Vec3(2, 0, 1, 0), goal, DT / 2)
        if length(one.position - two.position) > 1e-5 or _angle(one.rotation, two.rotation) > 1e-5:
            half_ok = False
    s.check(half_ok, "two half steps equal one step toward a fixed target (both modes)")

    # ---- orbit about a pivot ----------------------------------------------------------------------------
    var start = Vec3(0, 0, 5, 0)
    var q0 = look_rotation(-start, Vec3(0, 1, 0, 0))
    var end = Vec3(5, 0, 0, 0)
    var q1 = look_rotation(-end, Vec3(0, 1, 0, 0))
    var closest = List[Real]()
    var final_d = List[Real]()
    for mode in [SPRING_SPLIT, SPRING_MOTOR]:
        var c = CamSpring(mode, 0.2, start, q0)
        var lo = Real(1e9)
        for _ in range(120):
            c.update(end, q1, DT)
            lo = min(lo, length(c.position))
        closest.append(lo)
        final_d.append(length(c.position - end))
    print("  90 deg orbit about a pivot 5 m away: closest approach  split", closest[0], " motor", closest[1], ";  final gap", final_d[0], final_d[1])
    s.check(abs(closest[1] - 5) < 1e-3 and closest[0] < 4.5 and final_d[0] < 1e-3 and final_d[1] < 1e-3, "motor spring follows the arc (5 m from the pivot); split cuts the chord")

    # ---- framing ---------------------------------------------------------------------------------------
    var cs: List[Vec3] = [Vec3(0, 0, 0, 0), Vec3(4, 1, -2, 0), Vec3(-3, 0.5, 1, 0)]
    var rs: List[Real] = [0.5, 1.0, 0.3]
    var dir = Vec3(0.2, -0.3, -1, 0)
    var pos = frame_targets(cs, rs, dir, 1.0, 16.0 / 9.0)
    var fr = Frustum(CameraPose(pos, look_rotation(dir, Vec3(0, 1, 0, 0)), 1.0, 16.0 / 9.0, 0.1, 1000))
    var all_in = True
    for i in range(3):
        all_in = all_in and fr.sphere_inside(cs[i], rs[i])
    var one: List[Vec3] = [Vec3(1, 2, 3, 0)]
    var r1: List[Real] = [1.0]
    var d = Vec3(0, 0, -1, 0)
    var p1 = frame_targets(one, r1, d, 1.0, 16.0 / 9.0)
    var f_at = Frustum(CameraPose(p1, look_rotation(d, Vec3(0, 1, 0, 0)), 1.0, 16.0 / 9.0, 0.01, 1000))
    var p2 = one[0] + (p1 - one[0]) * 0.98
    var f_in = Frustum(CameraPose(p2, look_rotation(d, Vec3(0, 1, 0, 0)), 1.0, 16.0 / 9.0, 0.01, 1000))
    print("  framing: 3 spheres inside", all_in, ";  one sphere at", length(p1 - one[0]), "m inside", f_at.sphere_inside(one[0], 0.999), " 2 % closer inside", f_in.sphere_inside(one[0], 1.0))
    s.check(all_in and f_at.sphere_inside(one[0], 0.999) and not f_in.sphere_inside(one[0], 1.0), "frame_targets fits the spheres, and no closer")

    # ---- dolly rail ------------------------------------------------------------------------------------
    var pts: List[Vec3] = [Vec3(-12, 3, 0, 0), Vec3(-10, 3, 0, 0), Vec3(10, 3, 0, 0), Vec3(12, 3, 0, 0)]
    var cr = CatmullRom[3, 0.5](pts^)
    var rail = DollyRail(cr.to_bezier_path(), 256, 0.3)
    var target = Vec3(-12, 0, -5, 0)
    var cam = rail.update(target, DT)
    var x_prev = cam.position[0]
    var speed = Real(0)
    var off = Real(0)
    var look = Real(1)
    for k in range(360):
        target = target + Vec3(2 * DT, 0, 0, 0)
        cam = rail.update(target, DT)
        if k >= 300:
            speed = (cam.position[0] - x_prev) / DT
        x_prev = cam.position[0]
        off = max(off, abs(cam.position[1] - 3) + abs(cam.position[2]))
        var to = target - cam.position
        look = min(look, dot(cam.forward(), to / length(to)))
    print("  dolly: rail length", rail.length(), " camera speed after 5 s", speed, "m/s  off-rail", off, " min look cosine", look)
    s.check(abs(speed - 2) < 0.01 and off < 1e-3 and look > 0.9999, "the dolly tracks a 2 m/s target on the rail and looks at it")
    for _ in range(600):
        target = target + Vec3(2 * DT, 0, 0, 0)
        cam = rail.update(target, DT)
    print("  target past the end (x", target[0], "): camera x", cam.position[0], " s", rail.s, "of", rail.length())
    s.check(rail.s <= rail.length() and cam.position[0] > 11.9 and cam.position[0] < 12.1, "the dolly stops at the rail end")

    # ---- extremes --------------------------------------------------------------------------------------
    var raised = 0
    try:
        _ = CamSpring(2, 0.2, Vec3(0, 0, 0, 0), Quat(0, 0, 0, 1))
    except:
        raised += 1
    try:
        _ = CamSpring(SPRING_MOTOR, 0, Vec3(0, 0, 0, 0), Quat(0, 0, 0, 1))
    except:
        raised += 1
    var none = List[Vec3]()
    var nr = List[Real]()
    try:
        _ = frame_targets(none, nr, d, 1.0, 1.0)
    except:
        raised += 1
    try:
        _ = frame_targets(one, r1, Vec3(0, 0, 0, 0), 1.0, 1.0)
    except:
        raised += 1
    try:
        _ = frame_targets(one, r1, d, 3.2, 1.0)
    except:
        raised += 1
    s.check(raised == 5, "bad mode, half-life 0, no targets, zero direction, fov >= pi raise")
    var c = CamSpring(SPRING_MOTOR, 0.2, Vec3(1, 2, 3, 0), y30)
    c.update(Vec3(9, 9, 9, 0), Quat(0, 0, 0, 1), 0)
    var nan = Real(0) / Real(0)
    c.update(Vec3(nan, 0, 0, 0), Quat(0, 0, 0, 1), DT)
    s.check(c.position == Vec3(1, 2, 3, 0) and c.rotation.y == y30.y, "dt = 0 and a NaN target change nothing")
    s.finish()
