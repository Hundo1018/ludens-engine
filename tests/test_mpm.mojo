"""MLS-MPM: conservation, containment, and the elastic/plastic distinction.

The last pair of checks is the reason MPM exists in this engine. An elastic
solid springs back; a PLASTIC material forgets strain past a yield point and
keeps its new shape. FEM and the mass-spring lattice can do the first and not
the second, so a test that only confirmed "a block deforms and settles" would
pass for a solver that never yields at all — and yielding is the whole point.
Both regimes are therefore run on the identical scene with only the yield range
changed, and the plastic one must end up measurably flatter.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.mpm import MpmSolver


comptime DX: Real = 0.05
comptime N = 32
comptime G = Vec3(0, -9.8, 0)


def _column(mut m: MpmSolver, ox: Real, oy: Real, oz: Real, nx: Int, ny: Int, nz: Int, sp: Real):
    var vol = sp * sp * sp
    for i in range(nx):
        for j in range(ny):
            for k in range(nz):
                m.add(
                    Vec3(ox + Real(i) * sp, oy + Real(j) * sp, oz + Real(k) * sp),
                    vol * 1000.0,
                    vol,
                )


def _height(m: MpmSolver) -> Real:
    var h = Real(-1e30)
    for ref q in m.p:
        if q.x[1] > h:
            h = q.x[1]
    return h


def _spread(m: MpmSolver) -> Real:
    var lo = Real(1e30)
    var hi = Real(-1e30)
    for ref q in m.p:
        if q.x[0] < lo:
            lo = q.x[0]
        if q.x[0] > hi:
            hi = q.x[0]
    return hi - lo


def _inside(m: MpmSolver) -> Bool:
    var hi = m.lo + Vec3(Real(N) * DX, Real(N) * DX, Real(N) * DX)
    for ref q in m.p:
        for a in range(3):
            if q.x[a] < m.lo[a] - 1e-3 or q.x[a] > hi[a] + 1e-3:
                return False
    return True


def _finite(m: MpmSolver) -> Bool:
    for ref q in m.p:
        var v = q.v[0] * q.v[0] + q.v[1] * q.v[1] + q.v[2] * q.v[2]
        if not (v < 1e10):
            return False
    return True


def main() raises:
    var s = Suite("mpm")

    # ---- elastic: stiff, no yield. Dropped from a height so it IMPACTS:
    #      a column that merely stands still never deforms enough for a yield
    #      criterion to fire, and elastic and plastic would be indistinguishable.
    var e = MpmSolver(Vec3(0, 0, 0), DX, N, 100000.0, 0.2)
    _column(e, 0.55, 0.95, 0.70, 6, 10, 4, 0.04)
    var n0 = e.count()
    var m0 = e.total_mass()
    print("  particles:", n0)
    s.check(n0 == 240, "240 particles seeded")

    var ok = True
    for _ in range(2400):
        e.step(1.0 / 2000.0, G)
        if not _inside(e) or not _finite(e):
            ok = False
    s.check(ok, "elastic run stays contained and finite")
    s.check(e.count() == n0, "particle count conserved")
    s.check(abs(e.total_mass() - m0) < 1e-6, "total mass conserved")
    var h_elastic = _height(e)
    var w_elastic = _spread(e)

    # ---- plastic: identical scene, tight yield range ----
    var p = MpmSolver(Vec3(0, 0, 0), DX, N, 100000.0, 0.2)
    _column(p, 0.55, 0.95, 0.70, 6, 10, 4, 0.04)
    p.set_plastic(0.94, 1.02)
    var okp = True
    for _ in range(2400):
        p.step(1.0 / 2000.0, G)
        if not _inside(p) or not _finite(p):
            okp = False
    s.check(okp, "plastic run stays contained and finite")
    var h_plastic = _height(p)
    var w_plastic = _spread(p)

    print("  elastic  height", h_elastic, " spread", w_elastic)
    print("  plastic  height", h_plastic, " spread", w_plastic)
    # The distinguishing property is that the plastic material does NOT
    # RECOVER: both are squashed by the impact, but the elastic one springs
    # back toward its original height while the plastic one keeps the new
    # shape. Asserting "it spreads wider" would be wrong here — a column
    # squashed against a floor loses height without necessarily gaining width.
    s.check(
        h_plastic < 0.6 * h_elastic,
        "the plastic material keeps its squashed height (no elastic recovery)",
    )
    s.check(
        w_plastic > 0.5 * w_elastic,
        "the plastic material stays a coherent body, not a collapsed point",
    )

    # ---- free fall: momentum tracks gravity before anything is touched ----
    var f = MpmSolver(Vec3(0, 0, 0), DX, N, 4000.0, 0.2)
    _column(f, 0.60, 1.00, 0.70, 4, 4, 4, 0.04)
    var mass = f.total_mass()
    var dt = Real(1.0 / 2000.0)
    for _ in range(20):
        f.step(dt, G)
    var pmom = f.total_momentum()
    var want = -9.8 * mass * dt * 20.0
    print("  free-fall momentum y:", pmom[1], " expected ~", want)
    s.check(
        abs(pmom[1] - want) < 0.15 * abs(want),
        "free fall accumulates the gravitational impulse",
    )

    s.finish()
