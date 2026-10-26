"""Cumulant collision on the D3Q27 lattice, periodic (ROADMAP 17.60;
Geier, Schonherr, Pasquali & Krafczyk 2015, with every cumulant above
second order relaxed at rate 1).

`Lbm27` is a periodic cube of D3Q27 populations. Per cell, `collide`:

  1. density and velocity from the populations, then the central moments
     m_abc = sum f (cx - ux)^a (cy - uy)^b (cz - uz)^c for a, b, c in
     0..2 by three one-dimensional transforms (x, y, z; the 1-D moments
     of the three populations on a line about the shift ux are
     m0 = f- + f0 + f+, m1 = (f+ - f-) - ux m0,
     m2 = (f+ + f-) - 2 ux (f+ - f-) + ux^2 m0);
  2. the second-order moments are the second-order cumulants: shear
     (xy, xz, yz and xx - yy, xx - zz) relax at `omega` = 1 / (3 nu + 1/2),
     the trace at `omega_b` toward 3 rho cs^2 = rho;
  3. every higher cumulant is set to zero, the Gaussian closure: the
     central moments of odd order vanish and the even ones follow from the
     post-collision second moments S = m / rho by Wick's rule, e.g.
     m220 = rho (Sxx Syy + 2 Sxy^2),
     m211 = rho (Sxx Syz + 2 Sxy Sxz),
     m222 = rho (Sxx Syy Szz + 2 Sxx Syz^2 + 2 Syy Sxz^2 + 2 Szz Sxy^2
                 + 8 Sxy Syz Sxz);
  4. the three transforms run backwards, then the populations stream.

Galilean invariance: the lattice has no third central moment (c^3 = c
on {-1, 0, 1}), so the u^2 grad u terms of the stress are missing and a
flow carried by a uniform velocity u0 would decay more slowly, by an
amount growing as u0^2 (24.5 % in energy at u0 = 0.2, BGK 15 %). Geier et
al. 2015 add them back to the diagonal second-order relaxation, using the
velocity gradients estimated from the pre-collision second moments; that
is `galilean` = 1 (the default; 0 switches it off). It brings the error at
u0 = 0.2 down to 2.7 %. Measured limit (`test_lbm_cumulant`): at a
viscosity BGK cannot hold (a double shear layer at nu 1e-4) it survives
4x longer (1954 steps against 472) but still fails.
`smagorinsky` (Cs, 0 = off) adds an eddy viscosity from the
non-equilibrium second moments (Hou et al. 1996) to either collision.
`collide_bgk` is the D3Q27 BGK control on the same
storage. No walls, no forcing: this is the periodic collision study that
the D3Q19 `Lbm` (walls, forcing, moving solids) is not.
"""

from std.math import sqrt
from geometry.vec import Real

comptime Q27 = 27
comptime _CS2: Real = 1.0 / 3.0


def _cx(i: Int) -> Int:
    return i % 3 - 1


