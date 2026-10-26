"""Particle level set volume correction for `LevelSetWater2` (ROADMAP 17.60;
Enright, Fedkiw, Ferziger & Mitchell 2002).

A level set loses volume where its surface is under-resolved. Marker
particles carry the lost volume back: positive particles seeded on the air
side and negative particles on the liquid side are advected with the grid
velocity (RK2, bilinear). A negative particle found in the air (phi > 0 at
its position) means the surface cut off a piece of liquid, so the cells near
it take min(phi, |x - x_p| - r); a positive particle found in the liquid does
the reverse with max(phi, r - |x - x_p|). r is the particle radius, 0.3 dx by
default. Only the cells within `reach` cells of an escaped particle change.

Particles are seeded once (`seed`) and not reseeded; `advect` uses the
velocity after the level-set step, so this is first order in time.
"""

from std.math import floor, sqrt
from geometry.vec import Real
from physics.mac_levelset import LevelSetWater2


struct LevelSetParticles(Movable):
    var x: List[Real]
    var y: List[Real]
    var neg: List[Bool]  # True: liquid-side particle
    var r: Real
    var reach: Int

    def __init__(out self, dx: Real, reach: Int = 2):
        self.x = List[Real]()
        self.y = List[Real]()
        self.neg = List[Bool]()
        self.r = 0.3 * dx
        self.reach = reach

    def count(self) -> Int:
        return len(self.x)

    def seed(mut self, ls: LevelSetWater2, band: Real):
        """Four particles per cell within `band` (in cells) of the surface,
        on the side of the cell's own sign."""
        var n = ls.n
        var dx = ls.dx
        self.x = List[Real]()
        self.y = List[Real]()
        self.neg = List[Bool]()
        for j in range(n):
            for i in range(n):
                var f = ls.phi[j * n + i]
                if abs(f) > band * dx:
                    continue
                for a in range(2):
                    for b in range(2):
                        self.x.append((Real(i) + 0.25 + 0.5 * Real(a)) * dx)
                        self.y.append((Real(j) + 0.25 + 0.5 * Real(b)) * dx)
                        self.neg.append(f < 0)

    def advect(mut self, ls: LevelSetWater2, dt: Real):
        for k in range(len(self.x)):
            var v1 = ls.velocity(self.x[k], self.y[k])
            var mx = self.x[k] + 0.5 * dt * v1[0]
            var my = self.y[k] + 0.5 * dt * v1[1]
            var v2 = ls.velocity(mx, my)
            self.x[k] += dt * v2[0]
            self.y[k] += dt * v2[1]

    def _phi(self, ls: LevelSetWater2, x: Real, y: Real) -> Real:
        """Bilinear sample of phi at cell centres, clamped to the box."""
        var n = ls.n
        var gx = min(max(x / ls.dx - 0.5, 0), Real(n - 1))
        var gy = min(max(y / ls.dx - 0.5, 0), Real(n - 1))
        var i0 = min(Int(floor(gx)), n - 2)
        var j0 = min(Int(floor(gy)), n - 2)
        var ax = gx - Real(i0)
        var ay = gy - Real(j0)
        var lo = ls.phi[j0 * n + i0] * (1 - ax) + ls.phi[j0 * n + i0 + 1] * ax
        var hi = ls.phi[(j0 + 1) * n + i0] * (1 - ax) + ls.phi[(j0 + 1) * n + i0 + 1] * ax
        return lo * (1 - ay) + hi * ay

    def correct(self, mut ls: LevelSetWater2) -> Int:
        """Applies the escape corrections; returns how many particles escaped."""
        var n = ls.n
        var dx = ls.dx
        var escaped = 0
        for k in range(len(self.x)):
            var px = self.x[k]
            var py = self.y[k]
            var f = self._phi(ls, px, py)
            var neg = self.neg[k]
            if neg and f <= 0:
                continue
            if not neg and f >= 0:
                continue
            escaped += 1
            var ci = min(max(Int(floor(px / dx)), 0), n - 1)
            var cj = min(max(Int(floor(py / dx)), 0), n - 1)
            for jj in range(max(cj - self.reach, 0), min(cj + self.reach + 1, n)):
                for ii in range(max(ci - self.reach, 0), min(ci + self.reach + 1, n)):
                    var cx = (Real(ii) + 0.5) * dx
                    var cy = (Real(jj) + 0.5) * dx
                    var d = sqrt((cx - px) * (cx - px) + (cy - py) * (cy - py))
                    var c = jj * n + ii
                    if neg:
                        ls.phi[c] = min(ls.phi[c], d - self.r)
                    else:
                        ls.phi[c] = max(ls.phi[c], self.r - d)
        return escaped
