"""Particle level set volume correction for `LevelSetWater3` (ROADMAP 17.60;
3-D version of `physics.mac_levelset_particles`, after Enright et al. 2002).

The structure is close to the 2-D one: positive particles seeded on the air side and
negative particles on the liquid side are advected with the grid velocity (RK2,
trilinear). A negative particle found in the air takes the cells near it to
min(phi, |x - x_p| - r); a positive particle found in the liquid takes them to
max(phi, r - |x - x_p|). r = 0.3 dx, and only the cells within `reach` cells
(in each axis) of an escaped particle change.

Two differences from `physics.mac_levelset_particles` (2-D), both measured on
the 2-D vortex disk (2026-10-27). (1) Escape tests use the phi before the
correction (`correct` below); the 2-D code tests each particle against the phi
its predecessors already changed. (2) The corrections are merged per cell by
min / max before they are applied. Applying (1) alone to the 2-D scheme gives
+14.7 % volume against +9.1 % for the sequential 2-D code; adding (2) gives
+24.3 %. The 2-D scheme keeps the sequential form.

Known limits, inherited from the 2-D scheme and measured there (17.60 note,
2026-10-27): the volume gain is not converged in resolution, the sign of the
error changes between n = 32 and n = 64, and the error depends on how often the
level set is reinitialised. Particles are seeded once and not reseeded.
`advect` uses the velocity after the level-set step (first order in time).
"""

from std.math import floor, sqrt
from geometry.vec import Real
from physics.mac_levelset3 import LevelSetWater3


