from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.softbody import SoftBody

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)


def _d(v: Vec3) -> Float64:
    return Float64(sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]))


def _min_gap_sphere(
    sc: ContactScene6[QuatBody6], cen: Vec3, rad: Real, r: Real
) -> Float64:
    """Smallest particle-surface clearance (negative = penetration)."""
    var mn = Float64(1e30)
    for i in range(len(sc.softs[0].pts)):
        var g = _d(sc.softs[0].pts[i].x - cen) - Float64(rad + r)
        if g < mn:
            mn = g
    return mn


def _min_gap_capsule(
    sc: ContactScene6[QuatBody6], cen: Vec3, hl: Real, rad: Real, r: Real
) -> Float64:
    """Same but against a vertical capsule's axis segment."""
    var mn = Float64(1e30)
    for i in range(len(sc.softs[0].pts)):
        var p = sc.softs[0].pts[i].x
        var ty = Float64(p[1] - cen[1])
        if ty > Float64(hl):
            ty = Float64(hl)
        if ty < -Float64(hl):
            ty = -Float64(hl)
        var cp = cen + Vec3(0, Real(ty), 0)
        var g = _d(p - cp) - Float64(rad + r)
        if g < mn:
            mn = g
    return mn


def _bullet(
    kind: Int, ccd: Bool
) raises -> Vec3:
    """A tight 8-particle pellet fired at 200 m/s dead-centre at a static
    sphere (kind 1) or vertical capsule (kind 2) of radius 0.3: per-substep
    travel (0.83 m) exceeds the inflated crossing (0.7 m), and the start
    offset is phased so the discrete test misses at EVERY sampling point.
    Returns (max particle x, min distance to the shape axis) after 5
    frames — with friction the pellet may legitimately grip and wrap AROUND
    to the far surface, so the gates are "stays in the shape's vicinity and
    never inside the surface", not "stays on the approach side"."""
    var sc = ContactScene6[QuatBody6]()
    if kind == 1:
        _ = sc.add_sphere(
            QuatBody6.at_rest(Vec3(0, 0, 0), Inertia3.sphere(1, 0.3)),
            0.3,
            True,
        )
    else:
        _ = sc.add_capsule(
            QuatBody6.at_rest(Vec3(0, -0.3, 0), Inertia3.capsule(1, 0.3, 0.5)),
            0.3,
            0.5,
            True,
        )
    var sb = SoftBody.box_lattice(
        Vec3(-2.1, 0.2, 0), Vec3(0.05, 0.05, 0.05), 2, 0.5, 1e-5
    )
    for i in range(len(sb.pts)):
        var p = sb.pts[i]
        p.v = Vec3(200, 0, 0)
        sb.pts[i] = p
    _ = sc.add_soft(sb^)
    for _ in range(5):
        sc.step_soft(DT, G, ccd=ccd)
    var mx = Float64(-1e30)
    var mind = Float64(1e30)
    for i in range(len(sc.softs[0].pts)):
        var p = sc.softs[0].pts[i].x
        var x = Float64(p[0])
        if x > mx:
            mx = x
        # distance to the shape surface centre-line (sphere centre at the
        # origin; capsule axis x=z=0, y in [-0.8, 0.2])
        var ty = Float64(p[1])
        if kind == 2:
            if ty > 0.2:
                ty = 0.2
            if ty < -0.8:
                ty = -0.8
        else:
            ty = 0
        var d = _d(p - Vec3(0, Real(ty), 0))
        if d < mind:
            mind = d
    return Vec3(Real(mx), Real(mind), 0)


