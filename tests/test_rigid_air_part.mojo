# tier: integration
"""`RigidPart`: a rigid body with torque as a Coupler part (ROADMAP 17.61).

One point at the centre of mass is `BallPart` (same implicit drag). Points
away from the centre take the air's shear: two points at x = +-0.5 m whose
air velocities differ spin the body, and the 6 x 6 implicit step keeps the
linear and angular momentum books (impulse sum = m dv, moment sum = I dw).
"""

from harness.runner import Suite
from std.math import isfinite
from geometry.vec import Real, Vec3, cross, length
from geometry.quat import Quat
from physics.rigid_air_part import RigidPart
from physics.cloth_air_parts import BallPart
from physics.serialize import BinWriter, BinReader

comptime G = Vec3(0, -9.8, 0, 0)


def _send(u: List[Vec3]) -> List[Real]:
    var d = List[Real]()
    for p in u:
        d.append(p[0])
        d.append(p[1])
        d.append(p[2])
    return d^


def main() raises:
    var s = Suite("rigid_air_part")

    # 1. a single central point is BallPart
    var ball = BallPart(Vec3(0, 1, 0, 0), 2.0, 5.0, G)
    var one = RigidPart(Vec3(0, 1, 0, 0), Quat.identity(), 2.0, Vec3(0.1, 0.1, 0.1, 0), 5.0, G, [Vec3(0, 0, 0, 0)])
    var gap = Real(0)
    for _ in range(120):
        ball.recv([Real(3), Real(0), Real(1)])
        one.recv([Real(3), Real(0), Real(1)])
        ball.advance(1.0 / 60.0)
        one.advance(1.0 / 60.0)
        gap = max(gap, length(ball.x - one.x))
    print("central point vs BallPart over 120 steps: worst position gap", gap, " x", one.x[0], " vy", one.v[1])
    s.check(gap < 1e-4, "one central point behaves as BallPart")

    # 2. two points in a shear: air u_z = +-2 at x = +-0.5 -> w_y = -2 in one stiff step
    var pts: List[Vec3] = [Vec3(0.5, 0, 0, 0), Vec3(-0.5, 0, 0, 0)]
    var rod = RigidPart(Vec3(0, 0, 0, 0), Quat.identity(), 1.0, Vec3(0.1, 0.1, 0.1, 0), 1.0e5, Vec3(0, 0, 0, 0), pts.copy())
    var u: List[Vec3] = [Vec3(0, 0, 1, 0), Vec3(0, 0, -1, 0)]
    rod.recv(_send(u))
    rod.advance(1.0 / 60.0)
    print("shear: w", rod.w[0], rod.w[1], rod.w[2], " v", rod.v[0], rod.v[1], rod.v[2], " (ideal w_y = -2)")
    s.check(abs(rod.w[1] + 2) < 0.01 and abs(rod.w[0]) < 1e-4 and abs(rod.w[2]) < 1e-4 and length(rod.v) < 1e-3, "opposite air velocities at +-0.5 m spin the body to w_y = -2, no drift")

    # 3. momentum books of the impulses: sum j = m dv, sum r x j = I dw (softer drag, with a gravity-free body)
    var soft = RigidPart(Vec3(0, 0, 0, 0), Quat.from_axis_angle(Vec3(0, 0, 1, 0), 0.4), 3.0, Vec3(0.2, 0.3, 0.4, 0), 4.0, Vec3(0, 0, 0, 0), [Vec3(0.5, 0.1, 0, 0), Vec3(-0.4, 0, 0.2, 0), Vec3(0, 0.3, -0.3, 0)])
    var us: List[Vec3] = [Vec3(1, 0.5, 0, 0), Vec3(0, 2, 0.5, 0), Vec3(-1, 0, 1, 0)]
    soft.recv(_send(us))
    var q0 = soft.q
    var pre_L = soft._inertia_world(soft.w)
    soft.advance(0.02)
    var jsum = Vec3(0, 0, 0, 0)
    var msum = Vec3(0, 0, 0, 0)
    for i in range(3):
        jsum = jsum + soft.jv[i]
        msum = msum + cross(q0.rotate(soft.local[i]), soft.jv[i])
    var dL = soft._inertia_world(soft.w) - pre_L
    print("books: sum j", jsum[0], jsum[1], jsum[2], " m dv", 3.0 * soft.v[0], 3.0 * soft.v[1], 3.0 * soft.v[2], "; sum r x j", msum[0], msum[1], msum[2])
    s.check(length(jsum - soft.v * 3.0) < 1e-4, "the impulses on the points add up to m dv")
    s.check(length(msum - dL) < 1e-3, "their moments add up to I dw")

    # 4. a stiff drag never blows up, and save / restore returns the state
    var stiff = RigidPart(Vec3(0, 0, 0, 0), Quat.identity(), 0.01, Vec3(0.001, 0.001, 0.001, 0), 1.0e7, G, pts.copy())
    stiff.recv(_send(u))
    var ok = True
    for _ in range(50):
        stiff.advance(1.0 / 60.0)
        ok = ok and isfinite(stiff.w[1]) and length(stiff.w) < 10
    s.check(ok, "c dt / m = 1e7 stays finite and bounded")
    soft.save()
    var xs = soft.x
    var ws = soft.w
    soft.advance(0.02)
    soft.restore()
    s.check(length(soft.x - xs) == 0 and length(soft.w - ws) == 0, "restore returns the saved pose and spin")
    var bw = BinWriter()
    soft.write_state(bw)
    soft.advance(0.02)
    var back = RigidPart(Vec3(9, 9, 9, 0), Quat.identity(), 3.0, Vec3(0.2, 0.3, 0.4, 0), 4.0, Vec3(0, 0, 0, 0), [Vec3(0.5, 0.1, 0, 0), Vec3(-0.4, 0, 0.2, 0), Vec3(0, 0.3, -0.3, 0)])
    var br = BinReader(bw.b.copy())
    back.read_state(br)
    back.recv(_send(us))
    back.advance(0.02)
    s.check(back.x == soft.x and back.w == soft.w and back.q.x == soft.q.x and back.q.w == soft.q.w, "a snapshot continues bit for bit")
    s.finish()
