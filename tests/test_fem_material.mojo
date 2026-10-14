# tier: integration
"""FEM constitutive models behind one seam (ROADMAP 17.58).

  1. Ordinary: `Corotational` gives the same forces as `FemBody.elastic_forces`;
     at a small strain (|F - I| = 1e-3) the three models' stresses agree
     within 1 %; a rigid rotation of 63 degrees gives zero stress in all three;
     at rest P = 0 in all three.
  2. Integration: a cantilever beam (12 x 2 x 2 cells, E = 1e7) sags under
     gravity; its tip deflection is compared with Euler-Bernoulli
     q L^4 / (8 E I) (linear tets are stiff in bending: the ratio is
     reported and bounded); the explicit corotational and stable Neo-Hookean
     beams settle to tips within 2 % of each other.
  3. Extreme: an element pushed through itself (one vertex past the opposite
     face, det F = -0.2) is released: stable Neo-Hookean restores it
     (det F > 0), StVK and corotational keep it inverted; under uniaxial
     compression to 2 % StVK's restoring stress has dropped below 10 % of its
     peak (its energy flattens toward collapse) while Neo-Hookean's grows.
"""

from std.math import sqrt, cos, sin
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.mat import Mat3
from physics.fem import FemBody, make_beam, det3
from physics.fem_material import (
    Material, Corotational, StableNeoHookean, StVK, material_forces, step_material,
    inverted_count, deformation_gradient,
)

comptime MU: Real = 1000.0
comptime LAM: Real = 1500.0


def _diag(a: Real, b: Real, c: Real) -> Mat3:
    var m = Mat3()
    m.set(0, 0, a)
    m.set(1, 1, b)
    m.set(2, 2, c)
    return m^


def _norm(m: Mat3) -> Real:
    var s = Real(0)
    for i in range(3):
        for j in range(3):
            s += m.get(i, j) * m.get(i, j)
    return sqrt(s)


def _diff(a: Mat3, b: Mat3) -> Real:
    var s = Real(0)
    for i in range(3):
        for j in range(3):
            s += (a.get(i, j) - b.get(i, j)) ** 2
    return sqrt(s)


def _tip_y(b: FemBody, nx: Int) -> Real:
    """Mean y of the free-end nodes: `make_beam` writes the x = nx slice
    last, (2 + 1) * (2 + 1) nodes. Chosen by index, not by current x, which
    shrinks as the beam bends."""
    var y = Real(0)
    var n = b.node_count()
    for i in range(n - 9, n):
        y += b.y[i]
    return y / 9


def _beam(young: Real, nx: Int) -> FemBody:
    var b = FemBody(young, 0.3, 6.0)
    make_beam(b, nx, 2, 2, 0.1, 0.05)
    for i in range(b.node_count()):
        if b.pos(i)[0] < 1e-6:
            b.pin(i)
    return b^


def _one_tet(z: Real) -> FemBody:
    var b = FemBody(2000.0, 0.3, 2.0)
    b.add_node(Vec3(0, 0, 0, 0), 1)
    b.add_node(Vec3(1, 0, 0, 0), 1)
    b.add_node(Vec3(0, 1, 0, 0), 1)
    b.add_node(Vec3(0, 0, 1, 0), 1)
    b.add_tet(0, 1, 2, 3)
    b.z[3] = z
    return b^


def _release[M: Material](z: Real) -> Real:
    var b = _one_tet(z)
    for i in range(3):
        b.pin(i)
    for _ in range(2000):
        step_material[M](b, 1e-3, Vec3(0, 0, 0, 0))
    return det3(deformation_gradient(b, 0))


