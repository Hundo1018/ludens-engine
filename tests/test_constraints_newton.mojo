# tier: unit  (override: exercises physics.constraints alone; numerics.dense is its internal linear solve)
"""Active-set Newton with friction cones (13.5, `ConstraintSet.solve_cone_newton`).

Scene: a point mass with H = I. The normal is e_y, the tangents are e_x and
e_z, so the two tangent rows are an orthonormal basis of the contact plane.
With the velocity (vx, vy, vz) = (1, -1, 0.2) the normal must cancel vy
(f_n = 1) and the friction must oppose the tangential velocity (1, 0.2) with
at most mu f_n = 0.5.

  elliptic:  f_t = -mu f_n unit(v_t), so the tangential velocity keeps its
             direction: vz / vx stays 0.2.
  pyramidal: each component is clamped separately, f = -mu f_n (1, 1), which
             turns the velocity toward the basis axes: the direction changes.

The test checks that Newton matches PGS run to high precision on the elliptic
cone, that both cones show the same behaviour under both solvers, that a
stuck contact stays stuck, that a limit row combines with the contact, and
that every case settles in fewer rounds than `MAX_ROUNDS`.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real
from physics.constraints import ConstraintSet, CONE_PYRAMIDAL, CONE_ELLIPTIC

comptime MU: Real = 0.5
comptime MAX_ROUNDS = 40
comptime PGS_ITERS = 400


def identity(n: Int) -> List[Real]:
    var h = List[Real]()
    for r in range(n):
        for c in range(n):
            h.append(Real(1) if r == c else Real(0))
    return h^


def banded(n: Int) -> List[Real]:
    var h = List[Real]()
    for r in range(n):
        for c in range(n):
            h.append(Real(1) if r == c else (Real(0.1) if abs(r - c) == 1 else Real(0)))
    return h^


def _dot(cs: ConstraintSet, r: Int, v: List[Real]) -> Real:
    var acc = Real(0)
    for i in range(len(v)):
        acc += cs.jac[r * len(v) + i] * v[i]
    return acc


def unit(n: Int, i: Int) -> List[Real]:
    var j = List[Real](length=n, fill=0)
    j[i] = 1
    return j^


def vel(n: Int, a: Real, b: Real, c: Real, d: Real = 0) -> List[Real]:
    var q = List[Real](length=n, fill=0)
    q[0] = a
    q[1] = b
    q[2] = c
    if n > 3:
        q[3] = d
    return q^


def scene(cone: Int, with_limit: Bool) raises -> ConstraintSet:
    """Coordinates 0..2 carry the contact; coordinate 3 (if present) a limit."""
    var n = 4 if with_limit else 3
    var cs = ConstraintSet(n)
    cs.cone = cone
    var nr = cs.add_contact(unit(n, 1), 0)
    _ = cs.add_tangents(unit(n, 0), unit(n, 2), nr, MU)
    if with_limit:
        _ = cs.add_limit(unit(n, 3), 0)
    return cs^


def newton(mut cs: ConstraintSet, mut qd: List[Real]) raises -> Int:
    var n = len(qd)
    return cs.solve_cone_newton(identity(n), qd, MAX_ROUNDS)


def pgs(mut cs: ConstraintSet, mut qd: List[Real]) raises:
    var n = len(qd)
    cs.solve(identity(n), qd, PGS_ITERS)


def ratio(q: List[Real]) -> Real:
    return q[2] / q[0]


def main() raises:
    var s = Suite("constraints_newton")

    # A: the tangential speed 0.1 is below mu f_n = 0.5, so the contact sticks
    var a = scene(CONE_ELLIPTIC, False)
    var qa = vel(3, 0.1, -1, 0)
    var ra = newton(a, qa)
    print("  stick: rounds", ra, "vx", qa[0], "vy", qa[1])
    s.check(ra < MAX_ROUNDS, "a stuck contact settles within max_iter")
    s.almost(Float64(qa[0]), 0.0, "tangential speed below the cone is removed (stick)", tol=1e-6)
    s.almost(Float64(qa[1]), 0.0, "normal speed is removed by the contact", tol=1e-6)

    # B: slide along the axis; both cones agree when the velocity is axis-aligned
    for cone in [CONE_ELLIPTIC, CONE_PYRAMIDAL]:
        var b = scene(cone, False)
        var qb = vel(3, 1, -1, 0)
        var rb = newton(b, qb)
        print("  axis slide, cone", cone, "rounds", rb, "vx", qb[0], "vz", qb[2])
        s.check(rb < MAX_ROUNDS, "axis slide settles within max_iter")
        s.almost(Float64(qb[0]), 0.5, "axis slide loses mu f_n = 0.5 of speed", tol=1e-6)

    # C: incline. Elliptic keeps the direction; pyramidal turns it.
    var ce = scene(CONE_ELLIPTIC, False)
    var qe = vel(3, 1, -1, 0.2)
    var re = newton(ce, qe)
    var pe = scene(CONE_ELLIPTIC, False)
    var qpe = vel(3, 1, -1, 0.2)
    pgs(pe, qpe)
    var cp = scene(CONE_PYRAMIDAL, False)
    var qp = vel(3, 1, -1, 0.2)
    var rp = newton(cp, qp)
    var pp = scene(CONE_PYRAMIDAL, False)
    var qpp = vel(3, 1, -1, 0.2)
    pgs(pp, qpp)
    print("  elliptic newton: rounds", re, "vx", qe[0], "vz", qe[2], "vz/vx", ratio(qe))
    print("  elliptic pgs:    vx", qpe[0], "vz", qpe[2], "vz/vx", ratio(qpe))
    print("  pyramidal newton: rounds", rp, "vx", qp[0], "vz", qp[2], "vz/vx", ratio(qp))
    print("  pyramidal pgs:    vx", qpp[0], "vz", qpp[2], "vz/vx", ratio(qpp))

    s.check(re < MAX_ROUNDS and rp < MAX_ROUNDS, "incline settles within max_iter under both cones")
    s.almost(Float64(ratio(qe)), 0.2, "elliptic cone keeps the sliding direction (vz/vx = 0.2), Newton", tol=1e-6)
    s.almost(Float64(ratio(qpe)), 0.2, "elliptic cone keeps the sliding direction (vz/vx = 0.2), PGS", tol=1e-3)
    s.check(abs(ratio(qp) - 0.2) > 0.1, "pyramidal cone turns the sliding direction, Newton")
    s.check(abs(ratio(qpp) - 0.2) > 0.1, "pyramidal cone turns the sliding direction, PGS")
    s.almost(Float64(qe[0]), Float64(qpe[0]), "elliptic Newton matches PGS on vx", tol=1e-3)
    s.almost(Float64(qe[2]), Float64(qpe[2]), "elliptic Newton matches PGS on vz", tol=1e-3)
    s.almost(Float64(qp[0]), Float64(qpp[0]), "pyramidal Newton matches PGS on vx", tol=1e-3)
    s.almost(Float64(qp[2]), Float64(qpp[2]), "pyramidal Newton matches PGS on vz", tol=1e-3)

    # D: a limit row (coordinate 3, velocity -1) solved with the same contact
    var d = scene(CONE_ELLIPTIC, True)
    var qd4 = vel(4, 1, -1, 0, -1)
    var rd = newton(d, qd4)
    print("  limit + contact + friction: rounds", rd, "vx", qd4[0], "vy", qd4[1], "q3", qd4[3])
    s.check(rd < MAX_ROUNDS, "limit + contact + friction settles within max_iter")
    s.almost(Float64(qd4[3]), 0.0, "limit row stops the joint velocity", tol=1e-6)
    s.almost(Float64(qd4[1]), 0.0, "contact still removes the normal speed with a limit present", tol=1e-6)
    s.almost(Float64(qd4[0]), 0.5, "friction still acts with a limit present", tol=1e-6)

    # E: a sweep over approach speed and tangential direction. Newton must agree
    # with PGS (elliptic) everywhere and settle in few rounds; the rounds are
    # recorded so a cycling regression shows up as a larger number here.
    var worst_gap = Real(0)
    var worst_rounds = 0
    for k in range(24):
        var kk = Real(k)
        var vx = 0.2 + 0.15 * kk
        var vz = 0.6 * (kk - 12) / 12
        var vy = -(0.5 + 0.1 * kk)
        var ee = scene(CONE_ELLIPTIC, False)
        var qn = vel(3, vx, vy, vz)
        var rr = newton(ee, qn)
        var pg = scene(CONE_ELLIPTIC, False)
        var qg = vel(3, vx, vy, vz)
        pgs(pg, qg)
        if rr > worst_rounds:
            worst_rounds = rr
        for c in range(3):
            var gap = abs(qn[c] - qg[c])
            if gap > worst_gap:
                worst_gap = gap
    print("  sweep: worst |Newton - PGS| per component", worst_gap, "worst rounds", worst_rounds)
    s.check(worst_rounds < MAX_ROUNDS, "every sweep case settles within max_iter")
    s.check(worst_gap < 1e-3, "Newton matches PGS across the sweep (elliptic, 1e-3)")

    # F: coupled contacts (six coordinates shared by three pairs, H tridiagonal).
    # PGS stalls on this system (see bench_constraints); Newton is checked
    # against the KKT conditions directly, from the stored impulses.
    var nc = 18
    var cc = ConstraintSet(nc)
    cc.cone = CONE_ELLIPTIC
    for k in range(6):
        var base = (k * 3) % nc
        var nr = cc.add_contact(unit(nc, base), 0)
        _ = cc.add_tangents(unit(nc, base + 1), unit(nc, base + 2), nr, MU)
    var qc = List[Real](length=nc, fill=0)
    for i in range(nc):
        qc[i] = -1.0 + Real(i) * 0.13
    var rc = cc.solve_cone_newton(banded(nc), qc, MAX_ROUNDS)
    var pen = Real(0)
    var neg = Real(0)
    var comp = Real(0)
    var excess = Real(0)
    var stick = Real(0)
    var against = Real(0)
    for k in range(6):
        var nr = (k * 3) % nc
        var t1 = nr + 1
        var t2 = nr + 2
        var vn = _dot(cc, nr, qc)
        var v1 = _dot(cc, t1, qc)
        var v2 = _dot(cc, t2, qc)
        var fnor = cc.force[nr]
        var f1 = cc.force[t1]
        var f2 = cc.force[t2]
        var ft = sqrt(f1 * f1 + f2 * f2)
        pen = max(pen, -vn)
        neg = max(neg, -fnor)
        comp = max(comp, abs(fnor * vn))
        excess = max(excess, ft - MU * fnor)
        if ft < MU * fnor - 1e-6:
            stick = max(stick, sqrt(v1 * v1 + v2 * v2))
        elif ft > 1e-9:
            against = max(against, (f1 * v1 + f2 * v2) / ft)
    print("  coupled KKT: rounds", rc, "penetration", pen, "comp", comp, "cone excess", excess, "stuck speed", stick, "against", against)
    s.check(rc < MAX_ROUNDS, "coupled contacts settle within max_iter")
    s.check(pen < 1e-5 and neg < 1e-6 and comp < 1e-5, "coupled Newton: no penetration, non-negative normal impulse, complementarity")
    s.check(excess < 1e-6 and stick < 1e-5, "coupled Newton: inside the cone, stuck pairs have zero tangential speed")
    s.check(against < 1e-6, "coupled Newton: sliding friction opposes the tangential velocity")

    s.finish()
