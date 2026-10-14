"""Heat conduction on two discretisations, and thermal expansion (ROADMAP 17.61).

No temperature field existed in the engine. This module gives one, on the two
geometries that already carry the other fields:

  * `HeatGrid`: a regular grid (cell size dx), explicit 7-point finite
    differences, insulated outer faces (mirror), Dirichlet cells by `fix`.
    Stable for dt <= dx^2 / (6 alpha); `step` raises above it.
  * `HeatTets`: the tetrahedra of a `FemBody`, linear elements, lumped heat
    capacity, explicit. Conductance per element from the rest-shape
    gradients (rows of `dm_inv`); `max_dt` is a Gershgorin bound.

Both solve dT/dt = alpha lap(T) and are checked against the same closed form
(1D semi-infinite bar with a fixed hot end: T0 + (Ts - T0) erfc(x / (2
sqrt(alpha t))), `test_thermal`). Temperatures are Kelvin; setting one that
is <= 0 or non-finite raises at the boundary (the public input check), and
`step` leaves the field finite for any stable dt.

`expand` makes FEM elements expand with temperature: each tet's rest shape
is scaled by 1 + alpha_L (T - T_ref) (mean of its four nodes), by rescaling
`dm_inv` and the rest volume from the shape recorded at construction.
"""

from std.math import sqrt, isfinite
from geometry.vec import Real, Vec3
from geometry.mat import Mat3
from .fem import FemBody


def _check_kelvin(t: Real) raises:
    if not isfinite(t) or t <= 0:
        raise Error("thermal: temperature must be a finite value > 0 K, got " + String(t))


struct HeatGrid(Movable):
    var nx: Int
    var ny: Int
    var nz: Int
    var dx: Real
    var alpha: Real  # thermal diffusivity, m^2 / s
    var t: List[Real]
    var fixed: List[Bool]

    def __init__(out self, nx: Int, ny: Int, nz: Int, dx: Real, alpha: Real, t0: Real) raises:
        if nx < 1 or ny < 1 or nz < 1 or dx <= 0 or alpha <= 0:
            raise Error("HeatGrid: need >= 1 cell per axis, dx > 0, alpha > 0")
        _check_kelvin(t0)
        self.nx = nx
        self.ny = ny
        self.nz = nz
        self.dx = dx
        self.alpha = alpha
        self.t = List[Real](length=nx * ny * nz, fill=t0)
        self.fixed = List[Bool](length=nx * ny * nz, fill=False)

    def idx(self, i: Int, j: Int, k: Int) -> Int:
        return (k * self.ny + j) * self.nx + i

    def fix(mut self, i: Int, j: Int, k: Int, temp: Real) raises:
        _check_kelvin(temp)
        var c = self.idx(i, j, k)
        self.t[c] = temp
        self.fixed[c] = True

    def max_dt(self) -> Real:
        return self.dx * self.dx / (6 * self.alpha)

    def step(mut self, dt: Real) raises:
        if dt > self.max_dt():
            raise Error("HeatGrid.step: dt above the stability limit " + String(self.max_dt()))
        var r = self.alpha * dt / (self.dx * self.dx)
        var nt = self.t.copy()
        for k in range(self.nz):
            for j in range(self.ny):
                for i in range(self.nx):
                    var c = self.idx(i, j, k)
                    if self.fixed[c]:
                        continue
                    var tc = self.t[c]
                    var lap = Real(0)
                    lap += (self.t[c - 1] if i > 0 else tc) + (self.t[c + 1] if i < self.nx - 1 else tc) - 2 * tc
                    lap += (self.t[c - self.nx] if j > 0 else tc) + (self.t[c + self.nx] if j < self.ny - 1 else tc) - 2 * tc
                    var s = self.nx * self.ny
                    lap += (self.t[c - s] if k > 0 else tc) + (self.t[c + s] if k < self.nz - 1 else tc) - 2 * tc
                    nt[c] = tc + r * lap
        self.t = nt^

    def heat(self) -> Float64:
        """Sum of T over cells (proportional to stored heat for a uniform
        material): conserved with insulated faces and no fixed cells."""
        var s = Float64(0)
        for v in self.t:
            s += Float64(v)
        return s


