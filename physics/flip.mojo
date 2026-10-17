"""FLIP free-surface water on a 2-D MAC grid with walls (ROADMAP 17.60;
Zhu & Bridson 2005).

Marker particles carry the water; the grid is only the pressure solver.
A closed box of nx x ny cells (spacing dx, origin 0): u on x faces
(nx + 1) x ny, v on y faces nx x (ny + 1), walls on all four sides. One
`step(dt)`:

  1. move the particles through the grid velocity (RK2), clamped inside
     the box half a cell from the walls;
  2. particle velocities to the faces (bilinear weights); keep a copy;
  3. gravity on the faces; wall faces 0;
  4. mark cells holding a particle as water, the rest air; solve
     -lap p = -div u dx^2 / dt over water cells only, p = 0 in air (the
     free surface), no flux through walls (`numerics.pcg`, matrix-free);
     subtract dt grad p on faces next to water;
  5. back to the particles: FLIP (add the grid change) blended with PIC
     (take the grid value), `flip` = 0.95 by default.

`pressure(i, j)` is the last solve's pressure (p / rho, m^2/s^2).
"""

from std.math import floor, sqrt
from geometry.vec import Real
from numerics.sparse import LinearOperator
from numerics.cg import pcg, CgResult

comptime _AIR = 0
comptime _WATER = 1


def _splat(mut f: List[Real], mut wsum: List[Real], w: Int, h: Int, dx: Real, x: Real, y: Real, ox: Real, oy: Real, val: Real):
    """Bilinear weights of (x, y) on a staggered grid w x h whose (i, j)
    sample sits at ((i + ox) dx, (j + oy) dx): add val * weight and weight."""
    var gx = min(max(x / dx - ox, Real(0)), Real(w - 1) - 1e-4)
    var gy = min(max(y / dx - oy, Real(0)), Real(h - 1) - 1e-4)
    var i = Int(floor(gx))
    var j = Int(floor(gy))
    var ax = gx - Real(i)
    var ay = gy - Real(j)
    var ws = [(1 - ax) * (1 - ay), ax * (1 - ay), (1 - ax) * ay, ax * ay]
    var ks = [j * w + i, j * w + i + 1, (j + 1) * w + i, (j + 1) * w + i + 1]
    for q in range(4):
        f[ks[q]] += ws[q] * val
        wsum[ks[q]] += ws[q]


struct _WaterLaplacian(LinearOperator, Movable):
    """-lap over water cells (dx^2 = 1): a water neighbour contributes -p_n,
    an air neighbour p = 0, a wall nothing (and no diagonal term)."""

    var nx: Int
    var ny: Int
    var cell_of: List[Int]  # water index -> cell
    var index: List[Int]  # cell -> water index, -1 for air

    def __init__(out self, nx: Int, ny: Int, var cell_of: List[Int], var index: List[Int]):
        self.nx = nx
        self.ny = ny
        self.cell_of = cell_of^
        self.index = index^

    def size(self) -> Int:
        return len(self.cell_of)

    def _diag(self, c: Int) -> Real:
        var i = c % self.nx
        var j = c // self.nx
        var d = Real(0)
        if i > 0:
            d += 1
        if i < self.nx - 1:
            d += 1
        if j > 0:
            d += 1
        if j < self.ny - 1:
            d += 1
        return d

    def apply(self, x: List[Real], mut out: List[Real]):
        for w in range(len(self.cell_of)):
            var c = self.cell_of[w]
            var i = c % self.nx
            var j = c // self.nx
            var acc = self._diag(c) * x[w]
            if i > 0 and self.index[c - 1] >= 0:
                acc -= x[self.index[c - 1]]
            if i < self.nx - 1 and self.index[c + 1] >= 0:
                acc -= x[self.index[c + 1]]
            if j > 0 and self.index[c - self.nx] >= 0:
                acc -= x[self.index[c - self.nx]]
            if j < self.ny - 1 and self.index[c + self.nx] >= 0:
                acc -= x[self.index[c + self.nx]]
            out[w] = acc

    def diagonal(self, mut out: List[Real]):
        for w in range(len(self.cell_of)):
            out[w] = self._diag(self.cell_of[w])