struct LevelSetParticles3(Movable):
    var x: List[Real]
    var y: List[Real]
    var z: List[Real]
    var neg: List[Bool]  # True: liquid-side particle
    var r: Real
    var reach: Int

    def __init__(out self, dx: Real, reach: Int = 2):
        self.x = List[Real]()
        self.y = List[Real]()
        self.z = List[Real]()
        self.neg = List[Bool]()
        self.r = 0.3 * dx
        self.reach = reach

    def count(self) -> Int:
        return len(self.x)

    def seed(mut self, ls: LevelSetWater3, band: Real):
        """Eight particles per cell within `band` (in cells) of the surface,
        on the side of the cell's own sign."""
        var n = ls.n
        var dx = ls.dx
        self.x = List[Real]()
        self.y = List[Real]()
        self.z = List[Real]()
        self.neg = List[Bool]()
        for k in range(n):
            for j in range(n):
                for i in range(n):
                    var f = ls.phi[(k * n + j) * n + i]
                    if abs(f) > band * dx:
                        continue
                    for a in range(2):
                        for b in range(2):
                            for c in range(2):
                                self.x.append((Real(i) + 0.25 + 0.5 * Real(a)) * dx)
                                self.y.append((Real(j) + 0.25 + 0.5 * Real(b)) * dx)
                                self.z.append((Real(k) + 0.25 + 0.5 * Real(c)) * dx)
                                self.neg.append(f < 0)

    def advect(mut self, ls: LevelSetWater3, dt: Real):
        for q in range(len(self.x)):
            var v1 = ls.velocity(self.x[q], self.y[q], self.z[q])
            var mx = self.x[q] + 0.5 * dt * v1[0]
            var my = self.y[q] + 0.5 * dt * v1[1]
            var mz = self.z[q] + 0.5 * dt * v1[2]
            var v2 = ls.velocity(mx, my, mz)
            self.x[q] += dt * v2[0]
            self.y[q] += dt * v2[1]
            self.z[q] += dt * v2[2]

    def reseed(mut self, ls: LevelSetWater3, band: Real, target: Int):
        """Enright-style per-cell reseeding (Enright et al. 2002, section 4).

        A particle that lies deeper than `band` cells on its own side is deleted.
        Escaped particles (on the wrong side) are kept: they carry the correction.
        Then every band cell is topped up to `target` particles: the particle
        counts per cell are taken from the kept particles, and new particles sit
        on the 2 x 2 x 2 lattice of the cell. Each new particle's side comes from
        the trilinear phi at its position (not from the cell centre)."""
        var n = ls.n
        var dx = ls.dx
        var keep_x = List[Real]()
        var keep_y = List[Real]()
        var keep_z = List[Real]()
        var keep_neg = List[Bool]()
        for q in range(len(self.x)):
            var f = self._phi(ls, self.x[q], self.y[q], self.z[q])
            var own = (self.neg[q] and f < 0) or (not self.neg[q] and f > 0)
            if own and abs(f) > band * dx:
                continue
            keep_x.append(self.x[q])
            keep_y.append(self.y[q])
            keep_z.append(self.z[q])
            keep_neg.append(self.neg[q])
        self.x = keep_x^
        self.y = keep_y^
        self.z = keep_z^
        self.neg = keep_neg^
        var cnt = List[Int](length=n * n * n, fill=0)
        for q in range(len(self.x)):
            var ci = min(max(Int(floor(self.x[q] / dx)), 0), n - 1)
            var cj = min(max(Int(floor(self.y[q] / dx)), 0), n - 1)
            var ck = min(max(Int(floor(self.z[q] / dx)), 0), n - 1)
            cnt[(ck * n + cj) * n + ci] += 1
        for k in range(n):
            for j in range(n):
                for i in range(n):
                    var c = (k * n + j) * n + i
                    var fc = ls.phi[c]
                    if abs(fc) > band * dx:
                        continue
                    var need = target - cnt[c]
                    for a in range(2):
                        for b in range(2):
                            for d in range(2):
                                if need <= 0:
                                    break
                                var px = (Real(i) + 0.25 + 0.5 * Real(a)) * dx
                                var py = (Real(j) + 0.25 + 0.5 * Real(b)) * dx
                                var pz = (Real(k) + 0.25 + 0.5 * Real(d)) * dx
                                var f = self._phi(ls, px, py, pz)
                                self.x.append(px)
                                self.y.append(py)
                                self.z.append(pz)
                                self.neg.append(f < 0)
                                need -= 1

    def _phi(self, ls: LevelSetWater3, x: Real, y: Real, z: Real) -> Real:
        """Trilinear sample of phi at cell centres, clamped to the box."""
        var n = ls.n
        var dx = ls.dx
        var gx = min(max(x / dx - 0.5, 0), Real(n - 1))
        var gy = min(max(y / dx - 0.5, 0), Real(n - 1))
        var gz = min(max(z / dx - 0.5, 0), Real(n - 1))
        var i0 = min(Int(floor(gx)), n - 2)
        var j0 = min(Int(floor(gy)), n - 2)
        var k0 = min(Int(floor(gz)), n - 2)
        var ax = gx - Real(i0)
        var ay = gy - Real(j0)
        var az = gz - Real(k0)
        var acc = Real(0)
        for c in range(8):
            var di = c & 1
            var dj = (c >> 1) & 1
            var dk = (c >> 2) & 1
            var wgt = (ax if di == 1 else 1 - ax) * (ay if dj == 1 else 1 - ay) * (az if dk == 1 else 1 - az)
            acc += wgt * ls.phi[((k0 + dk) * n + j0 + dj) * n + i0 + di]
        return acc

    def correct(self, mut ls: LevelSetWater3) -> Int:
        """Applies the escape corrections; returns how many particles escaped.

        The negative corrections are reduced by min and the positive ones by
        max, per cell, before either is applied. A cell's result therefore does
        not depend on the order in which particles are visited (a sequential
        min / max on the same cell does not commute, and the z planes would see
        their neighbours in different orders)."""
        var n = ls.n
        var dx = ls.dx
        var escaped = 0
        var cmin = List[Real](length=n * n * n, fill=Real(1e30))
        var cmax = List[Real](length=n * n * n, fill=Real(-1e30))
        for q in range(len(self.x)):
            var px = self.x[q]
            var py = self.y[q]
            var pz = self.z[q]
            var f = self._phi(ls, px, py, pz)
            var neg = self.neg[q]
            if neg and f <= 0:
                continue
            if not neg and f >= 0:
                continue
            escaped += 1
            var ci = min(max(Int(floor(px / dx)), 0), n - 1)
            var cj = min(max(Int(floor(py / dx)), 0), n - 1)
            var ck = min(max(Int(floor(pz / dx)), 0), n - 1)
            for kk in range(max(ck - self.reach, 0), min(ck + self.reach + 1, n)):
                for jj in range(max(cj - self.reach, 0), min(cj + self.reach + 1, n)):
                    for ii in range(max(ci - self.reach, 0), min(ci + self.reach + 1, n)):
                        var cx = (Real(ii) + 0.5) * dx
                        var cy = (Real(jj) + 0.5) * dx
                        var cz = (Real(kk) + 0.5) * dx
                        var d = sqrt((cx - px) * (cx - px) + (cy - py) * (cy - py) + (cz - pz) * (cz - pz))
                        var c = (kk * n + jj) * n + ii
                        if neg:
                            cmin[c] = min(cmin[c], d - self.r)
                        else:
                            cmax[c] = max(cmax[c], self.r - d)
        for c in range(n * n * n):
            if cmin[c] < Real(1e29):
                ls.phi[c] = min(ls.phi[c], cmin[c])
            if cmax[c] > Real(-1e29):
                ls.phi[c] = max(ls.phi[c], cmax[c])
        return escaped
