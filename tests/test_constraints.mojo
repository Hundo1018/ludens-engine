"""The unified constraint solver, and the friction cone it exposes as a seam.

Most of this file is ordinary: each constraint kind gets a case where the
right answer is a closed form, because a solver whose only test is "the
residual got smaller" will happily converge to the wrong thing.

The friction cone is the part worth reading. Coulomb friction says the
tangential force has magnitude at most `mu * f_n` and points directly against
the slip. A pyramidal cone bounds each tangent COMPONENT instead, so its
admissible set is a square inscribed in nothing in particular: along a
diagonal of the tangent basis it permits `sqrt(2)` times the limit, and the
force it produces is not anti-parallel to the slip. Both errors are measured
here by sweeping the slip direction, and neither is a tolerance — both follow
from the geometry of a square, so the test states the number first and then
measures it.

  magnitude:    the diagonal of the square is sqrt(2) times its half-width, so
                a fully saturated pyramidal impulse is sqrt(2) * mu * f_n on
                the diagonal and mu * f_n on an axis. Relative to the smaller,
                that is 41.4 percent more friction for travelling at 45
                degrees to a basis the physics never chose.

  direction:    once both components saturate the impulse points at exactly 45
                degrees regardless of where the body is going. A component
                saturates when |v_i| > mu*f_n, i.e. beyond
                theta_min = asin(mu * f_n / v), so the worst misalignment is
                45 - theta_min degrees. At mu*f_n = 0.5 and v = 3 that is
                35.4 degrees — a friction force pointing a third of a right
                angle away from the direction of travel.
"""

from std.math import sqrt, sin, cos, atan2, acos
from harness.runner import Suite
from geometry.vec import Real
from physics.constraints import (
    ConstraintSet, ConRow, CONE_PYRAMIDAL, CONE_ELLIPTIC,
    CON_EQUALITY, CON_LIMIT, CON_FRICTION_LOSS, CON_CONTACT, CON_TANGENT,
)


def diag_mass(n: Int, m: Real) -> List[Real]:
    var h = List[Real]()
    for r in range(n):
        for c in range(n):
            h.append(m if r == c else Real(0))
    return h^


def vec(n: Int) -> List[Real]:
    var v = List[Real]()
    for _ in range(n):
        v.append(0)
    return v^


def _slide(cone: Int, theta: Real, v: Real, mu: Real) raises -> Tuple[Real, Real]:
    """One free body sliding on a plane. Returns the tangential speed removed
    and the angle between the friction impulse and the slip direction."""
    var m = Real(1.0)
    var cs = ConstraintSet(3)
    cs.cone = cone
    var jn = vec(3)
    jn[1] = 1
    var nrow = cs.add_contact(jn, 0)
    var jt1 = vec(3)
    jt1[0] = 1
    var jt2 = vec(3)
    jt2[2] = 1
    _ = cs.add_tangents(jt1, jt2, nrow, mu)

    var qd = vec(3)
    var cx = Real(cos(Float64(theta)))
    var sz = Real(sin(Float64(theta)))
    qd[0] = v * cx
    qd[1] = -1.0
    qd[2] = v * sz
    cs.solve(diag_mass(3, m), qd, 40)

    var dvx = v * cx - qd[0]
    var dvz = v * sz - qd[2]
    var removed = sqrt(dvx * dvx + dvz * dvz)
    # the friction impulse opposes slip, so -(dv) should point along +slip
    var dotp = (dvx * cx + dvz * sz) / (removed + 1e-12)
    if dotp > 1:
        dotp = 1
    if dotp < -1:
        dotp = -1
    var mis = Real(acos(Float64(dotp))) * Real(180.0 / 3.14159265358979)
    return (removed, mis)


