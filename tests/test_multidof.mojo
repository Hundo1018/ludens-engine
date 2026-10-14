# tier: integration
"""Universal and planar joints in reduced coordinates (ROADMAP 17.51).

  1. Ordinary: a rod hung from a universal joint (axes x then z) swinging
     in the x-y plane follows the ball-jointed rod's trajectory (the same
     motion through the same z rotation; tips within 1e-4 m over 2 s);
     swinging about both pins without gravity, the parent's x pin stays
     perpendicular to the body's z pin (the cross).
  2. Integration: a body on a planar joint (plane x-y, rotation about z)
     under gravity (1, -9.8, 2): accelerates at 1 and -9.8 m/s^2 in the
     plane, does not move along z, and keeps its 1.5 rad/s spin.
  2b. Free joint (`add_free`: three prismatics + a ball) as the root of a
     4 kg base carrying a 3-link arm, against `FloatingChain` (the 6-DOF
     base it replaces): same initial base motion and joint torques, the arm
     tips agree within 1 cm over 1 s and the gap shrinks with dt.
  3. Extreme: non-perpendicular axes and mass 0 raise.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length, dot
from std.math import sin
from geometry.quat import Quat
from physics.chain import Chain, ChainLink
from physics.floating import FloatingChain

comptime DT: Real = 1.0 / 240.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ZERO = Vec3(0, 0, 0, 0)
comptime ROD_I = Vec3(1.0 / 12.0, 1e-3, 1.0 / 12.0, 0)


def _arm(i: Int) -> ChainLink:
    return ChainLink.revolute(
        Vec3(0, 0, 1, 0) if i % 2 == 0 else Vec3(0, 1, 0, 0),
        Vec3(0.5, 0.1, 0, 0), Vec3(0.25, 0, 0, 0), 0.8 + Real(i) * 0.1, Vec3(0.02, 0.03, 0.025, 0),
    )


def _free_vs_floating(dt: Real) raises -> Real:
    var bw = Vec3(0.3, -0.2, 0.45, 0)
    var bv = Vec3(0.1, 0.25, -0.15, 0)
    var f = FloatingChain(4.0, Vec3(0.05, -0.02, 0.01, 0), Vec3(0.3, 0.4, 0.35, 0))
    var c = Chain()
    var fb = c.add_free(-1, ZERO, Vec3(0.05, -0.02, 0.01, 0), 4.0, Vec3(0.3, 0.4, 0.35, 0))
    var prev = fb
    for i in range(3):
        f.add_link(_arm(i))
        prev = c.add_link_to(prev, _arm(i))
    f.base_w = bw
    f.base_v = bv
    c.qd[0] = bv[0]  # base_rot is identity: body-frame = world velocity
    c.qd[1] = bv[1]
    c.qd[2] = bv[2]
    c.qd[3] = bw[0]
    c.qd[4] = bw[1]
    c.qd[5] = bw[2]
    for i in range(3):
        f.chain.q[i] = 0.2 + Real(i) * 0.1
        f.chain.qd[i] = 0.4 - Real(i) * 0.15
        c.q[6 + i] = f.chain.q[i]
        c.qd[6 + i] = f.chain.qd[i]
    var worst = Real(0)
    for k in range(Int(Real(1) / dt + 0.5)):
        var tf = List[Real](length=3, fill=0)
        var tc = List[Real](length=9, fill=0)
        for i in range(3):
            var t = Real(0.6) * Real(sin(Float64(k) * Float64(dt) * 3 + Float64(i)))
            tf[i] = t
            tc[6 + i] = t
        f.step(dt, tf, G)
        c.step(dt, tc, G)
        var tip_f = f.fk()[2].apply_point(Vec3(0.5, 0, 0, 0))
        var tip_c = c.fk()[prev].apply_point(Vec3(0.5, 0, 0, 0))
        worst = max(worst, length(tip_f - tip_c))
    return worst


def main() raises:
    var s = Suite("multidof")

    # ---- universal vs ball, planar swing ----------------------------------------------------------------
    var u = Chain()
    var ub = u.add_universal(-1, ZERO, Vec3(1, 0, 0, 0), Vec3(0, 0, 1, 0), Vec3(0, -0.5, 0, 0), 1, ROD_I)
    var b = Chain()
    var bb = b.add_ball(-1, ZERO, Vec3(0, -0.5, 0, 0), 1, ROD_I)
    u.qd[1] = 1.2  # about z
    b.qd[2] = 1.2
    var zu = List[Real](length=2, fill=0)
    var zb = List[Real](length=3, fill=0)
    var worst = Real(0)
    for _ in range(480):
        u.step(DT, zu, G)
        b.step(DT, zb, G)
        worst = max(worst, length(u.point_world(ub, Vec3(0, -1, 0, 0)) - b.point_world(bb, Vec3(0, -1, 0, 0))))
    print("  universal vs ball, swing about z, 2 s: max tip distance", worst)
    s.check(worst < 1e-4, "a universal joint swinging in a plane follows the ball joint")

    # ---- universal: the cross keeps its two pins perpendicular -----------------------------------------------
    var us = Chain()
    var usb = us.add_universal(-1, ZERO, Vec3(1, 0, 0, 0), Vec3(0, 0, 1, 0), Vec3(0, -0.5, 0, 0), 1, ROD_I)
    us.qd[0] = 1.0
    us.qd[1] = 0.7
    var perp = Real(0)
    for _ in range(480):
        us.step(DT, zu, ZERO)
        var qt = us.fk()[usb].to_quat_translation()
        perp = max(perp, abs(dot(Vec3(1, 0, 0, 0), qt[0].rotate(Vec3(0, 0, 1, 0)))))
    print("  universal, swinging about x and z without gravity, 2 s: max |parent x . body z|", perp)
    s.check(perp < 1e-5, "the universal joint's pins stay perpendicular (parent x . body z = 0)")

    # ---- planar -------------------------------------------------------------------------------------------------
    var pl = Chain()
    var pb = pl.add_planar(-1, ZERO, Vec3(1, 0, 0, 0), Vec3(0, 1, 0, 0), ZERO, 2, Vec3(0.1, 0.1, 0.1, 0))
    pl.qd[2] = 1.5
    var g3 = Vec3(1, -9.8, 2, 0)
    var z3 = List[Real](length=3, fill=0)
    for _ in range(240):
        pl.step(DT, z3, g3)
    var p = pl.point_world(pb, ZERO)
    print("  planar joint under gravity (1, -9.8, 2), 1 s: v", pl.qd[0], pl.qd[1], " z", p[2], " spin", pl.qd[2])
    s.check(abs(pl.qd[0] - 1) < 1e-4 and abs(pl.qd[1] + 9.8) < 1e-3 and abs(p[2]) < 1e-6 and abs(pl.qd[2] - 1.5) < 1e-5, "planar: in-plane accelerations 1 and -9.8, no motion along z, spin kept")

    # ---- free joint vs FloatingChain ------------------------------------------------------------------------------
    var g1 = _free_vs_floating(1.0 / 240.0)
    var g2 = _free_vs_floating(1.0 / 480.0)
    print("  free joint vs FloatingChain, 4 kg base + 3-link arm, 1 s: max tip distance", g1, "(dt 1/240)", g2, "(dt 1/480)")
    s.check(g1 < 0.01 and g2 < g1, "free-joint chain follows FloatingChain within 1 cm; the gap shrinks with dt")

    # ---- extremes -------------------------------------------------------------------------------------------------
    var raised = 0
    var c = Chain()
    try:
        _ = c.add_universal(-1, ZERO, Vec3(1, 0, 0, 0), Vec3(1, 1, 0, 0), ZERO, 1, ROD_I)
    except:
        raised += 1
    try:
        _ = c.add_planar(-1, ZERO, Vec3(1, 0, 0, 0), Vec3(0, 1, 0, 0), ZERO, 0, ROD_I)
    except:
        raised += 1
    s.check(raised == 2, "non-perpendicular axes and mass 0 raise")
    s.finish()
