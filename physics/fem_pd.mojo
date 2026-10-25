"""Projective dynamics for tetrahedral bodies (ROADMAP 17.58, a solver
variant; Bouaziz et al. 2014).

Implicit Euler on the as-rigid-as-possible energy
E = sum_e mu vol_e |F_e - R_e|^2 (R_e the rotation nearest F_e), solved by
local / global alternation:

  * local: per tet, R_e = polar rotation of F_e (`fem.polar_rotation`);
  * global: (M / h^2 + L) x = M / h^2 s + sum_e 2 mu vol_e R_e G_e, with
    s = x + h v + h^2 g the inertial target and L the constant matrix
    sum_e 2 mu vol_e G_e G_e^T over the tets' shape-function gradients
    (rows of Dm^-1; the first node's is minus their sum).

The global matrix does not change while dt, masses and the mesh do not:
`FemPd(body, dt)` builds it (pinned nodes as identity rows) and factors it
once with `numerics.cholesky.SparseCholesky`; each iteration is then
three back-substitutions (x, y, z share the matrix). More iterations
approach the implicit-Euler solution; any number is stable.

With Poisson ratio 0 (lambda = 0) this energy is the co-rotational one
`FemBody.step_implicit` integrates, so both settle to the same static
shape (`test_fem_pd`). There is no volume term: lambda is ignored, the
projective-dynamics restriction to energies with a constant global matrix.
Pinned nodes (`inv_m` 0) keep their positions.
"""

from geometry.vec import Real, Vec3
from geometry.mat import Mat3
from numerics.sparse import CsrMatrix
from numerics.cholesky import SparseCholesky, rcm_order
from .fem import FemBody, polar_rotation


def _grads(body: FemBody, e: Int) -> List[Vec3]:
    """Shape-function gradients of tet e's four nodes: F = sum_k x_k g_k^T."""
    var t = body.tets[e]
    var d = t.dm_inv
    var gb = Vec3(d.get(0, 0), d.get(0, 1), d.get(0, 2), 0)
    var gc = Vec3(d.get(1, 0), d.get(1, 1), d.get(1, 2), 0)
    var gd = Vec3(d.get(2, 0), d.get(2, 1), d.get(2, 2), 0)
    var ga = (gb + gc + gd) * -1
    return [ga, gb, gc, gd]


struct FemPd(Movable):
    var dt: Real
    var n: Int
    var chol: SparseCholesky
    var mass: List[Real]  # 0 for pinned nodes
    var iters: Int

    def __init__(out self, body: FemBody, dt: Real, iters: Int = 10) raises:
        if not (dt > 0) or iters < 1:
            raise Error("FemPd: dt > 0 and iters >= 1")
        self.dt = dt
        self.n = body.node_count()
        self.iters = iters
        self.mass = List[Real](length=self.n, fill=0)
        var rows = List[Int]()
        var cols = List[Int]()
        var vals = List[Real]()
        var h2 = dt * dt
        for i in range(self.n):
            if body.inv_m[i] == 0:
                rows.append(i)
                cols.append(i)
                vals.append(1)
            else:
                self.mass[i] = 1 / body.inv_m[i]
                rows.append(i)
                cols.append(i)
                vals.append(self.mass[i] / h2)
        for e in range(len(body.tets)):
            var t = body.tets[e]
            var g = _grads(body, e)
            var nodes: List[Int] = [t.a, t.b, t.c, t.d]
            var w = 2 * body.mu * t.vol
            for a in range(4):
                if body.inv_m[nodes[a]] == 0:
                    continue
                for b in range(4):
                    if body.inv_m[nodes[b]] == 0:
                        continue  # pinned columns move to the right-hand side
                    rows.append(nodes[a])
                    cols.append(nodes[b])
                    vals.append(w * (g[a][0] * g[b][0] + g[a][1] * g[b][1] + g[a][2] * g[b][2]))
        var m = CsrMatrix.from_triplets(self.n, rows, cols, vals)
        self.chol = SparseCholesky()
        self.chol.factor(m, rcm_order(m))

    def step(mut self, mut body: FemBody, gravity: Vec3):
        var n = self.n
        var h = self.dt
        var h2 = h * h
        var sx = List[Real](length=n, fill=0)
        var sy = List[Real](length=n, fill=0)
        var sz = List[Real](length=n, fill=0)
        for i in range(n):
            if self.mass[i] == 0:
                sx[i] = body.x[i]
                sy[i] = body.y[i]
                sz[i] = body.z[i]
                continue
            sx[i] = body.x[i] + h * body.vx[i] + h2 * gravity[0]
            sy[i] = body.y[i] + h * body.vy[i] + h2 * gravity[1]
            sz[i] = body.z[i] + h * body.vz[i] + h2 * gravity[2]
        var x0 = body.x.copy()
        var y0 = body.y.copy()
        var z0 = body.z.copy()
        # start from the inertial target
        for i in range(n):
            body.x[i] = sx[i]
            body.y[i] = sy[i]
            body.z[i] = sz[i]
        var bx = List[Real](length=n, fill=0)
        var by = List[Real](length=n, fill=0)
        var bz = List[Real](length=n, fill=0)
        for _ in range(self.iters):
            for i in range(n):
                if self.mass[i] == 0:
                    bx[i] = sx[i]
                    by[i] = sy[i]
                    bz[i] = sz[i]
                else:
                    bx[i] = self.mass[i] / h2 * sx[i]
                    by[i] = self.mass[i] / h2 * sy[i]
                    bz[i] = self.mass[i] / h2 * sz[i]
            for e in range(len(body.tets)):
                var t = body.tets[e]
                var g = _grads(body, e)
                var nodes: List[Int] = [t.a, t.b, t.c, t.d]
                var f = Mat3()
                for k in range(4):
                    var p = body.pos(nodes[k])
                    for r in range(3):
                        for c in range(3):
                            f.set(r, c, f.get(r, c) + p[r] * g[k][c])
                var rot = polar_rotation(f)
                var w = 2 * body.mu * t.vol
                for a in range(4):
                    var ia = nodes[a]
                    if self.mass[ia] == 0:
                        continue
                    # + w R g_a, minus the pinned neighbours' coupling
                    var ga = g[a]
                    bx[ia] += w * (rot.get(0, 0) * ga[0] + rot.get(0, 1) * ga[1] + rot.get(0, 2) * ga[2])
                    by[ia] += w * (rot.get(1, 0) * ga[0] + rot.get(1, 1) * ga[1] + rot.get(1, 2) * ga[2])
                    bz[ia] += w * (rot.get(2, 0) * ga[0] + rot.get(2, 1) * ga[1] + rot.get(2, 2) * ga[2])
                    for b in range(4):
                        var ib = nodes[b]
                        if self.mass[ib] != 0:
                            continue
                        var lab = w * (ga[0] * g[b][0] + ga[1] * g[b][1] + ga[2] * g[b][2])
                        bx[ia] -= lab * body.x[ib]
                        by[ia] -= lab * body.y[ib]
                        bz[ia] -= lab * body.z[ib]
            self.chol.solve(bx, body.x)
            self.chol.solve(by, body.y)
            self.chol.solve(bz, body.z)
        var damp = Real(1) / (1 + body.damping * h)
        for i in range(n):
            if self.mass[i] == 0:
                body.vx[i] = 0
                body.vy[i] = 0
                body.vz[i] = 0
                continue
            body.vx[i] = (body.x[i] - x0[i]) / h * damp
            body.vy[i] = (body.y[i] - y0[i]) / h * damp
            body.vz[i] = (body.z[i] - z0[i]) / h * damp