def main() raises:
    var s = Suite("fem_material")

    # ---- small strain, rest, rotation ------------------------------------------------
    var g = Mat3()
    var k = 0
    for i in range(3):
        for j in range(3):
            g.set(i, j, (Real(1) if i == j else Real(0)) + 1e-3 * Real((k * 7) % 5 - 2) / 2)
            k += 1
    var pc = Corotational.pk1(g, MU, LAM)
    var pn = StableNeoHookean.pk1(g, MU, LAM)
    var ps = StVK.pk1(g, MU, LAM)
    var dn = _diff(pn, pc) / _norm(pc)
    var ds = _diff(ps, pc) / _norm(pc)
    print("  small strain: |P_nh - P_co| / |P_co|", dn, "  |P_stvk - P_co| / |P_co|", ds)
    s.check(dn < 0.01 and ds < 0.01, "the three models agree within 1 % at strain 1e-3")
    var eye = Mat3.identity()
    s.check(_norm(Corotational.pk1(eye, MU, LAM)) < 1e-3 and _norm(StableNeoHookean.pk1(eye, MU, LAM)) < 1e-3 and _norm(StVK.pk1(eye, MU, LAM)) < 1e-3, "P(I) = 0 in all three (rest-stable)")
    var ang = Real(1.1)
    var rot = Mat3.identity()
    rot.set(0, 0, cos(ang))
    rot.set(0, 1, -sin(ang))
    rot.set(1, 0, sin(ang))
    rot.set(1, 1, cos(ang))
    var rc = _norm(Corotational.pk1(rot, MU, LAM))
    var rn = _norm(StableNeoHookean.pk1(rot, MU, LAM))
    var rs = _norm(StVK.pk1(rot, MU, LAM))
    print("  rigid rotation 63 deg: |P| corotational", rc, " neo-hookean", rn, " stvk", rs)
    s.check(rc < 0.05 and rn < 0.05 and rs < 0.05, "a rigid rotation is stress-free in all three (|P| < 5e-5 mu)")

    var b = _beam(5000.0, 4)
    for i in range(b.node_count()):
        b.y[i] += 0.02 * b.x[i] * b.x[i]
    var n = b.node_count()
    var fx1 = List[Real](length=n, fill=0)
    var fy1 = List[Real](length=n, fill=0)
    var fz1 = List[Real](length=n, fill=0)
    var fx2 = List[Real](length=n, fill=0)
    var fy2 = List[Real](length=n, fill=0)
    var fz2 = List[Real](length=n, fill=0)
    b.elastic_forces(fx1, fy1, fz1)
    material_forces[Corotational](b, fx2, fy2, fz2)
    var same = True
    for i in range(n):
        if fx1[i] != fx2[i] or fy1[i] != fy2[i] or fz1[i] != fz2[i]:
            same = False
    s.check(same, "Corotational through the seam == FemBody.elastic_forces, bit for bit")

    # ---- cantilever --------------------------------------------------------------------
    var nx = 12
    var young = Real(1e7)
    var cb = _beam(young, nx)
    var y0 = _tip_y(cb, nx)
    for _ in range(600):
        _ = cb.step_implicit(1.0 / 60.0, Vec3(0, -9.8, 0, 0), -1e30, 1e-6, 400)
    var sag = y0 - _tip_y(cb, nx)
    var length = Real(nx) * 0.1
    var mass = Real(0)
    for i in range(cb.node_count()):
        if cb.inv_m[i] > 0:
            mass += 1 / cb.inv_m[i]
    var q = mass * 9.8 / length
    var inertia = Real(0.2) * 0.2 * 0.2 * 0.2 / 12
    var eb = q * length ** 4 / (8 * young * inertia)
    print("  cantilever L=1.2: tip sag", sag, " Euler-Bernoulli", eb, " ratio", sag / eb)
    s.check(sag / eb > 0.5 and sag / eb < 1.1, "tip sag within [0.5, 1.1] of Euler-Bernoulli (linear tets lock in bending)")

    var soft_c = _beam(1e5, 6)
    var soft_n = _beam(1e5, 6)
    for _ in range(3000):
        step_material[Corotational](soft_c, 1e-3, Vec3(0, -9.8, 0, 0))
        step_material[StableNeoHookean](soft_n, 1e-3, Vec3(0, -9.8, 0, 0))
    var tc = _tip_y(soft_c, 6)
    var tn = _tip_y(soft_n, 6)
    var y06 = Real(0.1)
    print("  beam E=1e5 settled tip: corotational", tc, " neo-hookean", tn)
    s.check(abs((y06 - tc) - (y06 - tn)) <= 0.02 * abs(y06 - tc), "corotational and neo-hookean settle within 2 % of each other")

    # ---- inversion and collapse --------------------------------------------------------------
    var jn = _release[StableNeoHookean](-0.2)
    var js = _release[StVK](-0.2)
    var jc = _release[Corotational](-0.2)
    print("  inverted tet (det F = -0.2) released: det F after 2 s  neo-hookean", jn, " stvk", js, " corotational", jc)
    s.check(jn > 0, "stable Neo-Hookean restores an inverted element")
    s.check(js <= 0 and jc <= 0, "StVK and corotational keep it inverted (the controls)")
    s.check(inverted_count(_one_tet(-0.2)) == 1 and inverted_count(_one_tet(1)) == 0, "inverted_count sees det F <= 0")
    var peak = Real(0)
    for q2 in range(1, 100):
        peak = max(peak, -StVK.pk1(_diag(Real(q2) / 100, 1, 1), MU, LAM).get(0, 0))
    var s05 = -StVK.pk1(_diag(0.02, 1, 1), MU, LAM).get(0, 0)
    var n05 = -StableNeoHookean.pk1(_diag(0.02, 1, 1), MU, LAM).get(0, 0)
    var n50 = -StableNeoHookean.pk1(_diag(0.5, 1, 1), MU, LAM).get(0, 0)
    print("  uniaxial to 2 %: stvk restoring", s05, "(peak", peak, ")  neo-hookean", n05, "(at 50 %:", n50, ")")
    s.check(s05 < 0.1 * peak and n05 > n50, "StVK's restoring stress collapses, Neo-Hookean's grows")
    s.finish()