struct FlipWater2(Movable):
    var nx: Int
    var ny: Int
    var dx: Real
    var gravity: Real  # along -y
    var flip: Real
    var px: List[Real]
    var py: List[Real]
    var pu: List[Real]
    var pv: List[Real]
    var u: List[Real]  # [j * (nx + 1) + i], face (i dx, (j + 1/2) dx)
    var v: List[Real]  # [j * nx + i], face ((i + 1/2) dx, j dx)
    var mark: List[Int]
    var p: List[Real]  # per cell, last solve (0 in air)
    var last: CgResult

    def __init__(out self, nx: Int, ny: Int, dx: Real, gravity: Real = 9.8) raises:
        if nx < 2 or ny < 2 or not (dx > 0):
            raise Error("FlipWater2: need >= 2 x 2 cells and dx > 0")
        self.nx = nx
        self.ny = ny
        self.dx = dx
        self.gravity = gravity
        self.flip = 0.95
        self.px = List[Real]()
        self.py = List[Real]()
        self.pu = List[Real]()
        self.pv = List[Real]()
        self.u = List[Real](length=(nx + 1) * ny, fill=0)
        self.v = List[Real](length=nx * (ny + 1), fill=0)
        self.mark = List[Int](length=nx * ny, fill=_AIR)
        self.p = List[Real](length=nx * ny, fill=0)
        self.last = CgResult(True, False, 0, 0)

    def fill_box(mut self, x0: Real, y0: Real, x1: Real, y1: Real, per_axis: Int = 2):
        """Seed per_axis^2 particles per cell (jittered on a sub-grid) in
        the rectangle."""
        var s = self.dx / Real(per_axis)
        var nxp = Int((x1 - x0) / s)
        var nyp = Int((y1 - y0) / s)
        for j in range(nyp):
            for i in range(nxp):
                self.px.append(x0 + (Real(i) + 0.5) * s)
                self.py.append(y0 + (Real(j) + 0.5) * s)
                self.pu.append(0)
                self.pv.append(0)

    def count(self) -> Int:
        return len(self.px)

    def pressure(self, i: Int, j: Int) -> Real:
        return self.p[j * self.nx + i]

    # -- grid sampling --------------------------------------------------------------------
    def _sample(self, f: List[Real], w: Int, h: Int, x: Real, y: Real, ox: Real, oy: Real) -> Real:
        var gx = min(max(x / self.dx - ox, Real(0)), Real(w - 1) - 1e-4)
        var gy = min(max(y / self.dx - oy, Real(0)), Real(h - 1) - 1e-4)
        var i = Int(floor(gx))
        var j = Int(floor(gy))
        var ax = gx - Real(i)
        var ay = gy - Real(j)
        var lo = f[j * w + i] * (1 - ax) + f[j * w + i + 1] * ax
        var hi = f[(j + 1) * w + i] * (1 - ax) + f[(j + 1) * w + i + 1] * ax
        return lo * (1 - ay) + hi * ay

    def velocity(self, x: Real, y: Real) -> Tuple[Real, Real]:
        return (
            self._sample(self.u, self.nx + 1, self.ny, x, y, 0, 0.5),
            self._sample(self.v, self.nx, self.ny + 1, x, y, 0.5, 0),
        )

    # -- step -------------------------------------------------------------------------------
    def _advect(mut self, dt: Real):
        var lo = 0.5 * self.dx
        var hix = Real(self.nx) * self.dx - lo
        var hiy = Real(self.ny) * self.dx - lo
        for k in range(len(self.px)):
            var v0 = self.velocity(self.px[k], self.py[k])
            var vm = self.velocity(self.px[k] + 0.5 * dt * v0[0], self.py[k] + 0.5 * dt * v0[1])
            self.px[k] = min(max(self.px[k] + dt * vm[0], lo), hix)
            self.py[k] = min(max(self.py[k] + dt * vm[1], lo), hiy)

    def _to_grid(mut self):
        var nx = self.nx
        var ny = self.ny
        var wu = List[Real](length=(nx + 1) * ny, fill=0)
        var wv = List[Real](length=nx * (ny + 1), fill=0)
        for q in range(len(self.u)):
            self.u[q] = 0
        for q in range(len(self.v)):
            self.v[q] = 0
        for k in range(len(self.px)):
            _splat(self.u, wu, nx + 1, ny, self.dx, self.px[k], self.py[k], 0, 0.5, self.pu[k])
            _splat(self.v, wv, nx, ny + 1, self.dx, self.px[k], self.py[k], 0.5, 0, self.pv[k])
        for q in range(len(self.u)):
            if wu[q] > 0:
                self.u[q] /= wu[q]
        for q in range(len(self.v)):
            if wv[q] > 0:
                self.v[q] /= wv[q]

    def _walls(mut self):
        var nx = self.nx
        var ny = self.ny
        for j in range(ny):
            self.u[j * (nx + 1)] = 0
            self.u[j * (nx + 1) + nx] = 0
        for i in range(nx):
            self.v[i] = 0
            self.v[ny * nx + i] = 0

    def _mark(mut self):
        for q in range(len(self.mark)):
            self.mark[q] = _AIR
        for k in range(len(self.px)):
            var i = min(max(Int(self.px[k] / self.dx), 0), self.nx - 1)
            var j = min(max(Int(self.py[k] / self.dx), 0), self.ny - 1)
            self.mark[j * self.nx + i] = _WATER

    def _project(mut self, dt: Real) -> CgResult:
        var nx = self.nx
        var ny = self.ny
        var index = List[Int](length=nx * ny, fill=-1)
        var cell_of = List[Int]()
        for c in range(nx * ny):
            if self.mark[c] == _WATER:
                index[c] = len(cell_of)
                cell_of.append(c)
        var nw = len(cell_of)
        var rhs = List[Real](length=nw, fill=0)
        for w in range(nw):
            var c = cell_of[w]
            var i = c % nx
            var j = c // nx
            var div = (self.u[j * (nx + 1) + i + 1] - self.u[j * (nx + 1) + i] + self.v[(j + 1) * nx + i] - self.v[j * nx + i]) / self.dx
            rhs[w] = -div * self.dx * self.dx / dt
        var x = List[Real](length=nw, fill=0)
        for w in range(nw):
            x[w] = self.p[cell_of[w]]
        var op = _WaterLaplacian(nx, ny, cell_of.copy(), index.copy())
        var r = pcg(op, rhs, x, 1e-6, 4 * nw + 10)
        for c in range(nx * ny):
            self.p[c] = 0
        for w in range(nw):
            self.p[cell_of[w]] = x[w]
        # gradient on interior faces next to water (air p = 0)
        var s = dt / self.dx
        for j in range(ny):
            for i in range(1, nx):
                var a = j * nx + i - 1
                var b = j * nx + i
                if self.mark[a] == _WATER or self.mark[b] == _WATER:
                    self.u[j * (nx + 1) + i] -= s * (self.p[b] - self.p[a])
        for j in range(1, ny):
            for i in range(nx):
                var a = (j - 1) * nx + i
                var b = j * nx + i
                if self.mark[a] == _WATER or self.mark[b] == _WATER:
                    self.v[j * nx + i] -= s * (self.p[b] - self.p[a])
        return r

    def step(mut self, dt: Real) raises:
        if not (dt > 0):
            raise Error("FlipWater2.step: dt must be > 0")
        self._advect(dt)
        self._to_grid()
        var u0 = self.u.copy()
        var v0 = self.v.copy()
        for q in range(len(self.v)):
            self.v[q] -= self.gravity * dt
        self._walls()
        self._mark()
        self.last = self._project(dt)
        self._walls()
        for k in range(len(self.px)):
            var gu = self._sample(self.u, self.nx + 1, self.ny, self.px[k], self.py[k], 0, 0.5)
            var gv = self._sample(self.v, self.nx, self.ny + 1, self.px[k], self.py[k], 0.5, 0)
            var ou = self._sample(u0, self.nx + 1, self.ny, self.px[k], self.py[k], 0, 0.5)
            var ov = self._sample(v0, self.nx, self.ny + 1, self.px[k], self.py[k], 0.5, 0)
            self.pu[k] = self.flip * (self.pu[k] + gu - ou) + (1 - self.flip) * gu
            self.pv[k] = self.flip * (self.pv[k] + gv - ov) + (1 - self.flip) * gv

    def max_dt(self, cfl: Real = 1.0) -> Real:
        var m = Real(0)
        for k in range(len(self.pu)):
            m = max(m, abs(self.pu[k]) + abs(self.pv[k]))
        return cfl * self.dx / m if m > 0 else Real(1e30)
