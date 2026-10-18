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

Measured limits (`test_lbm_cumulant`): at a viscosity BGK cannot hold
(a double shear layer at nu 1e-4) it survives 4x longer (1954 steps
against 472) but still fails; and it is NOT Galilean invariant: a vortex
carried by a uniform flow u0 decays more slowly by an amount that grows as
u0^2 (25 % in energy at u0 = 0.2, BGK 15 %). The cause is the lattice's
missing third central moment (c^3 = c on {-1, 0, 1}); Geier et al. 2015
cancel it with an extra term in the diagonal second-order relaxation
(from the velocity-gradient estimate), which is not implemented here.
`collide_bgk` is the D3Q27 BGK control on the same
storage. No walls, no forcing: this is the periodic collision study that
the D3Q19 `Lbm` (walls, forcing, moving solids) is not.
"""

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
    var f: List[Real]  # [dir][cell]
    var g: List[Real]

    def __init__(out self, n: Int, nu: Real) raises:
        if n < 4 or not (nu > 0):
            raise Error("Lbm27: n >= 4 and nu > 0")
        self.n = n
        self.omega = 1 / (3 * nu + Real(0.5))
        self.omega_b = 1
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
            var tr = mxx + myy + mzz
            var d1 = mxx - myy
            var d2 = mxx - mzz
            var trn = tr + self.omega_b * (rho - tr)
            d1 *= 1 - self.omega
            d2 *= 1 - self.omega
            mxy *= 1 - self.omega
            mxz *= 1 - self.omega
            myz *= 1 - self.omega
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

    def collide_bgk(mut self):
        var m = self.cells()
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
            var usq = ux * ux + uy * uy + uz * uz
            for i in range(Q27):
                var cu = Real(_cx(i)) * ux + Real(_cy(i)) * uy + Real(_cz(i)) * uz
                var feq = _w(i) * rho * (1 + 3 * cu + Real(4.5) * cu * cu - Real(1.5) * usq)
                self.f[i * m + c] += self.omega * (feq - self.f[i * m + c])

    def stream(mut self):
        var n = self.n
        var m = self.cells()
        for i in range(Q27):
            var dx = _cx(i)
            var dy = _cy(i)
            var dz = _cz(i)
            for z in range(n):
                var zs = (z - dz + n) % n
                for y in range(n):
                    var ys = (y - dy + n) % n
                    for x in range(n):
                        var xs = (x - dx + n) % n
                        self.g[i * m + (z * n + y) * n + x] = self.f[i * m + (zs * n + ys) * n + xs]
        var t = self.f^
        self.f = self.g^
        self.g = t^

    def step(mut self):
        self.collide()
        self.stream()

    def step_bgk(mut self):
        self.collide_bgk()
        self.stream()
