# tier: integration
"""Projectile penetration, ricochet, homing, proximity fuse and lead aim
(ROADMAP 17.71, `gameplay.projectile`).

  1. Ordinary: a 300 m/s round with 0.3 m of penetration goes through a
     0.1 m wall (resistance 1), leaving at 300 x sqrt(0.2 / 0.3) = 244.95
     m/s, and stops in the next 0.1 m wall of resistance 3 (cost 0.3 > 0.2
     left). A 10-degree graze off the floor ricochets (ricochet angle 15):
     the normal component flips, the speed is x 0.6; a 45-degree shot
     stops.
  2. Integration: a homing round (turn rate 3 rad/s) fired at right angles
     to a target hits it; the same round without homing misses. A round
     passing 1 m from a fuse target (fuse radius 1.5) detonates at the
     closest approach before reaching the wall behind. `lead_direction`
     against a target crossing at 5 m/s: a 50 m/s straight shot meets it
     (closest approach printed); a target faster than the shot gets zero.
  3. Extreme: a resistance <= 0 or negative body, a bad homing index raise;
     a 1 m wall is not penetrated; ricochet off (0 degrees) stops a graze.
"""

from std.math import sqrt, sin, cos
from harness.runner import Suite
from geometry.vec import Real, Vec3, dot, length
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from gameplay.projectile import (
    ProjectileSet, ProjectileHit, lead_direction, HIT_STOP, HIT_PENETRATE, HIT_RICOCHET, HIT_FUSE,
)

comptime DT: Real = 1.0 / 60.0
comptime ZERO = Vec3(0, 0, 0, 0)


def _wall(mut sc: ContactScene6[QuatBody6], x: Real, half_x: Real) raises -> Int:
    return sc.add(QuatBody6.at_rest(Vec3(x, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(half_x, 3, 3, 0), True).index()


def _fly(mut ps: ProjectileSet, mut sc: ContactScene6[QuatBody6], ticks: Int, g: Vec3) raises -> List[ProjectileHit]:
    var all = List[ProjectileHit]()
    for _ in range(ticks):
        var h = ps.step(sc, DT, g)
        for x in h:
            all.append(x)
    return all^


def _graze(deg: Real, ric: Real) raises -> List[ProjectileHit]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 50, 1, 50)), Vec3(50, 1, 50, 0), True)
    var ps = ProjectileSet(4)
    ps.ricochet_deg = ric
    var a = deg * 0.017453292519943295
    _ = ps.spawn(Vec3(0, 1, 0, 0), Vec3(cos(a), -sin(a), 0, 0) * 50)
    return _fly(ps, sc, 30, ZERO)


