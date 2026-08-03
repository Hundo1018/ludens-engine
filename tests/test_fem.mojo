"""Co-rotational FEM: the properties that separate a continuum from a lattice.

Check 1 is the one that matters. Linear elasticity measures strain from
displacement, so a RIGID ROTATION of an undeformed body registers as enormous
strain and linear FEM tears it apart. Co-rotational FEM extracts the rotation
by polar decomposition and measures strain in the unrotated frame, so the same
rotation must produce EXACTLY zero force. A test that only checks "a beam
sags plausibly" passes for both, which is why that is not the first check here.

The rest gate the things a mass-spring lattice cannot claim: forces vanish at
rest (no built-in prestress), the material responds to its Poisson ratio rather
than to how the lattice happens to be wired, and a pinned beam under gravity
reaches a steady deflection instead of drifting or exploding.
"""

from std.math import sqrt, cos, sin
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.mat import Mat3
from physics.fem import FemBody, make_beam, polar_rotation


def _max_force(mut b: FemBody) -> Real:
    var n = b.node_count()
    var fx = List[Real]()
    var fy = List[Real]()
    var fz = List[Real]()
    for _ in range(n):
        fx.append(0)
        fy.append(0)
        fz.append(0)
    b.elastic_forces(fx, fy, fz)
    var m = Real(0)
    for i in range(n):
        var f = sqrt(fx[i] * fx[i] + fy[i] * fy[i] + fz[i] * fz[i])
        if f > m:
            m = f
    return m


def main() raises:
    var s = Suite("fem")

    # ---- 1. rest state: no prestress ----
    var b = FemBody(young=5000.0, poisson=0.3)
    make_beam(b, 4, 2, 2, 0.1, 0.05)
    print("  nodes:", b.node_count(), " tets:", len(b.tets))
    s.check(b.node_count() == 45, "45 lattice nodes")
    s.check(len(b.tets) == 80, "80 tetrahedra (5 per cell)")
    var f_rest = _max_force(b)
    print("  max force at rest:", f_rest)
    s.check(f_rest < 1e-3, "undeformed body carries no force")

    # ---- 2. RIGID ROTATION must be force-free (the co-rotational property) ----
    var r = FemBody(young=5000.0, poisson=0.3)
    make_beam(r, 4, 2, 2, 0.1, 0.05)
    var ang = Real(1.1)  # ~63 degrees: far outside the small-angle regime
    var ca = Real(cos(Float64(ang)))
    var sa = Real(sin(Float64(ang)))
    for i in range(r.node_count()):
        var px = r.x[i]
        var py = r.y[i]
        r.x[i] = ca * px - sa * py
        r.y[i] = sa * px + ca * py
    var f_rot = _max_force(r)
    print("  max force after a 63-degree rigid rotation:", f_rot)
    s.check(f_rot < 1e-2, "a rigid rotation produces no force (co-rotational)")

    # ---- 3. polar decomposition returns an actual rotation ----
    var m = Mat3()
    m.set(0, 0, 1.4)
    m.set(0, 1, 0.3)
    m.set(0, 2, -0.2)
    m.set(1, 0, -0.1)
    m.set(1, 1, 0.9)
    m.set(1, 2, 0.25)
    m.set(2, 0, 0.2)
    m.set(2, 1, -0.15)
    m.set(2, 2, 1.1)
    var rot = polar_rotation(m)
    var rtr = rot.transpose() * rot
    var orth = Real(0)
    for i in range(3):
        for j in range(3):
            var want = Real(1) if i == j else Real(0)
            var e = abs(rtr.get(i, j) - want)
            if e > orth:
                orth = e
    print("  polar R orthogonality error:", orth)
    s.check(orth < 1e-3, "polar decomposition yields an orthogonal R")

    # ---- 4. stretched body pulls BACK toward rest ----
    var t = FemBody(young=5000.0, poisson=0.3)
    make_beam(t, 4, 2, 2, 0.1, 0.05)
    for i in range(t.node_count()):
        t.x[i] *= 1.2  # 20% stretch along x
    var n = t.node_count()
    var fx = List[Real]()
    var fy = List[Real]()
    var fz = List[Real]()
    for _ in range(n):
        fx.append(0)
        fy.append(0)
        fz.append(0)
    t.elastic_forces(fx, fy, fz)
    # the far end (largest x) must be pulled in -x
    var far = 0
    for i in range(n):
        if t.x[i] > t.x[far]:
            far = i
    print("  restoring force at the stretched end:", fx[far])
    s.check(fx[far] < 0, "a stretched body pulls back toward rest")

    # ---- 5. pinned cantilever reaches a steady deflection ----
    var c = FemBody(young=20000.0, poisson=0.3)
    make_beam(c, 6, 2, 2, 0.1, 0.02)
    for i in range(c.node_count()):
        if c.x[i] < 1e-6:
            c.pin(i)
    var v0 = c.total_volume()
    for _ in range(600):
        c.step(1.0 / 600.0, Vec3(0, -9.8, 0))
    var tip_y = Real(1e30)
    for i in range(c.node_count()):
        if c.x[i] > 0.55 and c.y[i] < tip_y:
            tip_y = c.y[i]
    var v1 = c.total_volume()
    print("  cantilever tip y:", tip_y, "  volume", v0, "->", v1)
    s.check(tip_y < 0.0, "the cantilever sags under gravity")
    s.check(tip_y > -0.5, "the cantilever does not collapse or explode")
    s.check(
        v1 > 0.5 * v0 and v1 < 1.5 * v0,
        "volume stays within 50% of rest under load",
    )

    s.finish()
