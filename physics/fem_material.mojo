"""Constitutive models for tetrahedral FEM (ROADMAP 17.58).

`FemBody.elastic_forces` hard-codes co-rotational linear elasticity. That
model is cheap and exact under rigid rotation, but it measures strain
linearly in the unrotated frame, so under large compression or inversion its
answer depends on what the polar decomposition does with det F <= 0. This
module puts the stress law behind a trait, chosen at compile time:

  * `Corotational`: P = 2 mu (F - R) + lambda tr(R^T F - I) R
    (the model `FemBody` already uses; same numbers).
  * `StableNeoHookean` (Smith, de Goes, Kim 2018, without the log term):
    Psi = mu/2 (I_C - 3) + lambda_s/2 (J - alpha)^2,
    P = mu F + lambda_s (J - alpha) cof(F), lambda_s = lambda + mu,
    alpha = 1 + mu / lambda_s. Rest-stable (P(I) = 0), matches linear
    elasticity at small strain, and defined for J <= 0 (cof(F) needs no
    inverse), so an inverted element is pushed back out.
  * `StVK`: P = F (2 mu E + lambda tr(E) I), E = (F^T F - I) / 2. Rotation
    invariant and exact at small strain, but its energy has a minimum at
    the fully collapsed state: under strong compression the force turns
    toward collapse. Kept as the control that shows what the stable model
    buys.

All three agree at small strain and give zero force under a rigid rotation
(`test_fem_material`); they differ under large compression, which is the
point of the seam.
"""

from geometry.vec import Real, Vec3
from geometry.mat import Mat3
from .fem import FemBody, polar_rotation, det3


trait Material:
    @staticmethod
    def pk1(f: Mat3, mu: Real, lam: Real) -> Mat3: ...

    @staticmethod
    def name() -> String: ...


def cofactor(f: Mat3) -> Mat3:
    """The cofactor matrix d det(F) / dF = det(F) F^-T, computed without the inverse so
    it stays finite at det F = 0."""
    var c = Mat3()
    c.set(0, 0, f.get(1, 1) * f.get(2, 2) - f.get(1, 2) * f.get(2, 1))
    c.set(0, 1, f.get(1, 2) * f.get(2, 0) - f.get(1, 0) * f.get(2, 2))
    c.set(0, 2, f.get(1, 0) * f.get(2, 1) - f.get(1, 1) * f.get(2, 0))
    c.set(1, 0, f.get(0, 2) * f.get(2, 1) - f.get(0, 1) * f.get(2, 2))
    c.set(1, 1, f.get(0, 0) * f.get(2, 2) - f.get(0, 2) * f.get(2, 0))
    c.set(1, 2, f.get(0, 1) * f.get(2, 0) - f.get(0, 0) * f.get(2, 1))
    c.set(2, 0, f.get(0, 1) * f.get(1, 2) - f.get(0, 2) * f.get(1, 1))
    c.set(2, 1, f.get(0, 2) * f.get(1, 0) - f.get(0, 0) * f.get(1, 2))
    c.set(2, 2, f.get(0, 0) * f.get(1, 1) - f.get(0, 1) * f.get(1, 0))
    return c^


struct Corotational(Material):
    @staticmethod
    def pk1(f: Mat3, mu: Real, lam: Real) -> Mat3:
        var r = polar_rotation(f)
        var rtf = r.transpose() * f
        var tr = rtf.get(0, 0) + rtf.get(1, 1) + rtf.get(2, 2) - 3.0
        var p = Mat3()
        for i in range(3):
            for j in range(3):
                p.set(i, j, 2 * mu * (f.get(i, j) - r.get(i, j)) + lam * tr * r.get(i, j))
        return p^

    @staticmethod
    def name() -> String:
        return "corotational"


