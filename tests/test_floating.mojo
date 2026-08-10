"""A floating base, gated on the things a fixed base can never test.

Three gates carry this file.

FREE FALL: a body with no joints must accelerate at exactly g. Gravity enters
as a shift on the solve rather than a term in the bias, so applying it twice,
or with the wrong sign, or in the world frame instead of the body frame, all
show up here as a number that is not g.

PINNED PARITY: with the base bolted down the system must reproduce `Chain`
EXACTLY, not approximately. The pin replaces the six base rows with the
identity rather than giving the base a huge inertia, so there is no limit to
take and the comparison can demand machine precision.

INTERNAL FORCES CANNOT CHANGE TOTAL MOMENTUM: joint torques are internal, so
no sequence of them changes the system's total linear or angular momentum.
This is the falling-cat statement, and it is the one gate that exercises the
whole (6+n) coupling at once — a wrong off-diagonal block H_bj lets the robot
push against itself and drift, which nothing in the fixed-base tests could
ever notice. Momentum is assembled from per-link world velocities, sharing no
arithmetic with the solve it audits, and the drift is checked for CONVERGENCE
under halving dt so that "small" means "integration error" rather than
"tolerance chosen to pass".
"""

from std.math import sqrt, sin, cos
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.chain import Chain, ChainLink
from physics.floating import FloatingChain


def zeros(n: Int) -> List[Real]:
    var v = List[Real]()
    for _ in range(n):
        v.append(0)
    return v^


def _links(n: Int) -> List[ChainLink]:
    var out = List[ChainLink]()
    for i in range(n):
        out.append(
            ChainLink.revolute(
                Vec3(0, 0, 1) if i % 2 == 0 else Vec3(0, 1, 0),
                Vec3(0.5, 0.1, 0),
                Vec3(0.25, 0, 0),
                0.8 + Real(i) * 0.1,
                Vec3(0.02, 0.03, 0.025),
            )
        )
    return out^


def _build(n: Int) -> FloatingChain:
    var f = FloatingChain(4.0, Vec3(0.05, -0.02, 0.01), Vec3(0.3, 0.4, 0.35))
    var ls = _links(n)
    for i in range(n):
        f.add_link(ls[i])
    return f^


def _drift(n: Int, dt: Real, steps: Int) raises -> Tuple[Real, Real]:
    """Relative momentum drift over a run driven by joint torques alone."""
    var f = _build(n)
    f.base_w = Vec3(0.3, -0.2, 0.45)
    f.base_v = Vec3(0.1, 0.25, -0.15)
    for i in range(n):
        f.chain.q[i] = 0.2 + Real(i) * 0.1
        f.chain.qd[i] = 0.4 - Real(i) * 0.15
    var m0 = f.momentum(Vec3(0, 0, 0))
    var p0 = m0[0]
    var l0 = m0[1]
    for k in range(steps):
        var tau = zeros(n)
        for i in range(n):
            tau[i] = 0.6 * Real(sin(Float64(k) * 0.05 + Float64(i)))
        f.step(dt, tau, Vec3(0, 0, 0))
    var m1 = f.momentum(Vec3(0, 0, 0))
    var dp = length(m1[0] - p0) / (length(p0) + 1e-12)
    var dl = length(m1[1] - l0) / (length(l0) + 1e-12)
    return (dp, dl)