def main() raises:
    var s = Suite("softcouple")

    # 1. Drape: soft cube spawned at rest atop a static sphere bump poking 0.08 above
    #    the floor: the cube lies flat, dented by the dome — never
    #    penetrates it, and the dent proves the coupling engaged.
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10),
        True,
    )
    _ = sc.add_sphere(
        QuatBody6.at_rest(Vec3(0, -0.22, 0), Inertia3.sphere(1, 0.3)), 0.3, True
    )
    var sb = SoftBody.box_lattice(
        Vec3(0, 0.35, 0), Vec3(0.3, 0.3, 0.3), 4, 2.0, 1e-4
    )
    _ = sc.add_soft(sb^)
    var r = sc.softs[0].radius
    var gap = Float64(1e30)
    for _ in range(400):
        sc.step_soft(DT, G)
        var g = _min_gap_sphere(sc, Vec3(0, -0.22, 0), 0.3, r)
        if g < gap:
            gap = g
    var top = Float64(sc.softs[0].top_y())
    var mean_x = Float64(0)
    for i in range(len(sc.softs[0].pts)):
        mean_x += Float64(sc.softs[0].pts[i].x[0])
    mean_x /= Float64(len(sc.softs[0].pts))
    print("  sphere drape: min gap", gap, "cube top", top, "mean x", mean_x)
    s.check(gap > -0.01, "no particle ever penetrates the sphere")
    # particle-vs-shape contacts are frictionless (radial pushout only), so
    # the bump is an unstable equilibrium: the cube slides to its rim and
    # stops — correct for the current model. Gate: stays nearby, no blow-up.
    s.check(abs(mean_x) < 1.0, "cube slides at most to the bump rim")
    s.check(gap < 0.01, "contact really engaged (gap closed to the surface)")
    s.check(top > 0.6, "cube settles at a sane height")

    # 2. Same drape over a buried vertical static capsule (dome pokes
    #    0.08 above the floor).
    var cc = ContactScene6[QuatBody6]()
    _ = cc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10),
        True,
    )
    _ = cc.add_capsule(
        QuatBody6.at_rest(Vec3(0, -0.62, 0), Inertia3.capsule(1, 0.3, 0.4)),
        0.3,
        0.4,
        True,
    )
    var cb = SoftBody.box_lattice(
        Vec3(0, 0.35, 0), Vec3(0.3, 0.3, 0.3), 4, 2.0, 1e-4
    )
    _ = cc.add_soft(cb^)
    var cgap = Float64(1e30)
    for _ in range(400):
        cc.step_soft(DT, G)
        var g2 = _min_gap_capsule(cc, Vec3(0, -0.62, 0), 0.4, 0.3, r)
        if g2 < cgap:
            cgap = g2
    var cmx = Float64(0)
    for i in range(len(cc.softs[0].pts)):
        cmx += Float64(cc.softs[0].pts[i].x[0])
    cmx /= Float64(len(cc.softs[0].pts))
    print("  capsule drape: min gap", cgap, "mean x", cmx)
    s.check(cgap > -0.01, "no particle ever penetrates the capsule")
    s.check(abs(cmx) < 1.0, "cube slides at most to the dome rim")
    s.check(cgap < 0.01, "capsule contact really engaged")

    # 3. Zero-g momentum: moving soft cube hits a free sphere — coupling
    #    impulses must conserve linear momentum.
    var mz = ContactScene6[QuatBody6]()
    var ball = mz.add_sphere(
        QuatBody6.at_rest(Vec3(0.15, 0, 0), Inertia3.sphere(2, 0.3)), 0.3, False
    )
    var mb = SoftBody.box_lattice(
        Vec3(-0.85, 0, 0), Vec3(0.3, 0.3, 0.3), 4, 2.0, 1e-4
    )
    mb.damp = 1.0
    for i in range(len(mb.pts)):
        var p = mb.pts[i]
        p.v = Vec3(1, 0, 0)
        mb.pts[i] = p
    _ = mz.add_soft(mb^)
    for _ in range(300):
        mz.step_soft(DT, Vec3(0, 0, 0))
    var px = Float64(mz.bodies[ball].vel[0]) * 2.0
    for i in range(len(mz.softs[0].pts)):
        var p = mz.softs[0].pts[i]
        px += Float64(p.v[0]) / Float64(p.w)
    print("  momentum: total px", px, "sphere vx", Float64(mz.bodies[ball].vel[0]))
    s.check(abs(px - 2.0) < 0.01, "linear momentum conserved through coupling")
    s.check(Float64(mz.bodies[ball].vel[0]) > 0.2, "sphere really got pushed")

    # 4. CCD vs sphere: the phased pellet tunnels without ccd, is caught
    #    with it.
    var thru = _bullet(1, False)
    var caught = _bullet(1, True)
    print(
        "  sphere bullet: no-ccd max x", Float64(thru[0]),
        "ccd max x", Float64(caught[0]), "min dist", Float64(caught[1]),
    )
    s.check(thru[0] > 1.0, "without ccd the pellet skips the sphere (bites)")
    s.check(caught[0] < 0.5, "ccd keeps the pellet at the sphere")
    s.check(caught[1] > 0.315, "no particle ends inside the sphere")

    # 5. CCD vs capsule (closest-point sphere approximation).
    var cthru = _bullet(2, False)
    var ccaught = _bullet(2, True)
    print(
        "  capsule bullet: no-ccd max x", Float64(cthru[0]),
        "ccd max x", Float64(ccaught[0]), "min dist", Float64(ccaught[1]),
    )
    s.check(cthru[0] > 1.0, "without ccd the pellet skips the capsule (bites)")
    s.check(ccaught[0] < 0.5, "ccd keeps the pellet at the capsule")
    s.check(ccaught[1] > 0.315, "no particle ends inside the capsule")

    s.finish()
