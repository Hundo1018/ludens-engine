# tier: integration
"""Combat physics (ROADMAP 17.71).

  1. Ordinary: a blade swinging 0.05 rad per tick hits a 2 cm shield on its
     arc in all three detection modes (parity); hitscan returns the nearest
     hurtbox and its bone; a projectile with linear drag lands where the
     closed-form trajectory says (relative error <= 1e-3); quadratic drag
     lands within 1e-3 of a 100x finer RK4 reference; an explosion pushes an
     exposed crate away.
  2. Integration: at 1.2 rad per tick (72 m/s at the tip) the discrete test
     misses the shield, the endpoint-linear sweep misses it too (the chord
     of the arc passes inside), the arc sweep hits; one swing hits each
     owner once even through two of its hurtboxes; teammates are skipped; a
     crate behind a wall is not pushed; a half-hidden crate spins; a sleeping
     crate is woken; a 300 m/s round does not pass a 2 cm wall.
  3. Extreme: 150 spawns into a 100-slot pool drop 50 (counted); a zero-length
     ray finds nothing; a crate centred on the blast is pushed up, finite;
     hit-stop freezes for exactly the given ticks.
"""

from std.math import exp, sqrt, cos, sin, isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from gameplay.combat import Hurtbox, Swing, hitscan, HitStop, DETECT_DISCRETE, DETECT_LINEAR, DETECT_ARC
from gameplay.projectile import ProjectileSet, DRAG_LINEAR, DRAG_QUADRATIC
from gameplay.explosion import explode

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _shield(phi: Real, owner: Int = 7, bone: Int = 3) -> Hurtbox:
    var c = Vec3(0.9 * cos(phi), 0, -0.9 * sin(phi), 0)
    return Hurtbox(owner, bone, 1, 1.0, c - Vec3(0, 0.2, 0, 0), c + Vec3(0, 0.2, 0, 0), 0.01)


def _swing_hits(mode: Int, dtheta: Real, boxes: List[Hurtbox]) -> Int:
    var sw = Swing(0, 0.2, 1.0, 0.01, mode, 0.01)
    var axis = Vec3(0, 1, 0, 0)
    sw.begin(Vec3(0, 0, 0, 0), Quat.from_axis_angle(axis, 0))
    var n = 0
    var th = Real(0)
    while th < 1.5:
        th += dtheta
        var h = sw.step(Vec3(0, 0, 0, 0), Quat.from_axis_angle(axis, th), boxes)
        n += len(h)
    return n


def _land_x(ps: ProjectileSet, v0: Vec3, dt: Real) -> Real:
    """Free-flight x where y crosses 0 (no scene), stepping `dt`."""
    var p = Vec3(0, 0, 0, 0)
    var v = v0
    while True:
        var nx = ps.advance_state(p, v, G, dt)
        if nx[0][1] < 0 and nx[1][1] < 0:
            var u = p[1] / (p[1] - nx[0][1])
            return p[0] + (nx[0][0] - p[0]) * u
        p = nx[0]
        v = nx[1]


