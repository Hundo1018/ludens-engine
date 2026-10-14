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
  3. Extreme: non-perpendicular axes and mass 0 raise.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length, dot
from physics.chain import Chain

comptime DT: Real = 1.0 / 240.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ZERO = Vec3(0, 0, 0, 0)
comptime ROD_I = Vec3(1.0 / 12.0, 1e-3, 1.0 / 12.0, 0)


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