def _cy(i: Int) -> Int:
    return (i // 3) % 3 - 1


def _cz(i: Int) -> Int:
    return i // 9 - 1


def _w(i: Int) -> Real:
    var n = (1 if _cx(i) != 0 else 0) + (1 if _cy(i) != 0 else 0) + (1 if _cz(i) != 0 else 0)
    if n == 0:
        return 8.0 / 27.0
    if n == 1:
        return 2.0 / 27.0
    if n == 2:
        return 1.0 / 54.0
    return 1.0 / 216.0


def _fwd(mut a: Array[Real, 27], stride: Int, u: Real):
    """One axis of populations -> central moments about u, in place: slot 0
    = m0, slot 1 = m1, slot 2 = m2 on every line along `stride`."""
    for i in range(27):
        var pos = (i // stride) % 3
        if pos != 0:
            continue
        var fm = a[i]
        var f0 = a[i + stride]
        var fp = a[i + 2 * stride]
        var m0 = fm + f0 + fp
        var d = fp - fm
        a[i] = m0
        a[i + stride] = d - u * m0
        a[i + 2 * stride] = (fp + fm) - 2 * u * d + u * u * m0


def _inv(mut a: Array[Real, 27], stride: Int, u: Real):
    for i in range(27):
        var pos = (i // stride) % 3
        if pos != 0:
            continue
        var m0 = a[i]
        var m1 = a[i + stride]
        var m2 = a[i + 2 * stride]
        var s = m2 + 2 * u * m1 + u * u * m0
        var d = m1 + u * m0
        a[i] = (s - d) * 0.5
        a[i + stride] = m0 - s
        a[i + 2 * stride] = (s + d) * 0.5


struct Lbm27(Movable):
    var n: Int
    var omega: Real
    var omega_b: Real
    var smagorinsky: Real  # Smagorinsky constant for the shear rate (0 = off; 0.1-0.2 is usual)
    var galilean: Real  # strength of the Galilean correction of the diagonal relaxation (0 = off)
    var wall_z: Bool  # half-way bounce-back walls on the z = -1/2 and z = n - 1/2 planes (BGK path)
    var fx: Real  # uniform body force (Guo forcing, `collide_bgk` only)
    var fy: Real
    var fz: Real
    var f: List[Real]  # [dir][cell]
    var g: List[Real]

    def __init__(out self, n: Int, nu: Real) raises:
        if n < 4 or not (nu > 0):
            raise Error("Lbm27: n >= 4 and nu > 0")
        self.n = n
        self.omega = 1 / (3 * nu + Real(0.5))
        self.omega_b = 1
        self.galilean = 1
        self.smagorinsky = 0
        self.wall_z = False
        self.fx = 0
        self.fy = 0
        self.fz = 0
        var m = n * n * n
        self.f = List[Real](length=Q27 * m, fill=0)
        self.g = List[Real](length=Q27 * m, fill=0)

    def cells(self) -> Int:
        return self.n * self.n * self.n

    def nu(self) -> Real:
        return (1 / self.omega - Real(0.5)) / 3

    def set_equilibrium(mut self, c: Int, rho: Real, ux: Real, uy: Real, uz: Real):
        var m = self.cells()
        var usq = ux * ux + uy * uy + uz * uz
        for i in range(Q27):
            var cu = Real(_cx(i)) * ux + Real(_cy(i)) * uy + Real(_cz(i)) * uz
            self.f[i * m + c] = _w(i) * rho * (1 + 3 * cu + Real(4.5) * cu * cu - Real(1.5) * usq)

    def density(self, c: Int) -> Real:
        var m = self.cells()
        var s = Real(0)
        for i in range(Q27):
            s += self.f[i * m + c]
        return s

    def velocity(self, c: Int) -> Tuple[Real, Real, Real]:
        var m = self.cells()
        var r = Real(0)
        var x = Real(0)
        var y = Real(0)
        var z = Real(0)
        for i in range(Q27):
            var v = self.f[i * m + c]
            r += v
            x += v * Real(_cx(i))
            y += v * Real(_cy(i))
            z += v * Real(_cz(i))
        return (x / r, y / r, z / r)

    def mass(self) -> Float64:
        var s = Float64(0)
        for v in self.f:
            s += Float64(v)
        return s

    def kinetic_energy(self) -> Real:
        var e = Float64(0)
        for c in range(self.cells()):
            var r = self.density(c)
            var u = self.velocity(c)
            e += 0.5 * Float64(r) * Float64(u[0] * u[0] + u[1] * u[1] + u[2] * u[2])
        return Real(e)

    def is_finite(self) -> Bool:
        for v in self.f:
            if not (v == v) or abs(v) > 1e30:
                return False
        return True

    def collide(mut self):
        var m = self.cells()
        var a = Array[Real, 27](fill=0)
        for c in range(m):
            for i in range(Q27):
                a[i] = self.f[i * m + c]
            var rho = Real(0)
            var ux = Real(0)
            var uy = Real(0)
            var uz = Real(0)
            for i in range(Q27):
                rho += a[i]
                ux += a[i] * Real(_cx(i))
                uy += a[i] * Real(_cy(i))
                uz += a[i] * Real(_cz(i))
            if rho <= 0:
                continue
            ux /= rho
            uy /= rho
            uz /= rho
            # first-order shift: the cumulant path sets the post-collision
            # momentum to rho * (u + F / rho) outright
            ux += self.fx / rho
            uy += self.fy / rho
            uz += self.fz / rho
            _fwd(a, 1, ux)
            _fwd(a, 3, uy)
            _fwd(a, 9, uz)
            # a[c * 9 + b * 3 + a_] = m_{a_ b c}
            var mxx = a[2]
            var myy = a[6]
            var mzz = a[18]
            var mxy = a[4]
            var mxz = a[10]
            var myz = a[12]
            var omega = self.omega
            if self.smagorinsky > 0:
                # eddy viscosity from the non-equilibrium second moments
                # (Hou et al. 1996): tau = (tau0 + sqrt(tau0^2 +
                # 18 sqrt(2) Cs^2 sqrt(Q) / rho)) / 2, Q = |m - rho cs^2 I|^2
                var ex = mxx - rho * _CS2
                var ey = myy - rho * _CS2
                var ez = mzz - rho * _CS2
                var q = ex * ex + ey * ey + ez * ez + 2 * (mxy * mxy + mxz * mxz + myz * myz)
                var tau0 = 1 / self.omega
                var tau = Real(0.5) * (tau0 + sqrt(tau0 * tau0 + Real(25.455844122715707) * self.smagorinsky * self.smagorinsky * sqrt(q) / rho))
                omega = 1 / tau
            var tr = mxx + myy + mzz
            var d1 = mxx - myy
            var d2 = mxx - mzz
            var trn = tr + self.omega_b * (rho - tr)
            d1 *= 1 - omega
            d2 *= 1 - omega
            if self.galilean != 0:
                # Geier et al. 2015: the velocity gradients d_x u_x, ... from the
                # pre-collision second moments, and the u^2 grad u terms the
                # lattice's missing third moment leaves in the stress
                var tr0 = mxx + myy + mzz
                var dxu = -(omega / (2 * rho)) * (2 * mxx - myy - mzz) - (self.omega_b / (2 * rho)) * (tr0 - rho)
                var dyu = -(omega / (2 * rho)) * (mxx - 2 * myy + mzz) - (self.omega_b / (2 * rho)) * (tr0 - rho)
                var dzu = -(omega / (2 * rho)) * (mxx + myy - 2 * mzz) - (self.omega_b / (2 * rho)) * (tr0 - rho)
                var k1 = 3 * rho * (1 - omega / 2) * self.galilean
                d1 -= k1 * (ux * ux * dxu - uy * uy * dyu)
                d2 -= k1 * (ux * ux * dxu - uz * uz * dzu)
                trn -= 3 * rho * (1 - self.omega_b / 2) * self.galilean * (ux * ux * dxu + uy * uy * dyu + uz * uz * dzu)
            mxy *= 1 - omega
            mxz *= 1 - omega
            myz *= 1 - omega
            mxx = (trn + d1 + d2) / 3
            myy = mxx - d1
            mzz = mxx - d2
            var sxx = mxx / rho
            var syy = myy / rho
            var szz = mzz / rho
            var sxy = mxy / rho
            var sxz = mxz / rho
            var syz = myz / rho
            for i in range(27):
                a[i] = 0
            a[0] = rho
            a[2] = mxx
            a[6] = myy
            a[18] = mzz
            a[4] = mxy
            a[10] = mxz
            a[12] = myz
            a[8] = rho * (sxx * syy + 2 * sxy * sxy)  # m220
            a[20] = rho * (sxx * szz + 2 * sxz * sxz)  # m202
            a[24] = rho * (syy * szz + 2 * syz * syz)  # m022
            a[14] = rho * (sxx * syz + 2 * sxy * sxz)  # m211 (a=2, b=1, c=1)
            a[16] = rho * (syy * sxz + 2 * sxy * syz)  # m121 (a=1, b=2, c=1)
            a[22] = rho * (szz * sxy + 2 * sxz * syz)  # m112 (a=1, b=1, c=2)
            a[26] = rho * (sxx * syy * szz + 2 * sxx * syz * syz + 2 * syy * sxz * sxz + 2 * szz * sxy * sxy + 8 * sxy * syz * sxz)
            _inv(a, 9, uz)
            _inv(a, 3, uy)
            _inv(a, 1, ux)
            for i in range(Q27):
                self.f[i * m + c] = a[i]

    def set_walls_z(mut self, on: Bool):
        """Half-way bounce-back on the two z planes (x and y stay periodic).
        Applies to both `step` and `step_bgk`: the wall lives in the shared `stream`."""
        self.wall_z = on

    def set_force(mut self, fx: Real, fy: Real, fz: Real):
        """Uniform body force per unit volume. `step_bgk` uses the Guo et al. (2002)
        scheme; the cumulant `step` shifts the moment velocity by F / rho (first
        order; see the 17.60 note for the measured accuracy)."""
        self.fx = fx
        self.fy = fy
        self.fz = fz

    def collide_bgk(mut self):
        var m = self.cells()
        var forced = self.fx != 0 or self.fy != 0 or self.fz != 0
        for c in range(m):
            var rho = Real(0)
            var ux = Real(0)
            var uy = Real(0)
            var uz = Real(0)
            for i in range(Q27):
                var v = self.f[i * m + c]
                rho += v
                ux += v * Real(_cx(i))
                uy += v * Real(_cy(i))
                uz += v * Real(_cz(i))
            if rho <= 0:
                continue
            ux /= rho
            uy /= rho
            uz /= rho
            if forced:
                # Guo: the velocity that enters the equilibrium is shifted by F / (2 rho)
                ux += self.fx / (2 * rho)
                uy += self.fy / (2 * rho)
                uz += self.fz / (2 * rho)
            var usq = ux * ux + uy * uy + uz * uz
            var omega = self.omega
            if self.smagorinsky > 0:
                var pxx = Real(0)
                var pyy = Real(0)
                var pzz = Real(0)
                var pxy = Real(0)
                var pxz = Real(0)
                var pyz = Real(0)
                for i in range(Q27):
                    var cu = Real(_cx(i)) * ux + Real(_cy(i)) * uy + Real(_cz(i)) * uz
                    var neq = self.f[i * m + c] - _w(i) * rho * (1 + 3 * cu + Real(4.5) * cu * cu - Real(1.5) * usq)
                    pxx += neq * Real(_cx(i) * _cx(i))
                    pyy += neq * Real(_cy(i) * _cy(i))
                    pzz += neq * Real(_cz(i) * _cz(i))
                    pxy += neq * Real(_cx(i) * _cy(i))
                    pxz += neq * Real(_cx(i) * _cz(i))
                    pyz += neq * Real(_cy(i) * _cz(i))
                var q = pxx * pxx + pyy * pyy + pzz * pzz + 2 * (pxy * pxy + pxz * pxz + pyz * pyz)
                var tau0 = 1 / self.omega
                omega = 1 / (Real(0.5) * (tau0 + sqrt(tau0 * tau0 + Real(25.455844122715707) * self.smagorinsky * self.smagorinsky * sqrt(q) / rho)))
            for i in range(Q27):
                var cu = Real(_cx(i)) * ux + Real(_cy(i)) * uy + Real(_cz(i)) * uz
                var feq = _w(i) * rho * (1 + 3 * cu + Real(4.5) * cu * cu - Real(1.5) * usq)
                self.f[i * m + c] += omega * (feq - self.f[i * m + c])
                if forced:
                    # Guo source: w (1 - omega / 2) [3 (c - u) . F + 9 (c . u) (c . F)]
                    var cf = Real(_cx(i)) * self.fx + Real(_cy(i)) * self.fy + Real(_cz(i)) * self.fz
                    var uf = ux * self.fx + uy * self.fy + uz * self.fz
                    var src = _w(i) * (1 - omega / 2) * (3 * (cf - uf) + 9 * cu * cf)
                    self.f[i * m + c] += src

    def stream(mut self):
        var n = self.n
        var m = self.cells()
        for i in range(Q27):
            var dx = _cx(i)
            var dy = _cy(i)
            var dz = _cz(i)
            for z in range(n):
                var zr = z - dz
                var bounce = self.wall_z and (zr < 0 or zr >= n)
                var zs = (zr + n) % n
                for y in range(n):
                    var ys = (y - dy + n) % n
                    for x in range(n):
                        var xs = (x - dx + n) % n
                        var dst = i * m + (z * n + y) * n + x
                        if bounce:
                            # the population leaving the wall returns reversed, from the same node
                            self.g[dst] = self.f[(Q27 - 1 - i) * m + (z * n + y) * n + x]
                        else:
                            self.g[dst] = self.f[i * m + (zs * n + ys) * n + xs]
        var t = self.f^
        self.f = self.g^
        self.g = t^

    def step(mut self):
        self.collide()
        self.stream()

    def step_bgk(mut self):
        self.collide_bgk()
        self.stream()