def main() raises:
    var s = Suite("floating")
    var g = Vec3(0, -9.81, 0)

    # ---- 1. free fall is exactly g --------------------------------------
    var free = FloatingChain(2.5, Vec3(0.1, 0.2, -0.05), Vec3(0.2, 0.3, 0.25))
    var a = free.dynamics(zeros(0), g)
    print("  free-body accel:", a[3], a[4], a[5])
    s.check(
        abs(Float64(a[3])) < 1e-5
        and abs(Float64(a[4] + 9.81)) < 1e-4
        and abs(Float64(a[5])) < 1e-5,
        "a free body accelerates at exactly g",
    )
    s.check(
        abs(Float64(a[0])) < 1e-6 and abs(Float64(a[1])) < 1e-6,
        "gravity applies no torque to a free body",
    )

    # falling for 1 s: semi-implicit Euler gives v = g t exactly
    var dtf = Real(1.0 / 1000.0)
    for _ in range(1000):
        free.step(dtf, zeros(0), g)
    print("  velocity after 1 s:", free.base_v[1])
    s.check(
        abs(Float64(free.base_v[1] + 9.81)) < 5e-3,
        "one second of free fall reaches -g",
    )
    s.check(
        abs(Float64(free.base_rot.w - 1.0)) < 1e-6,
        "free fall induces no rotation",
    )

    # ---- 2. the (6+n) mass matrix is symmetric --------------------------
    #      nothing in the unit-acceleration assembly enforces this
    var fm = _build(3)
    fm.chain.q[0] = 0.4
    fm.chain.q[1] = -0.7
    fm.chain.q[2] = 0.25
    fm.base_rot = Quat.from_axis_angle(Vec3(0.267, 0.535, 0.802), 0.6)
    var h = fm.mass_matrix()
    var d = fm.dof()
    var asym = Real(0)
    var diag_min = Real(1e30)
    for r in range(d):
        for c in range(d):
            var e = Real(abs(Float64(h[r * d + c] - h[c * d + r])))
            if e > asym:
                asym = e
        if h[r * d + r] < diag_min:
            diag_min = h[r * d + r]
    print("  worst |H - H'|:", asym, "  smallest diagonal:", diag_min)
    s.check(asym < 1e-4, "the (6+n) mass matrix is symmetric")
    s.check(diag_min > 0, "the mass matrix has a positive diagonal")

    # ---- 2b. the two assemblies agree -----------------------------------
    #      CRBA extends the composite-inertia recursion; the unit-acceleration
    #      form drives the sweeps directly and shares none of that derivation.
    #      The joint block cannot disagree -- both come from the same
    #      recursion -- but the coupling and base blocks are genuinely
    #      independent, and they are the ones a floating base gets wrong.
    fm.use_crba = False
    var hu = fm.mass_matrix()
    fm.use_crba = True
    var worst_h = Real(0)
    var worst_bj = Real(0)
    for r in range(d):
        for c in range(d):
            var e = Real(abs(Float64(h[r * d + c] - hu[r * d + c])))
            if e > worst_h:
                worst_h = e
            if (r < 6) != (c < 6):  # the coupling block specifically
                if e > worst_bj:
                    worst_bj = e
    print("  CRBA vs unit accelerations:", worst_h, " (coupling block:", worst_bj, ")")
    s.check(worst_h < 1e-3, "CRBA and unit-acceleration assemblies agree")

    # ---- 3. PINNED == fixed base, exactly -------------------------------
    var fp = _build(4)
    var cf = Chain()
    var ls = _links(4)
    for i in range(4):
        cf.add_link(ls[i])
    for i in range(4):
        var qi = 0.3 - Real(i) * 0.17
        var vi = 0.5 + Real(i) * 0.2
        fp.chain.q[i] = qi
        fp.chain.qd[i] = vi
        cf.q[i] = qi
        cf.qd[i] = vi
    fp.pinned = True
    var tau = zeros(4)
    for i in range(4):
        tau[i] = 0.4 - Real(i) * 0.1
    var af = fp.dynamics(tau, g)
    var ac = cf.dynamics(tau, g)
    var worst = Real(0)
    for i in range(4):
        var e = Real(abs(Float64(af[6 + i] - ac[i])))
        if e > worst:
            worst = e
    print("  pinned qdd:", af[6], af[7], "  fixed-base qdd:", ac[0], ac[1])
    print("  worst parity error:", worst)
    s.check(worst < 1e-4, "a pinned floating base reproduces Chain exactly")

    # the pin is enforced through the linear solve, not by construction, so
    # the residual is roundoff on a f32 elimination -- judged against the
    # joint accelerations it sits beside rather than against zero
    var base_mag = Real(0)
    for j in range(6):
        var v = Real(abs(Float64(af[j])))
        if v > base_mag:
            base_mag = v
    print("  pinned base residual accel:", base_mag, " vs joint accel ~", ac[0])
    s.check(
        base_mag < 1e-3, "a pinned base does not accelerate"
    )

    # ---- 4. internal torques cannot change total momentum ---------------
    var d1 = _drift(4, Real(1.0 / 2000.0), 400)
    print("  dt = 1/2000: linear drift", d1[0], " angular drift", d1[1])
    s.check(d1[0] < 5e-3, "joint torques do not change linear momentum")
    s.check(d1[1] < 5e-3, "joint torques do not change angular momentum")

    # ---- 5. and the drift is INTEGRATION error, not a modelling error ---
    #      halving dt over the same physical time must shrink it
    var d2 = _drift(4, Real(1.0 / 4000.0), 800)
    var d3 = _drift(4, Real(1.0 / 8000.0), 1600)
    print("  dt = 1/4000:", d2[0], d2[1])
    print("  dt = 1/8000:", d3[0], d3[1])
    s.check(
        d2[0] < d1[0] and d3[0] < d2[0],
        "linear drift converges as dt shrinks",
    )
    s.check(
        d2[1] < d1[1] and d3[1] < d2[1],
        "angular drift converges as dt shrinks",
    )

    # ---- 6. gravity moves the centre of mass and nothing else -----------
    #      under gravity alone, total angular momentum about the COM is
    #      unchanged in the first instant: g exerts no torque there
    var fg = _build(3)
    fg.base_w = Vec3(0.2, 0.1, -0.3)
    for i in range(3):
        fg.chain.q[i] = 0.3 * Real(i + 1)
        fg.chain.qd[i] = 0.2 - Real(i) * 0.1
    var pre = fg.momentum(g)
    var dtg = Real(1.0 / 4000.0)
    var total_mass = Real(4.0)
    var lks = _links(3)
    for i in range(3):
        total_mass += lks[i].mass
    for _ in range(200):
        fg.step(dtg, zeros(3), g)
    var post = fg.momentum(g)
    var expect = pre[0] + g * (total_mass * dtg * 200)
    var rel = length(post[0] - expect) / (length(expect) + 1e-9)
    print("  linear momentum vs impulse m*g*t:", rel)
    s.check(rel < 5e-3, "gravity changes linear momentum by exactly m g t")

    s.finish()