def main() raises:
    var s = Suite("projectile_pen")

    # ---- penetration ---------------------------------------------------------------------------------
    var sc = ContactScene6[QuatBody6]()
    var w1 = _wall(sc, 5, 0.05)
    var w2 = _wall(sc, 10, 0.05)
    var ps = ProjectileSet(4)
    ps.penetration = 0.3
    ps.set_resistance(w2, 3)
    _ = ps.spawn(Vec3(0, 0, 0, 0), Vec3(300, 0, 0, 0))
    var hits = _fly(ps, sc, 10, ZERO)
    var v_after = ps.vel[0][0] if len(hits) > 0 else Real(0)
    print("  hits", len(hits), ": kind", hits[0].kind, "body", hits[0].body, "at x", hits[0].point[0], " then kind", hits[1].kind, "body", hits[1].body, "at x", hits[1].point[0], "after", hits[1].travelled, "m;  speed after wall 1", hits[1].velocity[0])
    s.check(len(hits) == 2 and hits[0].kind == HIT_PENETRATE and hits[0].body == w1 and hits[1].kind == HIT_STOP and hits[1].body == w2, "through the 0.1 m wall, stopped by the resistance-3 wall")
    s.check(abs(hits[1].velocity[0] - 244.949) < 0.05 and abs(hits[0].point[0] - 4.95) < 1e-3 and abs(hits[1].point[0] - 9.95) < 1e-3 and abs(hits[1].travelled - 9.95) < 1e-2, "exit speed 300 sqrt(0.2/0.3); entry points and distance flown")
    _ = v_after

    # ---- ricochet -----------------------------------------------------------------------------------
    var g10 = _graze(10, 15)
    var g45 = _graze(45, 15)
    var g10off = _graze(10, 0)
    print("  10 deg graze:", len(g10), "hits, first kind", g10[0].kind, ";  45 deg: kind", g45[0].kind, ";  ricochet off: kind", g10off[0].kind)
    s.check(g10[0].kind == HIT_RICOCHET and g45[0].kind == HIT_STOP and g10off[0].kind == HIT_STOP, "grazing shots ricochet, steep ones stop")
    var sc_r = ContactScene6[QuatBody6]()
    _ = sc_r.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 50, 1, 50)), Vec3(50, 1, 50, 0), True)
    var pr = ProjectileSet(1)
    pr.ricochet_deg = 15
    var a = Real(10) * 0.017453292519943295
    var v0 = Vec3(cos(a), -sin(a), 0, 0) * 50
    _ = pr.spawn(Vec3(0, 1, 0, 0), v0)
    var first = List[ProjectileHit]()
    while len(first) == 0:
        first = pr.step(sc_r, DT, ZERO)
    var vr = pr.vel[0]
    print("  ricochet: in", v0, " out", vr)
    s.check(abs(vr[0] - v0[0] * 0.6) < 1e-3 and abs(vr[1] + v0[1] * 0.6) < 1e-3, "the normal component flips, speed x 0.6")

    # ---- homing ---------------------------------------------------------------------------------------
    var homed = List[Bool]()
    for rate in [Real(0), Real(3)]:
        var sh = ContactScene6[QuatBody6]()
        var tgt = sh.add(QuatBody6.at_rest(Vec3(10, 0, 10, 0), Inertia3.box(1, 1, 1, 1)), Vec3(0.5, 0.5, 0.5, 0), True).index()
        var ph = ProjectileSet(1)
        var i = ph.spawn(Vec3(0, 0, 0, 0), Vec3(20, 0, 0, 0))
        if rate > 0:
            ph.set_homing(i, tgt, rate)
        var got = False
        for _ in range(180):
            for h in ph.step(sh, DT, ZERO):
                if h.body == tgt:
                    got = True
        homed.append(got)
    print("  target at right angles: hit without homing", homed[0], ", with 3 rad/s homing", homed[1])
    s.check(not homed[0] and homed[1], "homing turns the round onto the target")

    # ---- proximity fuse ------------------------------------------------------------------------------
    var sf = ContactScene6[QuatBody6]()
    var ft = sf.add(QuatBody6.at_rest(Vec3(10, 1, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(0.2, 0.2, 0.2, 0), True).index()
    var fw = _wall(sf, 20, 0.5)
    var pf = ProjectileSet(1)
    pf.fuse_radius = 1.5
    pf.fuse_targets.append(ft)
    _ = pf.spawn(Vec3(0, 0, 0, 0), Vec3(100, 0, 0, 0))
    var fh = _fly(pf, sf, 30, ZERO)
    print("  fuse:", len(fh), "hit, kind", fh[0].kind, "body", fh[0].body, "at", fh[0].point)
    s.check(len(fh) == 1 and fh[0].kind == HIT_FUSE and fh[0].body == ft and abs(fh[0].point[0] - 10) < 1e-3 and fw >= 0, "detonates at the closest approach, before the wall")

    # ---- lead -----------------------------------------------------------------------------------------
    var tp = Vec3(20, 0, 0, 0)
    var tv = Vec3(0, 0, 5, 0)
    var d = lead_direction(ZERO, 50, tp, tv)
    var miss = Real(1e9)
    for k in range(2000):
        var t = Real(k) * 0.0005
        miss = min(miss, length(d * (50 * t) - (tp + tv * t)))
    var none = lead_direction(ZERO, 3, tp, tv)
    print("  lead: direction", d, " closest approach", miss, "m;  outrun:", none)
    s.check(miss < 0.02 and length(none) == 0, "the led shot meets the crossing target; an outrunning target gives zero")

    # ---- extremes -------------------------------------------------------------------------------------
    var raised = 0
    var px = ProjectileSet(2)
    try:
        px.set_resistance(0, 0)
    except:
        raised += 1
    try:
        px.set_resistance(-1, 1)
    except:
        raised += 1
    try:
        px.set_homing(5, 0, 1)
    except:
        raised += 1
    s.check(raised == 3, "resistance <= 0, a negative body and a bad homing index raise")
    var st = ContactScene6[QuatBody6]()
    _ = _wall(st, 5, 0.5)
    var pt = ProjectileSet(1)
    pt.penetration = 0.3
    _ = pt.spawn(ZERO, Vec3(300, 0, 0, 0))
    var th = _fly(pt, st, 10, ZERO)
    s.check(len(th) == 1 and th[0].kind == HIT_STOP and pt.live() == 0, "a 1 m wall stops a 0.3 m round")
    s.finish()
