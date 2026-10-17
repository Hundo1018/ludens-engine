"""Two (or more) immiscible liquids of different density in one SPH
(ROADMAP 17.61: multiphase, "oil and water layering").

The single-phase solvers (`pbf`, `sph`) use one rest density, so a
heavy and a light liquid cannot share them: standard SPH density
sum_j m_j W_ij smears a density jump over the kernel radius and the
interface pressure is wrong (spurious tension, Solenthaler & Pajarola
2008). `MultiphaseSph` uses their number-density form instead:

    delta_i = sum_j W_ij            (particles per volume)
    rho_i   = m_i delta_i           (own mass only: no smearing across
                                     the interface)
    p_i     = B (rho_i / rho0_i - 1), clamped at 0 (no tension)
    a_i     = -(1 / m_i) sum_j (p_i / delta_i^2 + p_j / delta_j^2) grad W_ij
              + Monaghan artificial viscosity + gravity

with each particle carrying its own rest density rho0_i and mass
m_i = rho0_i / delta_ref (delta_ref: the number density of a resting
interior lattice of spacing s, so a resting lattice has p = 0), a light
particle in a heavy liquid feels the heavy liquid's pressure gradient on
its volume and its own weight on its mass: buoyancy. Cubic-spline kernel
of radius 2h, h = 1.2 s; neighbours from a hash grid of cell 2h each step;
symplectic Euler. Walls: each box face adds the number density of a
virtual particle lattice beyond it (tabulated against distance at
construction) and pushes with the particle's own pressure through that
term's gradient, so particles near a wall are not short of neighbours
(without it a 4-particle-deep box compacted by 45 % against its walls);
positions are also clamped to the box. B is shared by all phases (one
sound speed); dt must satisfy the CFL bound 0.25 h / c,
c = sqrt(B / rho0_min) (`step` raises above it).
"""

from std.math import sqrt, floor
from geometry.vec import Real, Vec3, dot


def _w(r: Real, h: Real) -> Real:
    var q = r / h
    var sigma = 1 / (Real(3.14159265358979) * h * h * h)
    if q >= 2:
        return 0
    if q < 1:
        return sigma * (1 - 1.5 * q * q + 0.75 * q * q * q)
    var a = 2 - q
    return sigma * 0.25 * a * a * a


def _dw(r: Real, h: Real) -> Real:
    """dW/dr (<= 0)."""
    var q = r / h
    var sigma = 1 / (Real(3.14159265358979) * h * h * h)
    if q >= 2:
        return 0
    if q < 1:
        return sigma * (-3 * q + 2.25 * q * q) / h
    var a = 2 - q
    return -sigma * 0.75 * a * a / h


comptime _TAB = 64


def _key(i: Int, j: Int, k: Int) -> Int:
    return (i * 73856093) ^ (j * 19349663) ^ (k * 83492791)