def main() raises:
    var s = Suite("constraints")

    # ---- 1. equality: the residual goes to zero and stays there ----------
    var eq = ConstraintSet(2)
    var j = vec(2)
    j[0] = 1
    j[1] = -2  # enforce qd0 = 2 qd1
    _ = eq.add_equality(j, 0)
    var qd = vec(2)
    qd[0] = 1.0
    qd[1] = 0.0
    eq.solve(diag_mass(2, 1.0), qd, 20)
    print("  equality residual:", qd[0] - 2 * qd[1])
    s.check(abs(Float64(qd[0] - 2 * qd[1])) < 1e-5, "equality residual driven to zero")
    # and the analytic answer: H = I, J = (1,-2), so dq = -J'(J qd0)/(J J')
    #   = -(1,-2) * 1 / 5  ->  qd = (0.8, 0.4)
    s.check(
        abs(Float64(qd[0] - 0.8)) < 1e-4 and abs(Float64(qd[1] - 0.4)) < 1e-4,
        "equality impulse matches the closed form",
    )

    # ---- 2. a limit pushes but never pulls -------------------------------
    var lim = ConstraintSet(1)
    var j1 = vec(1)
    j1[0] = 1
    _ = lim.add_limit(j1, 0)
    var app = vec(1)
    app[0] = -2.0  # moving INTO the stop
    lim.solve(diag_mass(1, 1.0), app, 10)
    print("  approaching:", app[0], "  impulse:", lim.force[0])
    s.check(abs(Float64(app[0])) < 1e-5, "a stop removes the approach velocity")
    s.check(lim.force[0] > 0, "the stop pushes")

    var sep = vec(1)
    sep[0] = 2.0  # moving AWAY
    lim.solve(diag_mass(1, 1.0), sep, 10)
    print("  separating:", sep[0], "  impulse:", lim.force[0])
    s.check(abs(Float64(sep[0] - 2.0)) < 1e-6, "a stop does not act on separation")
    s.check(abs(Float64(lim.force[0])) < 1e-9, "a stop applies no pulling impulse")

    # ---- 3. friction loss: stick below the cap, slip above ---------------
    for k in range(2):
        var fl = ConstraintSet(1)
        var jf = vec(1)
        jf[0] = 1
        _ = fl.add_friction_loss(jf, 0.5)
        var v = vec(1)
        v[0] = 0.3 if k == 0 else Real(2.0)
        fl.solve(diag_mass(1, 1.0), v, 10)
        if k == 0:
            print("  small velocity after dry friction:", v[0])
            s.check(abs(Float64(v[0])) < 1e-5, "dry friction sticks below the cap")
        else:
            print("  large velocity after dry friction:", v[0], "(expect 1.5)")
            s.check(
                abs(Float64(v[0] - 1.5)) < 1e-4,
                "dry friction removes exactly the cap above it",
            )

    # ---- 4. FRICTION CONE: magnitude anisotropy --------------------------
    #      a square admissible set permits sqrt(2)x the limit on its diagonal
    for c in range(2):
        var cone = CONE_PYRAMIDAL if c == 0 else CONE_ELLIPTIC
        var lo = Real(1e30)
        var hi = Real(0)
        var worst_mis = Real(0)
        for k in range(19):
            var th = Real(k) * Real(3.14159265358979 / 2.0) / 18.0
            var r = _slide(cone, th, 3.0, 0.5)
            if r[0] < lo:
                lo = r[0]
            if r[0] > hi:
                hi = r[0]
            if r[1] > worst_mis:
                worst_mis = r[1]
        # relative to the SMALLER, so the number is directly the sqrt(2)
        # excess the square permits rather than a mean-relative rescaling
        var spread = (hi - lo) / lo
        var nm = "pyramidal" if c == 0 else "elliptic"
        print("  ", nm, "friction: spread", spread, " worst misalignment(deg)", worst_mis)
        if c == 0:
            s.check(
                spread > 0.40 and spread < 0.43,
                "pyramidal friction varies by sqrt(2)-1 = 41.4% with direction",
            )
            # predicted 45 - asin(0.5/3) = 35.41 deg; the sweep steps by 5 deg
            # so it samples 35.0 rather than the exact peak
            s.check(
                worst_mis > 33.0 and worst_mis < 36.0,
                "pyramidal friction misaligns from the slip by ~35 deg",
            )
        else:
            s.check(spread < 1e-3, "elliptic friction is isotropic")
            s.check(
                worst_mis < 0.2, "elliptic friction opposes the slip exactly"
            )

    # ---- 5. the elliptic bound is the one Coulomb states -----------------
    var r45 = _slide(CONE_ELLIPTIC, Real(0.7853981634), 3.0, 0.5)
    var r0 = _slide(CONE_ELLIPTIC, Real(0.0), 3.0, 0.5)
    print("  elliptic |dv| at 0 deg:", r0[0], " at 45 deg:", r45[0], " (mu*f_n = 0.5)")
    s.check(
        abs(Float64(r0[0] - 0.5)) < 1e-3 and abs(Float64(r45[0] - 0.5)) < 1e-3,
        "elliptic friction removes exactly mu*f_n in every direction",
    )
    var p45 = _slide(CONE_PYRAMIDAL, Real(0.7853981634), 3.0, 0.5)
    print("  pyramidal |dv| at 45 deg:", p45[0], " (sqrt(2)*mu*f_n =", 0.5 * 1.41421356, ")")
    s.check(
        abs(Float64(p45[0] - 0.5 * 1.41421356)) < 5e-3,
        "pyramidal friction reaches sqrt(2)*mu*f_n on the diagonal",
    )

    # ---- 6. every kind in one system, all satisfied ---------------------
    var mix = ConstraintSet(4)
    var je = vec(4)
    je[0] = 1
    je[1] = -1
    _ = mix.add_equality(je, 0)
    var jl = vec(4)
    jl[2] = 1
    _ = mix.add_limit(jl, 0)
    var jc = vec(4)
    jc[3] = 1
    var nr = mix.add_contact(jc, 0)
    var jta = vec(4)
    jta[0] = 1
    var jtb = vec(4)
    jtb[1] = 1
    _ = mix.add_tangents(jta, jtb, nr, 0.4)
    var mv = vec(4)
    mv[0] = 1.2
    mv[1] = -0.4
    mv[2] = -0.8
    mv[3] = -1.5
    mix.solve(diag_mass(4, 1.0), mv, 60)
    print("  mixed: equality resid", mv[0] - mv[1], " limit", mv[2], " contact", mv[3])
    s.check(abs(Float64(mv[0] - mv[1])) < 1e-3, "equality holds alongside contact")
    s.check(mv[2] > -1e-4, "the limit holds alongside contact")
    s.check(mv[3] > -1e-4, "the contact holds alongside a limit and an equality")
    var ftan = sqrt(
        mix.force[3] * mix.force[3] + mix.force[4] * mix.force[4]
    )
    print("  |f_t| =", ftan, "  mu*f_n =", 0.4 * mix.force[2])
    s.check(
        ftan <= 0.4 * mix.force[2] + 1e-4,
        "friction stays inside the cone in the mixed system",
    )

    s.finish()
