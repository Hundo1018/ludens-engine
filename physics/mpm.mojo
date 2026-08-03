"""MLS-MPM — the hybrid particle/grid solver, for materials the others cannot do.

FEM discretises a fixed mesh, so it models a solid that keeps its connectivity.
PBF and SPH are purely particle-based, so they model a fluid with no memory of
its rest shape. MPM sits between them: particles carry the material state
(deformation gradient, volume), a BACKGROUND GRID is used once per step to
resolve the coupling, and the grid is thrown away afterwards. Because the mesh
is transient, the material can undergo arbitrary topology change — flow, pile
up, tear, merge — while still remembering elastic strain, which is what makes
this the method for snow, mud and plastic flow.

MLS-MPM (Hu et al. 2018) is used rather than classic MPM because it folds the
affine velocity field (APIC) and the stress term into one quadratic B-spline
scatter, which removes the separate force pass entirely.

Per step:
  P2G  scatter mass, affine momentum and stress onto a 3x3x3 grid stencil
  grid normalise momentum, apply gravity, enforce boundaries
  G2P  gather velocity and the affine matrix C, advect, update F

Plasticity is a determinant clamp on F: elastic strain beyond a yield range is
forgotten rather than stored, which is exactly what makes a material FLOW
instead of springing back. `test_mpm` asserts both regimes — elastic recoil
with the clamp wide, and permanent deformation with it tight — since a solver
that never yields would pass any test written only for the elastic case.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3
from geometry.mat import Mat3
from physics.fem import polar_rotation, _det3


@fieldwise_init
struct MpmParticle(Copyable, ImplicitlyCopyable, Movable):
    var x: Vec3
    var v: Vec3
    var f: Mat3  # deformation gradient
    var c: Mat3  # affine velocity field (APIC)
    var vol: Real
    var mass: Real


struct MpmSolver(Movable):
    var p: List[MpmParticle]
    var lo: Vec3
    var dx: Real
    var n: Int  # grid resolution per axis
    var mu: Real
    var lam: Real
    # plastic yield range on det(F); (1,1) = purely elastic
    var j_min: Real
    var j_max: Real
    # grid scratch (SoA, rebuilt each step)
    var gm: List[Real]
    var gvx: List[Real]
    var gvy: List[Real]
    var gvz: List[Real]

    def __init__(out self, lo: Vec3, dx: Real, n: Int, young: Real, poisson: Real):
        self.p = List[MpmParticle]()
        self.lo = lo
        self.dx = dx
        self.n = n
        self.mu = young / (2 * (1 + poisson))
        self.lam = young * poisson / ((1 + poisson) * (1 - 2 * poisson))
        self.j_min = 1.0
        self.j_max = 1.0
        self.gm = List[Real]()
        self.gvx = List[Real]()
        self.gvy = List[Real]()
        self.gvz = List[Real]()
        var cells = n * n * n
        for _ in range(cells):
            self.gm.append(0)
            self.gvx.append(0)
            self.gvy.append(0)
            self.gvz.append(0)

    def count(self) -> Int:
        return len(self.p)

    def add(mut self, pos: Vec3, mass: Real, vol: Real):
        self.p.append(
            MpmParticle(pos, Vec3(0, 0, 0), Mat3.identity(), Mat3(), vol, mass)
        )

    def set_plastic(mut self, j_min: Real, j_max: Real):
        self.j_min = j_min
        self.j_max = j_max

    def _gi(self, i: Int, j: Int, k: Int) -> Int:
        return (k * self.n + j) * self.n + i

    def total_mass(self) -> Real:
        var m = Real(0)
        for ref q in self.p:
            m += q.mass
        return m

    def total_momentum(self) -> Vec3:
        var s = Vec3(0, 0, 0)
        for ref q in self.p:
            s = s + q.v * q.mass
        return s

    def step(mut self, dt: Real, gravity: Vec3):
        var cells = self.n * self.n * self.n
        for c in range(cells):
            self.gm[c] = 0
            self.gvx[c] = 0
            self.gvy[c] = 0
            self.gvz[c] = 0

        var inv_dx = 1.0 / self.dx

        # ---- P2G ----
        for pi in range(len(self.p)):
            var q = self.p[pi]
            var gx = (q.x[0] - self.lo[0]) * inv_dx
            var gy = (q.x[1] - self.lo[1]) * inv_dx
            var gz = (q.x[2] - self.lo[2]) * inv_dx
            var bx = Int(gx - 0.5)
            var by = Int(gy - 0.5)
            var bz = Int(gz - 0.5)
            if bx < 0 or by < 0 or bz < 0:
                continue
            if bx + 2 >= self.n or by + 2 >= self.n or bz + 2 >= self.n:
                continue
            var fx = gx - Real(bx)
            var fy = gy - Real(by)
            var fz = gz - Real(bz)
            # quadratic B-spline weights over the 3-cell stencil
            var wx = InlineArray[Real, 3](fill=0)
            var wy = InlineArray[Real, 3](fill=0)
            var wz = InlineArray[Real, 3](fill=0)
            wx[0] = 0.5 * (1.5 - fx) * (1.5 - fx)
            wx[1] = 0.75 - (fx - 1.0) * (fx - 1.0)
            wx[2] = 0.5 * (fx - 0.5) * (fx - 0.5)
            wy[0] = 0.5 * (1.5 - fy) * (1.5 - fy)
            wy[1] = 0.75 - (fy - 1.0) * (fy - 1.0)
            wy[2] = 0.5 * (fy - 0.5) * (fy - 0.5)
            wz[0] = 0.5 * (1.5 - fz) * (1.5 - fz)
            wz[1] = 0.75 - (fz - 1.0) * (fz - 1.0)
            wz[2] = 0.5 * (fz - 0.5) * (fz - 0.5)

            # fixed-corotated stress: P = 2 mu (F - R) + lambda (J - 1) J F^-T,
            # folded into the MLS affine term
            var r = polar_rotation(q.f)
            var jdet = _det3(q.f)
            var stress = Mat3()
            for a in range(3):
                for b in range(3):
                    stress.set(a, b, 2 * self.mu * (q.f.get(a, b) - r.get(a, b)))
            # volumetric part: lambda (J-1) J * F^-T  ~  add along the diagonal
            # through the standard cofactor identity for the isotropic term
            var volterm = self.lam * (jdet - 1.0) * jdet
            for a in range(3):
                stress.set(a, a, stress.get(a, a) + volterm)
            var ft = q.f.transpose()
            var pft = stress * ft  # P F^T, the Cauchy-like term MLS scatters
            var scale = -dt * q.vol * 4.0 * inv_dx * inv_dx
            var affine = Mat3()
            for a in range(3):
                for b in range(3):
                    affine.set(
                        a, b, scale * pft.get(a, b) + q.mass * q.c.get(a, b)
                    )

            for i in range(3):
                for j in range(3):
                    for k in range(3):
                        var w = wx[i] * wy[j] * wz[k]
                        # offset from the particle to grid node (b+i):
                        # (i - fx) * dx, with fx in [0.5, 1.5] from the
                        # base = int(g - 0.5) convention. An extra +1 here
                        # shifts every stencil weight onto the wrong node and
                        # the solver explodes in free fall.
                        var dpx = (Real(i) - fx) * self.dx
                        var dpy = (Real(j) - fy) * self.dx
                        var dpz = (Real(k) - fz) * self.dx
                        var idx = self._gi(bx + i, by + j, bz + k)
                        self.gm[idx] += w * q.mass
                        self.gvx[idx] += w * (
                            q.mass * q.v[0]
                            + affine.get(0, 0) * dpx
                            + affine.get(0, 1) * dpy
                            + affine.get(0, 2) * dpz
                        )
                        self.gvy[idx] += w * (
                            q.mass * q.v[1]
                            + affine.get(1, 0) * dpx
                            + affine.get(1, 1) * dpy
                            + affine.get(1, 2) * dpz
                        )
                        self.gvz[idx] += w * (
                            q.mass * q.v[2]
                            + affine.get(2, 0) * dpx
                            + affine.get(2, 1) * dpy
                            + affine.get(2, 2) * dpz
                        )

        # ---- grid: momentum -> velocity, gravity, boundaries ----
        for k in range(self.n):
            for j in range(self.n):
                for i in range(self.n):
                    var idx = self._gi(i, j, k)
                    var m = self.gm[idx]
                    if m <= 1e-12:
                        self.gvx[idx] = 0
                        self.gvy[idx] = 0
                        self.gvz[idx] = 0
                        continue
                    var inv = 1.0 / m
                    self.gvx[idx] *= inv
                    self.gvy[idx] *= inv
                    self.gvz[idx] *= inv
                    self.gvx[idx] += gravity[0] * dt
                    self.gvy[idx] += gravity[1] * dt
                    self.gvz[idx] += gravity[2] * dt
                    # sticky walls in a 3-cell boundary band
                    if i < 3 and self.gvx[idx] < 0:
                        self.gvx[idx] = 0
                    if i > self.n - 4 and self.gvx[idx] > 0:
                        self.gvx[idx] = 0
                    if j < 3 and self.gvy[idx] < 0:
                        self.gvy[idx] = 0
                    if j > self.n - 4 and self.gvy[idx] > 0:
                        self.gvy[idx] = 0
                    if k < 3 and self.gvz[idx] < 0:
                        self.gvz[idx] = 0
                    if k > self.n - 4 and self.gvz[idx] > 0:
                        self.gvz[idx] = 0

        # ---- G2P ----
        for pi in range(len(self.p)):
            var q = self.p[pi]
            var gx = (q.x[0] - self.lo[0]) * inv_dx
            var gy = (q.x[1] - self.lo[1]) * inv_dx
            var gz = (q.x[2] - self.lo[2]) * inv_dx
            var bx = Int(gx - 0.5)
            var by = Int(gy - 0.5)
            var bz = Int(gz - 0.5)
            if bx < 0 or by < 0 or bz < 0:
                continue
            if bx + 2 >= self.n or by + 2 >= self.n or bz + 2 >= self.n:
                continue
            var fx = gx - Real(bx)
            var fy = gy - Real(by)
            var fz = gz - Real(bz)
            var wx = InlineArray[Real, 3](fill=0)
            var wy = InlineArray[Real, 3](fill=0)
            var wz = InlineArray[Real, 3](fill=0)
            wx[0] = 0.5 * (1.5 - fx) * (1.5 - fx)
            wx[1] = 0.75 - (fx - 1.0) * (fx - 1.0)
            wx[2] = 0.5 * (fx - 0.5) * (fx - 0.5)
            wy[0] = 0.5 * (1.5 - fy) * (1.5 - fy)
            wy[1] = 0.75 - (fy - 1.0) * (fy - 1.0)
            wy[2] = 0.5 * (fy - 0.5) * (fy - 0.5)
            wz[0] = 0.5 * (1.5 - fz) * (1.5 - fz)
            wz[1] = 0.75 - (fz - 1.0) * (fz - 1.0)
            wz[2] = 0.5 * (fz - 0.5) * (fz - 0.5)

            var nv = Vec3(0, 0, 0)
            var nc = Mat3()
            for i in range(3):
                for j in range(3):
                    for k in range(3):
                        var w = wx[i] * wy[j] * wz[k]
                        var idx = self._gi(bx + i, by + j, bz + k)
                        var gvel = Vec3(
                            self.gvx[idx], self.gvy[idx], self.gvz[idx]
                        )
                        # offset from the particle to grid node (b+i):
                        # (i - fx) * dx, with fx in [0.5, 1.5] from the
                        # base = int(g - 0.5) convention. An extra +1 here
                        # shifts every stencil weight onto the wrong node and
                        # the solver explodes in free fall.
                        var dpx = (Real(i) - fx) * self.dx
                        var dpy = (Real(j) - fy) * self.dx
                        var dpz = (Real(k) - fz) * self.dx
                        nv = nv + gvel * w
                        # APIC affine matrix: outer product of velocity and
                        # offset, scaled by 4/dx^2 for the quadratic kernel
                        var s = w * 4.0 * inv_dx * inv_dx
                        nc.set(0, 0, nc.get(0, 0) + s * gvel[0] * dpx)
                        nc.set(0, 1, nc.get(0, 1) + s * gvel[0] * dpy)
                        nc.set(0, 2, nc.get(0, 2) + s * gvel[0] * dpz)
                        nc.set(1, 0, nc.get(1, 0) + s * gvel[1] * dpx)
                        nc.set(1, 1, nc.get(1, 1) + s * gvel[1] * dpy)
                        nc.set(1, 2, nc.get(1, 2) + s * gvel[1] * dpz)
                        nc.set(2, 0, nc.get(2, 0) + s * gvel[2] * dpx)
                        nc.set(2, 1, nc.get(2, 1) + s * gvel[2] * dpy)
                        nc.set(2, 2, nc.get(2, 2) + s * gvel[2] * dpz)

            q.v = nv
            q.c = nc
            q.x = q.x + nv * dt
            # F <- (I + dt C) F
            var upd = Mat3.identity()
            for a in range(3):
                for b in range(3):
                    upd.set(a, b, upd.get(a, b) + dt * nc.get(a, b))
            q.f = upd * q.f
            # PLASTICITY: forget elastic strain outside the yield range. This
            # single clamp is what turns an elastic solid into a material that
            # flows and keeps its new shape.
            if self.j_max > self.j_min:
                var jd = _det3(q.f)
                if jd > self.j_max or jd < self.j_min:
                    var target = self.j_max if jd > self.j_max else self.j_min
                    if abs(jd) > 1e-9:
                        # cube root through Float64: Real ** Float64
                        # is not a supported type combination on this nightly
                        var sc = Real(Float64(target / jd) ** (1.0 / 3.0))
                        for a in range(3):
                            for b in range(3):
                                q.f.set(a, b, q.f.get(a, b) * sc)
            self.p[pi] = q