struct MultiphaseSph(Movable):
    var x: List[Vec3]
    var v: List[Vec3]
    var mass: List[Real]
    var rho0: List[Real]
    var phase: List[Int]
    var delta: List[Real]
    var pres: List[Real]
    var h: Real
    var spacing: Real
    var b: Real  # pressure stiffness, Pa
    var alpha: Real  # artificial viscosity
    var lo: Vec3
    var hi: Vec3
    var delta_ref: Real  # number density of a resting interior lattice
    var wall_tab: List[Real]  # wall number density vs distance, 0 .. 2h
    var wall_dtab: List[Real]  # its derivative

    def __init__(out self, spacing: Real, b: Real, alpha: Real, lo: Vec3, hi: Vec3) raises:
        if not (spacing > 0) or not (b > 0) or not (alpha >= 0):
            raise Error("MultiphaseSph: spacing > 0, b > 0, alpha >= 0")
        self.x = List[Vec3]()
        self.v = List[Vec3]()
        self.mass = List[Real]()
        self.rho0 = List[Real]()
        self.phase = List[Int]()
        self.delta = List[Real]()
        self.pres = List[Real]()
        self.spacing = spacing
        self.h = 1.2 * spacing
        self.b = b
        self.alpha = alpha
        self.lo = lo
        self.hi = hi
        # interior lattice sum and the wall's share (virtual particles on
        # the lattice beyond each wall plane), tabulated over 0 .. 2h
        var h = self.h
        var reach = Int(2 * h / spacing) + 2
        var dref = Real(0)
        for i in range(-reach, reach + 1):
            for j in range(-reach, reach + 1):
                for k in range(-reach, reach + 1):
                    var r = spacing * sqrt(Real(i * i + j * j + k * k))
                    dref += _w(r, h)
        self.delta_ref = dref
        self.wall_tab = List[Real](length=_TAB + 1, fill=0)
        self.wall_dtab = List[Real](length=_TAB + 1, fill=0)
        for t in range(_TAB + 1):
            var d = 2 * h * Real(t) / Real(_TAB)
            var acc = Real(0)
            for l in range(reach + 1):
                var dn = d + (Real(l) + 0.5) * spacing
                for i in range(-reach, reach + 1):
                    for k in range(-reach, reach + 1):
                        var r = sqrt(dn * dn + spacing * spacing * Real(i * i + k * k))
                        acc += _w(r, h)
            self.wall_tab[t] = acc
        for t in range(_TAB + 1):
            var a = self.wall_tab[max(t - 1, 0)]
            var b = self.wall_tab[min(t + 1, _TAB)]
            var span = Real(min(t + 1, _TAB) - max(t - 1, 0))
            self.wall_dtab[t] = (b - a) / (span * 2 * h / Real(_TAB))

    def add(mut self, p: Vec3, rho0: Real, phase: Int) raises:
        if not (rho0 > 0):
            raise Error("MultiphaseSph.add: rho0 must be > 0")
        self.x.append(p)
        self.v.append(Vec3(0, 0, 0, 0))
        self.rho0.append(rho0)
        self.mass.append(rho0 / self.delta_ref)
        self.phase.append(phase)
        self.delta.append(0)
        self.pres.append(0)

    def _wall(self, p: Vec3) -> Tuple[Real, Vec3]:
        """Wall number density at p and its gradient (sum over the six
        box faces within reach)."""
        var d_sum = Real(0)
        var g = Vec3(0, 0, 0, 0)
        var span = 2 * self.h
        for ax in range(3):
            for side in range(2):
                var d = p[ax] - self.lo[ax] if side == 0 else self.hi[ax] - p[ax]
                if d >= span:
                    continue
                var u = max(d, Real(0)) / span * Real(_TAB)
                var t = min(Int(u), _TAB - 1)
                var f = u - Real(t)
                d_sum += self.wall_tab[t] * (1 - f) + self.wall_tab[t + 1] * f
                var dd = self.wall_dtab[t] * (1 - f) + self.wall_dtab[t + 1] * f
                # d grows into the fluid: +axis for the lo face, -axis for hi
                var sgn = Real(1) if side == 0 else Real(-1)
                var e = Vec3(0, 0, 0, 0)
                e[ax] = sgn * dd
                g = g + e
        return (d_sum, g)

    def count(self) -> Int:
        return len(self.x)

    def max_dt(self) -> Real:
        var rmin = Real(1e30)
        for r in self.rho0:
            rmin = min(rmin, r)
        return 0.25 * self.h / sqrt(self.b / rmin)

    def mean_height(self, phase: Int) -> Real:
        var s = Real(0)
        var n = 0
        for i in range(len(self.x)):
            if self.phase[i] == phase:
                s += self.x[i][1]
                n += 1
        return s / Real(n) if n > 0 else Real(0)

    def momentum(self) -> Vec3:
        var m = Vec3(0, 0, 0, 0)
        for i in range(len(self.x)):
            m = m + self.v[i] * self.mass[i]
        return m

    def _neighbours(self) -> Tuple[List[Int], List[Int]]:
        var cell = 2 * self.h
        var grid = Dict[Int, List[Int]]()
        var n = len(self.x)
        for i in range(n):
            var k = _key(Int(floor(self.x[i][0] / cell)), Int(floor(self.x[i][1] / cell)), Int(floor(self.x[i][2] / cell)))
            if k in grid:
                try:
                    grid[k].append(i)
                except:
                    pass
            else:
                grid[k] = [i]
        var start = List[Int](length=n + 1, fill=0)
        var nbr = List[Int]()
        var r2 = cell * cell
        for i in range(n):
            start[i] = len(nbr)
            var ci = Int(floor(self.x[i][0] / cell))
            var cj = Int(floor(self.x[i][1] / cell))
            var ck = Int(floor(self.x[i][2] / cell))
            var seen = List[Int]()
            for dk in range(-1, 2):
                for dj in range(-1, 2):
                    for di in range(-1, 2):
                        var k = _key(ci + di, cj + dj, ck + dk)
                        var dup = False
                        for s in seen:
                            if s == k:
                                dup = True
                        if dup or k not in grid:
                            continue
                        seen.append(k)
                        try:
                            for j in grid[k]:
                                if j != i:
                                    var d = self.x[i] - self.x[j]
                                    if dot(d, d) < r2:
                                        nbr.append(j)
                        except:
                            pass
        start[n] = len(nbr)
        return (start^, nbr^)

    def step(mut self, dt: Real, gravity: Vec3) raises:
        if dt > self.max_dt():
            raise Error("MultiphaseSph.step: dt above the CFL bound " + String(self.max_dt()))
        var n = len(self.x)
        var nb = self._neighbours()
        ref start = nb[0]
        ref nbr = nb[1]
        var w0 = _w(0, self.h)
        for i in range(n):
            var d = w0
            for e in range(start[i], start[i + 1]):
                var r = self.x[i] - self.x[nbr[e]]
                d += _w(sqrt(dot(r, r)), self.h)
            d += self._wall(self.x[i])[0]
            self.delta[i] = d
            self.pres[i] = max(self.b * (self.mass[i] * d / self.rho0[i] - 1), Real(0))
        var acc = List[Vec3](length=n, fill=Vec3(0, 0, 0, 0))
        var cmax = sqrt(self.b / self.rho0[0])
        for i in range(n):
            var a = Vec3(0, 0, 0, 0)
            var pi_ = self.pres[i] / (self.delta[i] * self.delta[i])
            for e in range(start[i], start[i + 1]):
                var j = nbr[e]
                var rij = self.x[i] - self.x[j]
                var r = sqrt(dot(rij, rij))
                if r <= 0:
                    continue
                var g = rij * (_dw(r, self.h) / r)
                var coef = pi_ + self.pres[j] / (self.delta[j] * self.delta[j])
                # artificial viscosity on approaching pairs (Monaghan 1992)
                var vij = self.v[i] - self.v[j]
                var vr = dot(vij, rij)
                if vr < 0 and self.alpha > 0:
                    var mu = self.h * vr / (r * r + 0.01 * self.h * self.h)
                    var rho_bar = 0.5 * (self.mass[i] * self.delta[i] + self.mass[j] * self.delta[j])
                    # same units as p / delta^2, symmetric in i, j (momentum kept)
                    coef += -self.alpha * cmax * mu * rho_bar / (self.delta[i] * self.delta[j])
                a = a - g * (coef / self.mass[i])
            # wall pressure: virtual particles mirror p_i
            var wg = self._wall(self.x[i])[1]
            a = a - wg * (2 * pi_ / self.mass[i])
            acc[i] = a + gravity
        for i in range(n):
            self.v[i] = self.v[i] + acc[i] * dt
            var p = self.x[i] + self.v[i] * dt
            var vv = self.v[i]
            for ax in range(3):
                if p[ax] < self.lo[ax]:
                    p[ax] = self.lo[ax]
                    if vv[ax] < 0:
                        vv[ax] = 0
                elif p[ax] > self.hi[ax]:
                    p[ax] = self.hi[ax]
                    if vv[ax] > 0:
                        vv[ax] = 0
            self.x[i] = p
            self.v[i] = vv