def main() raises:
    var s = Suite("combat")

    # ---- melee detection ----------------------------------------------------------
    var boxes: List[Hurtbox] = [_shield(0.6)]
    var slow = List[Int]()
    var fast = List[Int]()
    for mode in [DETECT_DISCRETE, DETECT_LINEAR, DETECT_ARC]:
        slow.append(_swing_hits(mode, 0.05, boxes))
        fast.append(_swing_hits(mode, 1.2, boxes))
    print("  2 cm shield at 0.6 rad: slow swing hits (discrete, linear, arc)", slow[0], slow[1], slow[2], "  fast (72 m/s tip)", fast[0], fast[1], fast[2])
    s.check(slow[0] == 1 and slow[1] == 1 and slow[2] == 1, "slow swing: all three modes hit once (parity)")
    s.check(fast[0] == 0 and fast[1] == 0 and fast[2] == 1, "fast swing: discrete and chord sweeps miss, the arc sweep hits")
    var two: List[Hurtbox] = [_shield(0.6, 7, 3), _shield(0.9, 7, 4), _shield(1.2, 8, 0)]
    s.check(_swing_hits(DETECT_ARC, 0.05, two) == 2, "one swing hits each owner once (owner 7 twice in the way, owner 8 once)")
    var mates: List[Hurtbox] = [Hurtbox(5, 0, 0, 1.0, Vec3(0.6, -0.2, -0.5, 0), Vec3(0.6, 0.2, -0.5, 0), 0.05)]
    s.check(_swing_hits(DETECT_ARC, 0.05, mates) == 0, "teammates are skipped")

    # ---- hitscan -------------------------------------------------------------------------
    var body: List[Hurtbox] = [
        Hurtbox(1, 0, 1, 1.0, Vec3(5, 0, 0, 0), Vec3(5, 1, 0, 0), 0.2),
        Hurtbox(1, 9, 1, 2.0, Vec3(4, 1.5, 0, 0), Vec3(4, 1.7, 0, 0), 0.15),
    ]
    var hs = hitscan(Vec3(0, 1.6, 0, 0), Vec3(1, 0, 0, 0), 100, body, 0)
    var hs2 = hitscan(Vec3(0, 0.5, 0, 0), Vec3(1, 0, 0, 0), 100, body, 0)
    var hs0 = hitscan(Vec3(0, 0.5, 0, 0), Vec3(0, 0, 0, 0), 100, body, 0)
    print("  hitscan: head ray -> box", hs[0], "t", hs[1], "  torso ray -> box", hs2[0], "t", hs2[1])
    s.check(hs[0] == 1 and abs(hs[1] - 3.85) < 1e-4 and body[hs[0]].bone == 9 and hs2[0] == 0 and abs(hs2[1] - 4.8) < 1e-4, "hitscan: nearest hurtbox, its bone and distance")
    s.check(hs0[0] == -1, "zero-length ray: nothing")

    # ---- projectiles ---------------------------------------------------------------------
    var lin = ProjectileSet(4, DRAG_LINEAR, 0.5)
    var v0 = Vec3(20, 20, 0, 0)
    # closed form: x(t) = (v0 - vt)(1 - e^-kt)/k + vt t, vt = g / k
    var k = Real(0.5)
    var lo = Real(0.1)
    var hi = Real(10)
    for _ in range(80):
        var t = (lo + hi) / 2
        var y = (v0[1] - (-9.8 / k)) * (1 - exp(-k * t)) / k + (-9.8 / k) * t
        if y > 0:
            lo = t
        else:
            hi = t
    var tl = (lo + hi) / 2
    var x_exact = v0[0] * (1 - exp(-k * tl)) / k
    var x_sim = _land_x(lin, v0, DT)
    print("  linear drag landing x: closed form", x_exact, " stepped", x_sim)
    s.check(abs(x_sim - x_exact) / x_exact < 1e-3, "linear drag: landing within 1e-3 of the closed form")
    var quad = ProjectileSet(4, DRAG_QUADRATIC, 0.02)
    var xq = _land_x(quad, v0, DT)
    var xr = _land_x(quad, v0, DT / 100)
    print("  quadratic drag landing x: 1/60 s RK4", xq, " 100x finer", xr)
    s.check(abs(xq - xr) / xr < 1e-3, "quadratic drag: RK4 at 1/60 s within 1e-3 of a 100x finer reference")

    var sw = ContactScene6[QuatBody6]()
    _ = sw.add(QuatBody6.at_rest(Vec3(10, 1, 0, 0), Inertia3.box(1, 0.01, 2, 2)), Vec3(0.01, 2, 2, 0), True)
    var bullets = ProjectileSet(4)
    _ = bullets.spawn(Vec3(0, 1, 0, 0), Vec3(300, 0, 0, 0))
    var got = 0
    for _ in range(10):
        got += len(bullets.step(sw, DT, Vec3(0, 0, 0, 0)))
    s.check(got == 1 and bullets.live() == 0, "a 300 m/s round stops at a 2 cm wall (segment rays)")
    var pool = ProjectileSet(100)
    for i in range(150):
        _ = pool.spawn(Vec3(Real(i), 0, 0, 0), Vec3(0, 1, 0, 0))
    print("  pool of 100, 150 spawns: live", pool.live(), " dropped", pool.dropped)
    s.check(pool.live() == 100 and pool.dropped == 50, "full pool drops the newest and counts them")

    # ---- explosion -------------------------------------------------------------------------
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    var a = sc.add(QuatBody6.at_rest(Vec3(2, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    _ = sc.add(QuatBody6.at_rest(Vec3(-1.5, 1, 0, 0), Inertia3.box(1, 0.1, 1, 1)), Vec3(0.1, 1, 1, 0), True)  # wall
    var b = sc.add(QuatBody6.at_rest(Vec3(-2.5, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    _ = sc.add(QuatBody6.at_rest(Vec3(0, 0.5, 1.5, 0), Inertia3.box(1, 0.5, 0.5, 0.05)), Vec3(0.5, 0.5, 0.05, 0), True)  # short wall
    var c = sc.add(QuatBody6.at_rest(Vec3(0.6, 0.25, 2.5, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    for _ in range(120):  # settle and fall asleep
        sc.step_soft(DT, G)
    var asleep = sc.bset.sleeping[a.index()]
    var rep = explode(sc, Vec3(0, 0.3, 0, 0), 5, 20, 9)
    var exp_a = Real(-1)
    var exp_b = Real(-1)
    var exp_c = Real(-1)
    for k2 in range(len(rep.bodies)):
        if rep.bodies[k2] == a.index():
            exp_a = rep.exposure[k2]
        elif rep.bodies[k2] == b.index():
            exp_b = rep.exposure[k2]
        elif rep.bodies[k2] == c.index():
            exp_c = rep.exposure[k2]
    var va = sc.velocity(a)
    var wc = sc.angular_velocity(c)
    print("  explosion: exposure open / walled / half", exp_a, exp_b, exp_c, "  open crate vx", va[0], " half-hidden |w|", length(wc), " was asleep", asleep)
    s.check(exp_a == 1 and va[0] > 1, "an exposed crate is pushed away")
    s.check(exp_b < 0, "a crate behind a wall is not pushed")
    s.check(exp_c > 0 and exp_c < 1 and length(wc) > 0.1, "a half-hidden crate is pushed off-centre and spins")
    s.check(asleep and not sc.bset.sleeping[a.index()], "the blast wakes a sleeping crate")
    var sd = ContactScene6[QuatBody6]()
    var dd = sd.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    _ = explode(sd, Vec3(0, 0, 0, 0), 3, 10, 1)
    var vd = sd.velocity(dd)
    s.check(isfinite(vd[1]) and vd[1] > 0 and abs(vd[0]) < 1e-6, "blast centred on a crate pushes it up, finite")

    # ---- hit-stop ---------------------------------------------------------------------------
    var stop = HitStop(4)
    stop.freeze(2, 3)
    var frozen = 0
    for _ in range(6):
        if stop.scale(2) == 0:
            frozen += 1
        stop.tick()
    s.check(frozen == 3 and stop.scale(1) == 1, "hit-stop freezes for exactly 3 ticks, others unaffected")
    s.finish()
