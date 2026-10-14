# tier: integration
"""Reduced-coordinate contact: an articulated body that can touch the world.

Until now the two halves of the engine could not meet — `Chain` integrates in
joint space and `ContactScene6` resolves contacts in maximal coordinates, with
nothing between them. The bridge is the point Jacobian: it maps joint
velocities to the velocity of one material point, and its transpose maps an
impulse there back to joint torques, so a contact can be solved without ever
leaving generalised coordinates.

The Jacobian is checked BEFORE any contact behaviour, and against finite
differences of the forward kinematics, because everything downstream inherits
its errors: an impulse applied through a wrong Jacobian still produces
plausible-looking motion, just of the wrong body.

The structural check is that joints NOT on the path to the contact must have
exactly zero influence. That is the property that makes the reduced
formulation different from applying a force to a free body, and a Jacobian
that quietly filled in every column would still pass a numerical spot-check on
a serial chain, where every joint IS an ancestor.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from physics.chain import Chain, ChainLink
from collision.collider_set import ColliderSet, Pose3

comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 240.0


def _link(axis: Vec3, pivot: Vec3) -> ChainLink:
    """A unit-length rod: joint at its top, COM half a length below.

    `ChainLink` takes (axis, PIVOT, COM, ...) — passing the rod offset as the
    third argument silently makes it the centre of mass and leaves every pivot
    at zero, which collapses the whole chain onto one frame. That produced a
    degenerate single pendulum that still satisfied self-consistent checks."""
    return ChainLink.revolute(
        axis, pivot, Vec3(0, -0.5, 0, 0), 1.0, Vec3(1.0 / 12.0, 1e-6, 1.0 / 12.0, 0)
    )


def _chain(n: Int) -> Chain:
    var c = Chain()
    for _ in range(n):
        c.add_link(_link(Vec3(0, 0, 1, 0), Vec3(0, -1, 0, 0)))
    return c^


def _slide(mu: Real) raises -> Real:
    """Distance a block on (prismatic y, prismatic x) slides in 1 s from
    3 m/s along x, resting on a floor."""
    var c = Chain()
    c.add_link(ChainLink.prismatic(Vec3(0, 1, 0, 0), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 0.001, Vec3(1e-4, 1e-4, 1e-4, 0)))
    c.add_link(ChainLink.prismatic(Vec3(1, 0, 0, 0), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 1.0, Vec3(0.1, 0.1, 0.1, 0)))
    var ground = ColliderSet()
    var slab = ground.add_ground_slab(-0.5)
    var poses = List[Pose3]()
    poses.append(slab[1].copy())
    var pts = List[Int]()
    pts.append(1)
    var locs = List[Vec3]()
    locs.append(Vec3(0, -0.5, 0, 0))
    var zero = List[Real]()
    zero.append(0)
    zero.append(0)
    for _ in range(60):  # settle onto the floor
        c.step(DT, zero, G)
        _ = c.resolve_contacts(ground, poses, 0.0, pts, locs, DT, 8, True, mu)
    c.qd[1] = 3
    var x0 = c.q[1]
    for _ in range(240):
        c.step(DT, zero, G)
        _ = c.resolve_contacts(ground, poses, 0.0, pts, locs, DT, 8, True, mu)
    return c.q[1] - x0


def main() raises:
    var s = Suite("chain_contact")

    # ---- 1. the Jacobian matches finite differences of FK ----
    var c = _chain(3)
    c.q[0] = 0.3
    c.q[1] = -0.5
    c.q[2] = 0.8
    var tip = Vec3(0, -1, 0, 0)  # far end of the last link (rods are unit length)
    var dir = Vec3(0, 1, 0, 0)
    var j = c.point_jacobian(2, tip, dir)
    comptime H: Real = 1e-3
    var worst = Real(0)
    for k in range(3):
        var q0 = c.q[k]
        c.q[k] = q0 + H
        var pp = c.point_world(2, tip)
        c.q[k] = q0 - H
        var pm = c.point_world(2, tip)
        c.q[k] = q0
        var fd = ((pp - pm) * (1.0 / (2 * H)))[1]
        # relative: central differences carry O(H^2) truncation, which scales
        # with the point's excursion, so an absolute bound would tighten as the
        # rods get longer for no reason
        var scale = abs(fd) if abs(fd) > 1 else Real(1)
        var e = abs(j[k] - fd) / scale
        if e > worst:
            worst = e
    print("  worst relative |J - dFK/dq|:", worst)
    s.check(worst < 1e-2, "point Jacobian == finite-differenced FK")

    # ---- 2. non-ancestor joints have EXACTLY zero influence ----
    var t = Chain()
    var root = t.add_link_to(-1, _link(Vec3(0, 0, 1, 0), Vec3(0, -1, 0, 0)))
    var armA = t.add_link_to(root, _link(Vec3(1, 0, 0, 0), Vec3(0, -1, 0, 0)))
    var armB = t.add_link_to(root, _link(Vec3(0, 1, 0, 0), Vec3(0, -1, 0, 0)))
    t.q[0] = 0.2
    t.q[1] = 0.4
    t.q[2] = -0.3
    var ja = t.point_jacobian(armA, tip, dir)
    print("  J for a point on branch A:", ja[0], ja[1], ja[2])
    s.check(ja[armB] == 0, "the OTHER branch's joint has exactly zero column")
    s.check(ja[root] != 0 or ja[armA] != 0, "ancestor joints do contribute")

    # ---- 3. an impulse produces exactly the requested velocity change ----
    var ic = _chain(3)
    ic.q[0] = 0.2
    ic.q[1] = 0.3
    var before = ic.point_velocity(2, tip, dir)
    var want_dv = Real(1.7)
    _ = ic.apply_impulse(2, tip, dir, want_dv)
    var after = ic.point_velocity(2, tip, dir)
    print("  requested dv", want_dv, " achieved", after - before)
    s.check(
        abs((after - before) - want_dv) < 1e-3,
        "an impulse changes the point velocity by exactly the amount asked",
    )

    # ---- 4. a falling chain lands on the floor and stays above it ----
    var f = _chain(2)
    f.q[0] = 1.2  # swing out so the tip arcs down into the floor
    var zero = List[Real]()
    zero.append(0)
    zero.append(0)
    var pts = List[Int]()
    var locs = List[Vec3]()
    pts.append(0)
    locs.append(Vec3(0, -1, 0, 0))
    pts.append(1)
    locs.append(Vec3(0, -1, 0, 0))
    # two unit rods hanging straight down put the tip at y = -2, so a floor
    # at -1.6 is struck partway through the swing
    comptime FLOOR: Real = -1.6
    var ground = ColliderSet()
    var slab = ground.add_ground_slab(FLOOR)
    var poses = List[Pose3]()
    poses.append(slab[1].copy())
    var worst_pen = Real(0)
    var ever_touched = False
    for _ in range(1200):
        f.step(DT, zero, G)
        var n_act = f.resolve_contacts(ground, poses, 0.0, pts, locs, DT)
        if n_act > 0:
            ever_touched = True
        for c2 in range(len(pts)):
            var pw = f.point_world(pts[c2], locs[c2])
            var pen = FLOOR - pw[1]
            if pen > worst_pen:
                worst_pen = pen
    print("  worst penetration below the floor:", worst_pen)
    s.check(ever_touched, "the chain actually reaches the floor")
    s.check(worst_pen < 0.05, "contact keeps the chain out of the floor")

    # ---- 5. contact must not INJECT energy ----
    #      A frictionless zero-restitution contact removes energy or leaves it
    #      alone; it can never add. Asking the chain to "come to rest" would be
    #      wrong physics here (nothing damps a swinging pendulum), so the gate
    #      is that the speed never exceeds what free fall alone would produce.
    var free = _chain(2)
    free.q[0] = 1.2
    var free_max = Real(0)
    for _ in range(1200):
        free.step(DT, zero, G)
        var sp = abs(free.qd[0]) + abs(free.qd[1])
        if sp > free_max:
            free_max = sp
    var contact_max = Real(0)
    var f2 = _chain(2)
    f2.q[0] = 1.2
    for _ in range(1200):
        f2.step(DT, zero, G)
        _ = f2.resolve_contacts(ground, poses, 0.0, pts, locs, DT)
        var sp = abs(f2.qd[0]) + abs(f2.qd[1])
        if sp > contact_max:
            contact_max = sp
    print("  peak joint speed: free", free_max, " with contact", contact_max)
    s.check(
        contact_max <= free_max * 1.05,
        "contact never injects energy above the free-swinging bound",
    )

    # ---- 6. factored vs dense contact solve (17.51) ----
    #      the same 1200 steps with H Cholesky-factored once per pass and with
    #      a dense elimination per impulse: the same contact fixed point
    var fa = _chain(2)
    var fb = _chain(2)
    fa.q[0] = 1.2
    fb.q[0] = 1.2
    var dq = Real(0)
    for _ in range(1200):
        fa.step(DT, zero, G)
        fb.step(DT, zero, G)
        _ = fa.resolve_contacts(ground, poses, 0.0, pts, locs, DT, 8, True)
        _ = fb.resolve_contacts(ground, poses, 0.0, pts, locs, DT, 8, False)
        dq = max(dq, max(abs(fa.q[0] - fb.q[0]), abs(fa.q[1] - fb.q[1])))
    # and an 8-link chain lying on the floor, every tip touching
    var flat = ColliderSet()
    var fslab = flat.add_ground_slab(-1.01)
    var fposes = List[Pose3]()
    fposes.append(fslab[1].copy())
    var ca = _chain(8)
    var cb = _chain(8)
    ca.q[0] = 1.5707963
    cb.q[0] = 1.5707963
    var p8 = List[Int]()
    var l8 = List[Vec3]()
    var z8 = List[Real]()
    for i in range(8):
        p8.append(i)
        l8.append(Vec3(0, -1, 0, 0))
        z8.append(0)
    for _ in range(120):
        ca.step(DT, z8, G)
        cb.step(DT, z8, G)
        _ = ca.resolve_contacts(flat, fposes, 0.0, p8, l8, DT, 8, True)
        _ = cb.resolve_contacts(flat, fposes, 0.0, p8, l8, DT, 8, False)
        for i in range(8):
            dq = max(dq, abs(ca.q[i] - cb.q[i]))
    print("  factored vs dense contact solve (2 links swinging 1200 steps, 8 links lying on the floor 120 steps): max |dq|", dq)
    s.check(dq < 1e-3, "factoring H once per pass gives the dense solve's motion (max |dq| < 1e-3)")

    # ---- 7. Coulomb friction (17.51) ----
    #      a 1 kg block on two prismatic joints (drop along y, slide along x)
    #      resting on the floor and sliding at 3 m/s: with mu = 0.5 it stops
    #      in v^2 / (2 mu g') (g' = g (m_y + m_x) / m_x for the 1 g carrier);
    #      with mu = 0 it keeps sliding
    var stop = _slide(0.5)
    var keep = _slide(0)
    var gp = Real(9.8) * 1.001
    var want = Real(9) / (2 * 0.5 * gp)
    print("  block sliding at 3 m/s: mu 0.5 stops after", stop, "m (analytic", want, "); mu 0 after 1 s", keep, "m")
    s.check(abs(stop / want - 1) < 0.02, "friction stops the sliding block at v^2 / (2 mu g)")
    s.check(abs(keep - 3) < 0.01, "mu = 0 leaves it sliding at 3 m/s")

    s.finish()