struct StableNeoHookean(Material):
    @staticmethod
    def pk1(f: Mat3, mu: Real, lam: Real) -> Mat3:
        var lam_s = lam + mu
        var alpha = 1 + mu / lam_s
        var j = det3(f)
        var c = cofactor(f)
        var p = Mat3()
        for a in range(3):
            for b in range(3):
                p.set(a, b, mu * f.get(a, b) + lam_s * (j - alpha) * c.get(a, b))
        return p^

    @staticmethod
    def name() -> String:
        return "stable neo-hookean"


struct StVK(Material):
    @staticmethod
    def pk1(f: Mat3, mu: Real, lam: Real) -> Mat3:
        var ftf = f.transpose() * f
        var e = Mat3()
        for a in range(3):
            for b in range(3):
                e.set(a, b, 0.5 * (ftf.get(a, b) - (Real(1) if a == b else Real(0))))
        var tr = e.get(0, 0) + e.get(1, 1) + e.get(2, 2)
        var s = Mat3()
        for a in range(3):
            for b in range(3):
                s.set(a, b, 2 * mu * e.get(a, b) + (lam * tr if a == b else Real(0)))
        return f * s

    @staticmethod
    def name() -> String:
        return "stvk"


def deformation_gradient(body: FemBody, t: Int) -> Mat3:
    var tt = body.tets[t]
    var pa = body.pos(tt.a)
    var e1 = body.pos(tt.b) - pa
    var e2 = body.pos(tt.c) - pa
    var e3 = body.pos(tt.d) - pa
    var ds = Mat3()
    for k in range(3):
        ds.set(k, 0, e1[k])
        ds.set(k, 1, e2[k])
        ds.set(k, 2, e3[k])
    return ds * tt.dm_inv


def material_forces[M: Material](body: FemBody, mut fx: List[Real], mut fy: List[Real], mut fz: List[Real]):
    """Accumulate the elastic nodal forces of model `M` (H = -W P Dm^-T, as
    in `FemBody.elastic_forces`)."""
    for t in range(len(body.tets)):
        var f = deformation_gradient(body, t)
        var p = M.pk1(f, body.mu, body.lam)
        var tt = body.tets[t]
        var h = p * tt.dm_inv.transpose()
        var w = tt.vol
        var f1 = Vec3(-w * h.get(0, 0), -w * h.get(1, 0), -w * h.get(2, 0), 0)
        var f2 = Vec3(-w * h.get(0, 1), -w * h.get(1, 1), -w * h.get(2, 1), 0)
        var f3 = Vec3(-w * h.get(0, 2), -w * h.get(1, 2), -w * h.get(2, 2), 0)
        var f0 = (f1 + f2 + f3) * Real(-1)
        fx[tt.a] += f0[0]
        fy[tt.a] += f0[1]
        fz[tt.a] += f0[2]
        fx[tt.b] += f1[0]
        fy[tt.b] += f1[1]
        fz[tt.b] += f1[2]
        fx[tt.c] += f2[0]
        fy[tt.c] += f2[1]
        fz[tt.c] += f2[2]
        fx[tt.d] += f3[0]
        fy[tt.d] += f3[1]
        fz[tt.d] += f3[2]


def step_material[M: Material](mut body: FemBody, dt: Real, gravity: Vec3, floor_y: Real = -1e30):
    """Explicit step of `FemBody` with model `M` (same integrator as
    `FemBody.step`: symplectic Euler, mass-proportional damping, floor)."""
    var n = body.node_count()
    var fx = List[Real](length=n, fill=0)
    var fy = List[Real](length=n, fill=0)
    var fz = List[Real](length=n, fill=0)
    material_forces[M](body, fx, fy, fz)
    body.integrate(fx, fy, fz, dt, gravity, floor_y)


def inverted_count(body: FemBody) -> Int:
    """Elements whose current det F is <= 0."""
    var k = 0
    for t in range(len(body.tets)):
        if det3(deformation_gradient(body, t)) <= 0:
            k += 1
    return k
