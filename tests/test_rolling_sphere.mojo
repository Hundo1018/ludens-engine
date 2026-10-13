# tier: integration
"""Rolling round shapes keep rolling (ROADMAP 17.19).

Before the fix a sphere launched along the ground entered rolling at 5/7 of
its launch speed (correct) and then kept losing speed (v0 = 3, mu = 0.5:
1.80 m/s at 1.5 s, 1.57 at 4 s) and sank about 7 mm: its body-frame contact
anchor turned with the ball every substep, so friction acted ahead of the
true contact point. Round-shape anchors are now a body-frame core point plus
a world-frame offset (`physics.contact6.ContactConstraint.oa`).

  1. Ordinary: sphere slides, then rolls at 5/7 v0 and holds that speed with
     omega * r == vx and its centre at the radius.
  2. Integration: a capsule rolling sideways about its own axis does the same
     (2/(2 + k) of v0 for its inertia ratio); a resting box tower is untouched
     (the non-round path is the old body-frame anchor bit for bit -- the
     golden output of every other test is the gate for that).
  3. Extreme: high spin, no linear speed (a spinning ball takes off and rolls
     at the analytic speed), and a ball on a box (dynamic-dynamic contact).
"""

from std.math import pi
from harness.runner import Suite
from geometry.quat import Quat
from geometry.vec import Real, Vec3, length
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _ground(mut sc: ContactScene6[QuatBody6]):
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 200, 0.5, 200)),
        Vec3(200, 0.5, 200, 0),
        True,
    )


def _sphere_run(vx0: Real, wz0: Real, mu: Real, frames: Int) -> Tuple[Real, Real, Real]:
    """Sphere r = 0.5, m = 1 on the ground; returns (vx, omega_z * r, y)."""
    var sc = ContactScene6[QuatBody6]()
    _ground(sc)
    var b = QuatBody6.at_rest(Vec3(0, 0.5, 0, 0), Inertia3.sphere(1, 0.5))
    b.vel = Vec3(vx0, 0, 0, 0)
    b.omega = Vec3(0, 0, wz0, 0)
    var id = sc.add_sphere(b^, 0.5, False)
    try:
        sc.set_can_sleep(id, False)
    except:
        pass
    for _ in range(frames):
        sc.step_soft(DT, G, mu=mu)
    ref s = sc.bset.bodies[1]
    return (s.linear_velocity()[0], -s.omega[2] * 0.5, s.position()[1])


def _capsule_run(v0: Real, frames: Int) -> Tuple[Real, Real, Real]:
    """Capsule r = 0.3, half-length 0.6, m = 1 lying along z (local y -> z),
    launched along x: it rolls about its own axis. Returns (vx, omega_z * r, y)."""
    var sc = ContactScene6[QuatBody6]()
    _ground(sc)
    var b = QuatBody6.at_rest(Vec3(0, 0.3, 0, 0), Inertia3.capsule(1, 0.3, 0.6))
    b.q = Quat.from_axis_angle(Vec3(1, 0, 0, 0), pi / 2)
    b.vel = Vec3(v0, 0, 0, 0)
    var id = sc.add_capsule(b^, 0.3, 0.6, False)
    try:
        sc.set_can_sleep(id, False)
    except:
        pass
    for _ in range(frames):
        sc.step_soft(DT, G, mu=0.5)
    ref c = sc.bset.bodies[1]
    return (c.linear_velocity()[0], -c.omega[2] * 0.3, c.position()[1])