struct HeatTets(Movable):
    var t: List[Real]  # per node, Kelvin
    var cap: List[Real]  # lumped capacity per node (volume share)
    var fixed: List[Bool]
    var alpha: Real
    var tet: List[Int]  # 4 per element
    var kel: List[Real]  # 16 per element: vol * grad Ni . grad Nj
    var rest_dm_inv: List[Mat3]
    var rest_vol: List[Real]
    var dt_max: Real  # Gershgorin bound, fixed with the mesh

    def __init__(out self, body: FemBody, alpha: Real, t0: Real) raises:
        if alpha <= 0:
            raise Error("HeatTets: alpha > 0")
        _check_kelvin(t0)
        var n = body.node_count()
        self.t = List[Real](length=n, fill=t0)
        self.cap = List[Real](length=n, fill=0)
        self.fixed = List[Bool](length=n, fill=False)
        self.alpha = alpha
        self.tet = List[Int]()
        self.kel = List[Real]()
        self.rest_dm_inv = List[Mat3]()
        self.rest_vol = List[Real]()
        for ref tt in body.tets:
            var ids: List[Int] = [tt.a, tt.b, tt.c, tt.d]
            # grad N_b, N_c, N_d are the rows of dm_inv; grad N_a = -their sum
            var g = List[Vec3]()
            var gb = Vec3(tt.dm_inv.get(0, 0), tt.dm_inv.get(0, 1), tt.dm_inv.get(0, 2), 0)
            var gc = Vec3(tt.dm_inv.get(1, 0), tt.dm_inv.get(1, 1), tt.dm_inv.get(1, 2), 0)
            var gd = Vec3(tt.dm_inv.get(2, 0), tt.dm_inv.get(2, 1), tt.dm_inv.get(2, 2), 0)
            g.append((gb + gc + gd) * Real(-1))
            g.append(gb)
            g.append(gc)
            g.append(gd)
            for a in range(4):
                self.tet.append(ids[a])
                self.cap[ids[a]] += tt.vol / 4
                for b in range(4):
                    var d = g[a][0] * g[b][0] + g[a][1] * g[b][1] + g[a][2] * g[b][2]
                    self.kel.append(tt.vol * d)
            self.rest_dm_inv.append(tt.dm_inv.copy())
            self.rest_vol.append(tt.vol)
        self.dt_max = 0
        self.dt_max = self._gershgorin()

    def fix(mut self, node: Int, temp: Real) raises:
        _check_kelvin(temp)
        self.t[node] = temp
        self.fixed[node] = True

    def max_dt(self) -> Real:
        """Gershgorin bound on the explicit step: dt <= 2 / max_i (sum_j
        |K_ij| alpha / C_i), computed once at construction (conductances
        are from the rest shape)."""
        return self.dt_max

    def _gershgorin(self) -> Real:
        var n = len(self.t)
        var row = List[Real](length=n, fill=0)
        for e in range(len(self.tet) // 4):
            for a in range(4):
                for b in range(4):
                    row[self.tet[4 * e + a]] += abs(self.kel[16 * e + 4 * a + b])
        var worst = Real(0)
        for i in range(n):
            if self.cap[i] > 0:
                worst = max(worst, self.alpha * row[i] / self.cap[i])
        return 2 / worst if worst > 0 else Real(1e30)

    def step(mut self, dt: Real) raises:
        if dt > self.max_dt():
            raise Error("HeatTets.step: dt above the stability bound " + String(self.max_dt()))
        var n = len(self.t)
        var flux = List[Real](length=n, fill=0)
        for e in range(len(self.tet) // 4):
            for a in range(4):
                var acc = Real(0)
                for b in range(4):
                    acc += self.kel[16 * e + 4 * a + b] * self.t[self.tet[4 * e + b]]
                flux[self.tet[4 * e + a]] -= acc
        for i in range(n):
            if self.fixed[i] or self.cap[i] <= 0:
                continue
            self.t[i] += dt * self.alpha * flux[i] / self.cap[i]

    def heat(self) -> Float64:
        var s = Float64(0)
        for i in range(len(self.t)):
            s += Float64(self.cap[i]) * Float64(self.t[i])
        return s

    def expand(self, mut body: FemBody, t_ref: Real, alpha_l: Real):
        """Scale each element's rest shape by 1 + alpha_l (T_mean - t_ref)."""
        for e in range(len(body.tets)):
            var tm = (self.t[self.tet[4 * e]] + self.t[self.tet[4 * e + 1]] + self.t[self.tet[4 * e + 2]] + self.t[self.tet[4 * e + 3]]) / 4
            var s = 1 + alpha_l * (tm - t_ref)
            var m = Mat3()
            for i in range(3):
                for j in range(3):
                    m.set(i, j, self.rest_dm_inv[e].get(i, j) / s)
            body.tets[e].dm_inv = m^
            body.tets[e].vol = self.rest_vol[e] * s * s * s
