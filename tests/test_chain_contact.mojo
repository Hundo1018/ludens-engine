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

comptime G = Vec3(0, -9.8, 0)
comptime DT: Real = 1.0 / 240.0


def _link(axis: Vec3, pivot: Vec3) -> ChainLink:
    """A unit-length rod: joint at its top, COM half a length below.

    `ChainLink` takes (axis, PIVOT, COM, ...) — passing the rod offset as the
    third argument silently makes it the centre of mass and leaves every pivot
    at zero, which collapses the whole chain onto one frame. That produced a
    degenerate single pendulum that still satisfied self-consistent checks."""
    return ChainLink(
        axis, pivot, Vec3(0, -0.5, 0), 1.0, Vec3(1.0 / 12.0, 1e-6, 1.0 / 12.0)
    )


def _chain(n: Int) -> Chain:
    var c = Chain()
    for _ in range(n):
        c.add_link(_link(Vec3(0, 0, 1), Vec3(0, -1, 0)))
    return c^


def main() raises:
    var s = Suite("chain_contact")

    # ---- 1. the Jacobian matches finite differences of FK ----
    var c = _chain(3)
    c.q[0] = 0.3
    c.q[1] = -0.5
    c.q[2] = 0.8
    var tip = Vec3(0, -1, 0)  # far end of the last link (rods are unit length)
    var dir = Vec3(0, 1, 0)
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
    var root = t.add_link_to(-1, _link(Vec3(0, 0, 1), Vec3(0, -1, 0)))
    var armA = t.add_link_to(root, _link(Vec3(1, 0, 0), Vec3(0, -1, 0)))
    var armB = t.add_link_to(root, _link(Vec3(0, 1, 0), Vec3(0, -1, 0)))
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
    locs.append(Vec3(0, -1, 0))
    pts.append(1)
    locs.append(Vec3(0, -1, 0))
    # two unit rods hanging straight down put the tip at y = -2, so a floor
    # at -1.6 is struck partway through the swing
    comptime FLOOR: Real = -1.6
    var worst_pen = Real(0)
    var ever_touched = False
    for _ in range(1200):
        f.step(DT, zero, G)
        var n_act = f.resolve_ground(FLOOR, 0.0, pts, locs, DT)
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
        _ = f2.resolve_ground(FLOOR, 0.0, pts, locs, DT)
        var sp = abs(f2.qd[0]) + abs(f2.qd[1])
        if sp > contact_max:
            contact_max = sp
    print("  peak joint speed: free", free_max, " with contact", contact_max)
    s.check(
        contact_max <= free_max * 1.05,
        "contact never injects energy above the free-swinging bound",
    )

    s.finish()
