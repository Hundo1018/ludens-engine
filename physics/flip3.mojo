"""FLIP free-surface water on a 3-D MAC grid with walls (ROADMAP 17.60;
Zhu & Bridson 2005): `FlipWater2` in three dimensions.

A closed box of nx x ny x nz cells (spacing dx, origin 0): u on x faces
(nx + 1) x ny x nz, v on y faces nx x (ny + 1) x nz, w on z faces
nx x ny x (nz + 1), walls on all six sides, gravity along -y. One
`step(dt)`, as in 2-D:

  1. move the particles through the grid velocity (RK2, trilinear),
     clamped inside the box half a cell from the walls;
  2. particle velocities to the faces (trilinear weights); keep a copy;
  3. gravity on the v faces; wall faces 0;
  4. cells holding a particle are water, the rest air; solve
     -lap p = -div u dx^2 / dt over water cells only (7-point, p = 0 in
     air, no flux through walls; `numerics.pcg`, matrix-free), subtract
     dt grad p on faces next to water;
  5. back to the particles: FLIP (add the grid change) blended with PIC,
     `flip` = 0.95.

`test_flip3`: still water stays still and hydrostatic; a dam break in a
thin slab follows the 2-D solver's front.
"""

from std.math import floor
from geometry.vec import Real
from numerics.sparse import LinearOperator
from numerics.cg import pcg, CgResult

comptime _AIR = 0
comptime _WATER = 1


def _weights(x: Real, y: Real, z: Real, dx: Real, w: Int, h: Int, d: Int, ox: Real, oy: Real, oz: Real) -> Tuple[Int, Int, Int, Real, Real, Real]:
    """Base node and fractions of (x, y, z) on a staggered w x h x d grid
    whose (i, j, k) sample sits at ((i + ox) dx, (j + oy) dx, (k + oz) dx)."""
    var gx = min(max(x / dx - ox, Real(0)), Real(w - 1) - 1e-4)
    var gy = min(max(y / dx - oy, Real(0)), Real(h - 1) - 1e-4)
    var gz = min(max(z / dx - oz, Real(0)), Real(d - 1) - 1e-4)
    var i = Int(floor(gx))
    var j = Int(floor(gy))
    var k = Int(floor(gz))
    return (i, j, k, gx - Real(i), gy - Real(j), gz - Real(k))