def _ball_on_box(frames: Int) -> Tuple[Real, Real, Real]:
    """Ball r = 0.5 launched at 3 m/s along the top of a heavy dynamic slab
    (m = 1000, top face y = 0.4) resting on the ground: dynamic-dynamic
    round contact. Returns (ball vx - slab vx, omega_z * r, ball y)."""
    var sc = ContactScene6[QuatBody6]()
    _ground(sc)
    var slab = QuatBody6.at_rest(Vec3(0, 0.2, 0, 0), Inertia3.box(1000, 20, 0.2, 20))
    var sid = sc.add(slab^, Vec3(20, 0.2, 20, 0), False)
    var b = QuatBody6.at_rest(Vec3(0, 0.9, 0, 0), Inertia3.sphere(1, 0.5))
    b.vel = Vec3(3, 0, 0, 0)
    var id = sc.add_sphere(b^, 0.5, False)
    try:
        sc.set_can_sleep(id, False)
        sc.set_can_sleep(sid, False)
    except:
        pass
    for _ in range(frames):
        sc.step_soft(DT, G, mu=0.5)
    ref s = sc.bset.bodies[1]
    ref ball = sc.bset.bodies[2]
    return (
        ball.linear_velocity()[0] - s.linear_velocity()[0],
        -ball.omega[2] * 0.5,
        ball.position()[1] - s.position()[1],
    )


def main() raises:
    var s = Suite("rolling_sphere")

    # ---- 1. sphere: 5/7 v0 and it stays there ---------------------------
    var v0 = Real(3)
    var want = v0 * 5.0 / 7.0
    var r90 = _sphere_run(v0, 0, 0.5, 90)
    var r240 = _sphere_run(v0, 0, 0.5, 240)
    print("  sphere v0=3 mu=0.5: vx(1.5 s) =", r90[0], " vx(4 s) =", r240[0],
          " omega*r(4 s) =", r240[1], " y(4 s) =", r240[2])
    s.almost(Float64(r90[0]), Float64(want), "vx at 1.5 s == 5/7 v0", 0.02)
    s.almost(Float64(r240[0]), Float64(want), "vx at 4 s == 5/7 v0 (no rolling drag)", 0.02)
    s.almost(Float64(r240[1]), Float64(r240[0]), "omega*r == vx (pure roll)", 0.01)
    s.almost(Float64(r240[2]), 0.5, "centre stays at the radius (no sinking)", 1e-3)

    # ---- 2. capsule rolling about its own axis -------------------------
    var ci = Inertia3.capsule(1, 0.3, 0.6)
    var k = ci.iy / (1 * 0.3 * 0.3)  # I_axis / (m r^2)
    var cwant = v0 / (1 + k)
    var cap = _capsule_run(v0, 240)
    print("  capsule: vx =", cap[0], " want", cwant, " omega*r =", cap[1], " y =", cap[2])
    s.almost(Float64(cap[0]), Float64(cwant), "capsule rolls at v0 / (1 + I/(m r^2))", 0.02)
    s.almost(Float64(cap[1]), Float64(cap[0]), "capsule omega*r == vx", 0.01)
    s.almost(Float64(cap[2]), 0.3, "capsule axis stays at the radius", 1e-3)

    # ---- 3. extremes: spin only; spin-up from rest ---------------------
    # A ball spinning backspin-free at omega0 with v = 0: friction trades spin
    # for speed until vx = omega*r = 2/7 * omega0 * r.
    var sp = _sphere_run(0, -8, 0.5, 240)
    print("  spin-only: vx =", sp[0], " omega*r =", sp[1])
    s.almost(Float64(sp[0]), Float64(2.0 / 7.0 * 8 * 0.5), "spin-only ball rolls at 2/7 omega0 r", 0.02)
    s.almost(Float64(sp[1]), Float64(sp[0]), "spin-only ball ends in pure roll", 0.01)

    var bb = _ball_on_box(240)
    print("  ball on dynamic slab: relative vx =", bb[0], " omega*r =", bb[1], " height above slab centre =", bb[2])
    s.almost(Float64(bb[1]), Float64(bb[0]), "ball on dynamic slab: pure roll relative to the slab", 0.01)
    s.almost(Float64(bb[2]), 0.7, "ball on dynamic slab: no sinking (0.2 + r)", 1e-3)

    s.finish()
