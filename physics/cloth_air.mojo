"""Cloth <-> lattice air, two-way (ROADMAP 17.61: "cloth's reaction on the
LBM flow -- blocking, wake -- written back to the fluid").

`ClothAir` owns an `Lbm` (lattice node (x, y, z) at origin + (x, y, z) dx,
one lattice step = `dt` seconds, physical density `rho`) and couples a
`MeshCloth` to it per vertex, as immersed points:

  * the air velocity u at a vertex is the trilinear interpolation of the
    lattice velocity (periodic wrap), scaled to m/s by dx / dt;
  * the vertex gets normal drag, F = k A n (n . (u - v)), with A the
    vertex's share of the triangle areas and n its area-weighted normal,
    integrated implicitly along n (no overshoot for any k dt / m):
    v_n <- (v_n + a u_n) / (1 + a), a = k A dt / m. A pinned vertex
    (inverse mass 0) does not move but still feels F = k A n (n . u)
    -- it is the impulse a fixed sheet takes from the flow;
  * two-way: minus each vertex's impulse J goes to the 8 lattice cells
    around it with the same trilinear weights, as lattice momentum
    J dt / (rho dx^4) (`Lbm.add_cell_force`), so the air loses what the
    cloth gains; one-way (`two_way = False`) only the cloth is pushed.

`step(cloth, gravity)`: drag (with the air at the start of the step), the
cloth's own step (`advance`), the lattice step. `cloth_impulse` and
`air_impulse` sum what each side received (N s); in two-way mode they are
equal and opposite by construction, and the air's momentum changes by
exactly `air_impulse` (a periodic box; `air_momentum`).
"""

from std.math import sqrt, floor
from geometry.vec import Real, Vec3, cross, dot
from fluid.lbm import Lbm
from .cloth import MeshCloth


struct ClothAir(Movable):
    var lbm: Lbm
    var origin: Vec3
    var dx: Real
    var dt: Real
    var rho: Real
    var k: Real  # drag coefficient, kg / (m^2 s)
    var two_way: Bool
    var cloth_impulse: Vec3
    var air_impulse: Vec3

    def __init__(out self, var lbm: Lbm, origin: Vec3, dx: Real, dt: Real, rho: Real, k: Real, two_way: Bool = True) raises:
        if not (dx > 0) or not (dt > 0) or not (rho > 0) or not (k >= 0):
            raise Error("ClothAir: dx, dt, rho > 0 and k >= 0")
        self.lbm = lbm^
        self.origin = origin
        self.dx = dx
        self.dt = dt
        self.rho = rho
        self.k = k
        self.two_way = two_way
        self.cloth_impulse = Vec3(0, 0, 0, 0)
        self.air_impulse = Vec3(0, 0, 0, 0)

    def _corners(self, p: Vec3) -> Tuple[List[Int], List[Real]]:
        """The 8 lattice cells around p and their trilinear weights."""
        var g = (p - self.origin) * (1 / self.dx)
        var nx = self.lbm.nx
        var ny = self.lbm.ny
        var nz = self.lbm.nz
        var gx = floor(g[0])
        var gy = floor(g[1])
        var gz = floor(g[2])
        var fx = g[0] - gx
        var fy = g[1] - gy
        var fz = g[2] - gz
        var x0 = Int(gx)
        var y0 = Int(gy)
        var z0 = Int(gz)
        var cells = List[Int]()
        var w = List[Real]()
        for dz in range(2):
            for dy in range(2):
                for dxx in range(2):
                    var cx = ((x0 + dxx) % nx + nx) % nx
                    var cy = ((y0 + dy) % ny + ny) % ny
                    var cz = ((z0 + dz) % nz + nz) % nz
                    cells.append(self.lbm.idx(cx, cy, cz))
                    var wx = fx if dxx == 1 else 1 - fx
                    var wy = fy if dy == 1 else 1 - fy
                    var wz = fz if dz == 1 else 1 - fz
                    w.append(wx * wy * wz)
        return (cells^, w^)

    def air_velocity(self, p: Vec3) -> Vec3:
        """Air velocity at p, m/s."""
        var cw = self._corners(p)
        var u = Vec3(0, 0, 0, 0)
        for q in range(8):
            u = u + self.lbm.velocity(cw[0][q]) * cw[1][q]
        return u * (self.dx / self.dt)

    def air_momentum(self) -> Vec3:
        """Sum of rho u over the fluid cells, N s (rho u as the lattice
        stores it, sum_i f_i c_i)."""
        var m = Vec3(0, 0, 0, 0)
        for c in range(self.lbm.cells()):
            m = m + self.lbm.velocity(c) * self.lbm.density(c)
        var s = self.rho * self.dx * self.dx * self.dx * self.dx / self.dt
        return m * s

    def step(mut self, mut cloth: MeshCloth, gravity: Vec3):
        var n = len(cloth.x)
        var area = List[Real](length=n, fill=0)
        var normal = List[Vec3](length=n, fill=Vec3(0, 0, 0, 0))
        for t in range(len(cloth.tris) // 3):
            var a = cloth.tris[3 * t]
            var b = cloth.tris[3 * t + 1]
            var c = cloth.tris[3 * t + 2]
            var nn = cross(cloth.x[b] - cloth.x[a], cloth.x[c] - cloth.x[a])
            var ar = 0.5 * sqrt(dot(nn, nn)) / 3
            for v in [a, b, c]:
                area[v] += ar
                normal[v] = normal[v] + nn
        self.lbm.clear_cell_force()
        var to_lat = self.dt / (self.rho * self.dx * self.dx * self.dx * self.dx)
        for i in range(n):
            var nl = sqrt(dot(normal[i], normal[i]))
            if nl <= 0 or area[i] <= 0:
                continue
            var nrm = normal[i] / nl
            var u = self.air_velocity(cloth.x[i])
            var j: Vec3
            if cloth.w[i] > 0:
                var m = 1 / cloth.w[i]
                var a = self.k * area[i] * self.dt / m
                var vn = dot(cloth.v[i], nrm)
                var vn_new = (vn + a * dot(u, nrm)) / (1 + a)
                j = nrm * (m * (vn_new - vn))
                cloth.v[i] = cloth.v[i] + nrm * (vn_new - vn)
            else:
                j = nrm * (self.k * area[i] * self.dt * dot(u - cloth.v[i], nrm))
            self.cloth_impulse = self.cloth_impulse + j
            if self.two_way:
                self.air_impulse = self.air_impulse - j
                var cw = self._corners(cloth.x[i])
                var cs = cw[0].copy()
                var ws = cw[1].copy()
                for q in range(8):
                    self.lbm.add_cell_force(cs[q], j * (-to_lat * ws[q]))
        cloth.advance(self.dt, gravity)
        self.lbm.step()