def _splat3(mut f: List[Real], mut wsum: List[Real], w: Int, h: Int, d: Int, dx: Real, x: Real, y: Real, z: Real, ox: Real, oy: Real, oz: Real, val: Real):
    var b = _weights(x, y, z, dx, w, h, d, ox, oy, oz)
    for q in range(8):
        var di = q % 2
        var dj = (q // 2) % 2
        var dk = q // 4
        var wq = (b[3] if di == 1 else 1 - b[3]) * (b[4] if dj == 1 else 1 - b[4]) * (b[5] if dk == 1 else 1 - b[5])
        var idx = ((b[2] + dk) * h + b[1] + dj) * w + b[0] + di
        f[idx] += wq * val
        wsum[idx] += wq


def _sample3(f: List[Real], w: Int, h: Int, d: Int, dx: Real, x: Real, y: Real, z: Real, ox: Real, oy: Real, oz: Real) -> Real:
    var b = _weights(x, y, z, dx, w, h, d, ox, oy, oz)
    var acc = Real(0)
    for q in range(8):
        var di = q % 2
        var dj = (q // 2) % 2
        var dk = q // 4
        var wq = (b[3] if di == 1 else 1 - b[3]) * (b[4] if dj == 1 else 1 - b[4]) * (b[5] if dk == 1 else 1 - b[5])
        acc += wq * f[((b[2] + dk) * h + b[1] + dj) * w + b[0] + di]
    return acc


struct _WaterLaplacian3(LinearOperator, Movable):
    """-lap (dx^2 = 1) over the water cells: Neumann at walls, Dirichlet 0
    at air cells."""

    var nx: Int
    var ny: Int
    var nz: Int
    var cell_of: List[Int]
    var index: List[Int]

    def __init__(out self, nx: Int, ny: Int, nz: Int, var cell_of: List[Int], var index: List[Int]):
        self.nx = nx
        self.ny = ny
        self.nz = nz
        self.cell_of = cell_of^
        self.index = index^

    def size(self) -> Int:
        return len(self.cell_of)

    def _diag(self, c: Int) -> Real:
        var i = c % self.nx
        var j = (c // self.nx) % self.ny
        var k = c // (self.nx * self.ny)
        var d = Real(0)
        if i > 0:
            d += 1
        if i < self.nx - 1:
            d += 1
        if j > 0:
            d += 1
        if j < self.ny - 1:
            d += 1
        if k > 0:
            d += 1
        if k < self.nz - 1:
            d += 1
        return d

    def apply(self, x: List[Real], mut out: List[Real]):
        var sx = 1
        var sy = self.nx
        var sz = self.nx * self.ny
        for w in range(len(self.cell_of)):
            var c = self.cell_of[w]
            var i = c % self.nx
            var j = (c // self.nx) % self.ny
            var k = c // sz
            var acc = self._diag(c) * x[w]
            if i > 0 and self.index[c - sx] >= 0:
                acc -= x[self.index[c - sx]]
            if i < self.nx - 1 and self.index[c + sx] >= 0:
                acc -= x[self.index[c + sx]]
            if j > 0 and self.index[c - sy] >= 0:
                acc -= x[self.index[c - sy]]
            if j < self.ny - 1 and self.index[c + sy] >= 0:
                acc -= x[self.index[c + sy]]
            if k > 0 and self.index[c - sz] >= 0:
                acc -= x[self.index[c - sz]]
            if k < self.nz - 1 and self.index[c + sz] >= 0:
                acc -= x[self.index[c + sz]]
            out[w] = acc

    def diagonal(self, mut out: List[Real]):
        for w in range(len(self.cell_of)):
            out[w] = self._diag(self.cell_of[w])


struct FlipWater3(Movable):
    var nx: Int
    var ny: Int
    var nz: Int
    var dx: Real
    var gravity: Real  # along -y
    var flip: Real
    var px: List[Real]
    var py: List[Real]
    var pz: List[Real]
    var pu: List[Real]
    var pv: List[Real]
    var pw: List[Real]
    var u: List[Real]  # [(k ny + j)(nx + 1) + i]
    var v: List[Real]  # [(k (ny + 1) + j) nx + i]
    var w: List[Real]  # [(k ny + j) nx + i], k in [0, nz]
    var mark: List[Int]
    var p: List[Real]
    var last: CgResult

    def __init__(out self, nx: Int, ny: Int, nz: Int, dx: Real, gravity: Real = 9.8) raises:
        if nx < 2 or ny < 2 or nz < 2 or not (dx > 0):
            raise Error("FlipWater3: need >= 2 x 2 x 2 cells and dx > 0")
        self.nx = nx
        self.ny = ny
        self.nz = nz
        self.dx = dx
        self.gravity = gravity
        self.flip = 0.95
        self.px = List[Real]()
        self.py = List[Real]()
        self.pz = List[Real]()
        self.pu = List[Real]()
        self.pv = List[Real]()
        self.pw = List[Real]()
        self.u = List[Real](length=(nx + 1) * ny * nz, fill=0)
        self.v = List[Real](length=nx * (ny + 1) * nz, fill=0)
        self.w = List[Real](length=nx * ny * (nz + 1), fill=0)
        self.mark = List[Int](length=nx * ny * nz, fill=_AIR)
        self.p = List[Real](length=nx * ny * nz, fill=0)
        self.last = CgResult(True, False, 0, 0)

    def fill_box(mut self, x0: Real, y0: Real, z0: Real, x1: Real, y1: Real, z1: Real, per_axis: Int = 2):
        """Seed per_axis^3 particles per cell (on a sub-grid) in the box."""
        var s = self.dx / Real(per_axis)
        var nxp = Int((x1 - x0) / s)
        var nyp = Int((y1 - y0) / s)
        var nzp = Int((z1 - z0) / s)
        for k in range(nzp):
            for j in range(nyp):
                for i in range(nxp):
                    self.px.append(x0 + (Real(i) + 0.5) * s)
                    self.py.append(y0 + (Real(j) + 0.5) * s)
                    self.pz.append(z0 + (Real(k) + 0.5) * s)
                    self.pu.append(0)
                    self.pv.append(0)
                    self.pw.append(0)

    def count(self) -> Int:
        return len(self.px)

    def pressure(self, i: Int, j: Int, k: Int) -> Real:
        return self.p[(k * self.ny + j) * self.nx + i]

    def velocity(self, x: Real, y: Real, z: Real) -> Tuple[Real, Real, Real]:
        var nx = self.nx
        var ny = self.ny
        var nz = self.nz
        return (
            _sample3(self.u, nx + 1, ny, nz, self.dx, x, y, z, 0, 0.5, 0.5),
            _sample3(self.v, nx, ny + 1, nz, self.dx, x, y, z, 0.5, 0, 0.5),
            _sample3(self.w, nx, ny, nz + 1, self.dx, x, y, z, 0.5, 0.5, 0),
        )

    def _advect(mut self, dt: Real):
        var lo = 0.5 * self.dx
        var hx = Real(self.nx) * self.dx - lo
        var hy = Real(self.ny) * self.dx - lo
        var hz = Real(self.nz) * self.dx - lo
        for k in range(len(self.px)):
            var v0 = self.velocity(self.px[k], self.py[k], self.pz[k])
            var vm = self.velocity(self.px[k] + 0.5 * dt * v0[0], self.py[k] + 0.5 * dt * v0[1], self.pz[k] + 0.5 * dt * v0[2])
            self.px[k] = min(max(self.px[k] + dt * vm[0], lo), hx)
            self.py[k] = min(max(self.py[k] + dt * vm[1], lo), hy)
            self.pz[k] = min(max(self.pz[k] + dt * vm[2], lo), hz)

    def _to_grid(mut self):
        var nx = self.nx
        var ny = self.ny
        var nz = self.nz
        var wu = List[Real](length=len(self.u), fill=0)
        var wv = List[Real](length=len(self.v), fill=0)
        var ww = List[Real](length=len(self.w), fill=0)
        for q in range(len(self.u)):
            self.u[q] = 0
        for q in range(len(self.v)):
            self.v[q] = 0
        for q in range(len(self.w)):
            self.w[q] = 0
        for k in range(len(self.px)):
            _splat3(self.u, wu, nx + 1, ny, nz, self.dx, self.px[k], self.py[k], self.pz[k], 0, 0.5, 0.5, self.pu[k])
            _splat3(self.v, wv, nx, ny + 1, nz, self.dx, self.px[k], self.py[k], self.pz[k], 0.5, 0, 0.5, self.pv[k])
            _splat3(self.w, ww, nx, ny, nz + 1, self.dx, self.px[k], self.py[k], self.pz[k], 0.5, 0.5, 0, self.pw[k])
        for q in range(len(self.u)):
            if wu[q] > 0:
                self.u[q] /= wu[q]
        for q in range(len(self.v)):
            if wv[q] > 0:
                self.v[q] /= wv[q]
        for q in range(len(self.w)):
            if ww[q] > 0:
                self.w[q] /= ww[q]

    def _walls(mut self):
        var nx = self.nx
        var ny = self.ny
        var nz = self.nz
        for k in range(nz):
            for j in range(ny):
                self.u[(k * ny + j) * (nx + 1)] = 0
                self.u[(k * ny + j) * (nx + 1) + nx] = 0
        for k in range(nz):
            for i in range(nx):
                self.v[(k * (ny + 1)) * nx + i] = 0
                self.v[(k * (ny + 1) + ny) * nx + i] = 0
        for j in range(ny):
            for i in range(nx):
                self.w[j * nx + i] = 0
                self.w[(nz * ny + j) * nx + i] = 0

    def _mark(mut self):
        for q in range(len(self.mark)):
            self.mark[q] = _AIR
        for k in range(len(self.px)):
            var i = min(max(Int(self.px[k] / self.dx), 0), self.nx - 1)
            var j = min(max(Int(self.py[k] / self.dx), 0), self.ny - 1)
            var l = min(max(Int(self.pz[k] / self.dx), 0), self.nz - 1)
            self.mark[(l * self.ny + j) * self.nx + i] = _WATER

    def _project(mut self, dt: Real) -> CgResult:
        var nx = self.nx
        var ny = self.ny
        var nz = self.nz
        var nc = nx * ny * nz
        var index = List[Int](length=nc, fill=-1)
        var cell_of = List[Int]()
        for c in range(nc):
            if self.mark[c] == _WATER:
                index[c] = len(cell_of)
                cell_of.append(c)
        var nw = len(cell_of)
        var rhs = List[Real](length=nw, fill=0)
        for q in range(nw):
            var c = cell_of[q]
            var i = c % nx
            var j = (c // nx) % ny
            var k = c // (nx * ny)
            var div = (
                self.u[(k * ny + j) * (nx + 1) + i + 1] - self.u[(k * ny + j) * (nx + 1) + i]
                + self.v[(k * (ny + 1) + j + 1) * nx + i] - self.v[(k * (ny + 1) + j) * nx + i]
                + self.w[((k + 1) * ny + j) * nx + i] - self.w[(k * ny + j) * nx + i]
            ) / self.dx
            rhs[q] = -div * self.dx * self.dx / dt
        var x = List[Real](length=nw, fill=0)
        for q in range(nw):
            x[q] = self.p[cell_of[q]]
        var op = _WaterLaplacian3(nx, ny, nz, cell_of.copy(), index.copy())
        var r = pcg(op, rhs, x, 1e-6, 4 * nw + 10)
        for c in range(nc):
            self.p[c] = 0
        for q in range(nw):
            self.p[cell_of[q]] = x[q]
        var s = dt / self.dx
        for k in range(nz):
            for j in range(ny):
                for i in range(1, nx):
                    var a = (k * ny + j) * nx + i - 1
                    var b = a + 1
                    if self.mark[a] == _WATER or self.mark[b] == _WATER:
                        self.u[(k * ny + j) * (nx + 1) + i] -= s * (self.p[b] - self.p[a])
        for k in range(nz):
            for j in range(1, ny):
                for i in range(nx):
                    var a = (k * ny + j - 1) * nx + i
                    var b = (k * ny + j) * nx + i
                    if self.mark[a] == _WATER or self.mark[b] == _WATER:
                        self.v[(k * (ny + 1) + j) * nx + i] -= s * (self.p[b] - self.p[a])
        for k in range(1, nz):
            for j in range(ny):
                for i in range(nx):
                    var a = ((k - 1) * ny + j) * nx + i
                    var b = (k * ny + j) * nx + i
                    if self.mark[a] == _WATER or self.mark[b] == _WATER:
                        self.w[(k * ny + j) * nx + i] -= s * (self.p[b] - self.p[a])
        return r

    def step(mut self, dt: Real) raises:
        if not (dt > 0):
            raise Error("FlipWater3.step: dt must be > 0")
        var nx = self.nx
        var ny = self.ny
        var nz = self.nz
        self._advect(dt)
        self._to_grid()
        var u0 = self.u.copy()
        var v0 = self.v.copy()
        var w0 = self.w.copy()
        for q in range(len(self.v)):
            self.v[q] -= self.gravity * dt
        self._walls()
        self._mark()
        self.last = self._project(dt)
        self._walls()
        for k in range(len(self.px)):
            var x = self.px[k]
            var y = self.py[k]
            var z = self.pz[k]
            var gu = _sample3(self.u, nx + 1, ny, nz, self.dx, x, y, z, 0, 0.5, 0.5)
            var gv = _sample3(self.v, nx, ny + 1, nz, self.dx, x, y, z, 0.5, 0, 0.5)
            var gw = _sample3(self.w, nx, ny, nz + 1, self.dx, x, y, z, 0.5, 0.5, 0)
            var ou = _sample3(u0, nx + 1, ny, nz, self.dx, x, y, z, 0, 0.5, 0.5)
            var ov = _sample3(v0, nx, ny + 1, nz, self.dx, x, y, z, 0.5, 0, 0.5)
            var ow = _sample3(w0, nx, ny, nz + 1, self.dx, x, y, z, 0.5, 0.5, 0)
            self.pu[k] = self.flip * (self.pu[k] + gu - ou) + (1 - self.flip) * gu
            self.pv[k] = self.flip * (self.pv[k] + gv - ov) + (1 - self.flip) * gv
            self.pw[k] = self.flip * (self.pw[k] + gw - ow) + (1 - self.flip) * gw

    def max_dt(self, cfl: Real = 1.0) -> Real:
        var m = Real(0)
        for k in range(len(self.pu)):
            m = max(m, abs(self.pu[k]) + abs(self.pv[k]) + abs(self.pw[k]))
        return cfl * self.dx / m if m > 0 else Real(1e30)
