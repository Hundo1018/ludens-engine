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

Sand and obstacles run in `step_ext` (`step` ignores them; see there why).
Sand (ROADMAP 17.58, `set_sand(friction_deg)`; EXPERIMENTAL: in
`test_mpm_sand` a column keeps more height the larger the angle and stands
at 85 degrees, but at 30 and 60 it keeps spreading instead of stopping at its
angle of repose): Drucker-Prager plasticity by
the return mapping of Klar et al. 2016 on the singular values of F (SVD from
the polar decomposition and a symmetric eigen solve), in log-strain space:
a stretched particle forgets all elastic strain (sand has no tension), a
compressed one is projected back onto the friction cone. It replaces the
determinant clamp. Static obstacles (`add_obstacle(sdf, mu)`): a grid node
inside an `Sdf3` loses the velocity into it, with Coulomb friction on the
rest (sticks when the tangential speed is within mu times the normal one),
and a particle that still ends inside is put back on the surface. The
domain walls only remove the velocity into them (frictionless), so sand
needs an obstacle as its floor to pile instead of spreading.
"""

from std.math import sqrt, log, exp, sin
from geometry.vec import Real, Vec3, dot, length
from geometry.mat import Mat3
from geometry.mat3 import Mat3x3, sym_eigen3
from geometry.sdf3 import Sdf3
from physics.fem import polar_rotation, det3


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
    var dp_alpha: Real  # Drucker-Prager cone (0 = off)
    var obstacles: List[Sdf3]
    var obstacle_mu: List[Real]
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
        self.dp_alpha = 0
        self.obstacles = List[Sdf3]()
        self.obstacle_mu = List[Real]()
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
            MpmParticle(pos, Vec3(0, 0, 0, 0), Mat3.identity(), Mat3(), vol, mass)
        )

    def set_plastic(mut self, j_min: Real, j_max: Real):
        self.j_min = j_min
        self.j_max = j_max

    def set_sand(mut self, friction_deg: Real) raises:
        """Drucker-Prager sand with friction angle `friction_deg` (module
        note); raises outside (0, 90)."""
        if not (friction_deg > 0 and friction_deg < 90):
            raise Error("MpmSolver.set_sand: friction angle must be in (0, 90) degrees")
        var sp = sin(friction_deg * 0.017453292519943295)
        self.dp_alpha = Real(0.816496580927726) * 2 * sp / (3 - sp)
        self.j_min = 1.0  # the return mapping replaces the determinant clamp
        self.j_max = 1.0

    def add_obstacle(mut self, sdf: Sdf3, mu: Real) raises:
        if not (mu >= 0):
            raise Error("MpmSolver.add_obstacle: mu must be >= 0")
        self.obstacles.append(sdf)
        self.obstacle_mu.append(mu)

    def _sand(self, f: Mat3) -> Mat3:
        """Drucker-Prager return mapping of F (Klar et al. 2016)."""
        var r = polar_rotation(f)
        var sm = r.transpose() * f
        var s3 = Mat3x3()
        for a in range(3):
            for b in range(3):
                s3.set(a, b, (sm.get(a, b) + sm.get(b, a)) * 0.5)
        var ev = sym_eigen3(s3)
        var sig = ev[0]
        var eps = Vec3(log(max(sig[0], Real(1e-6))), log(max(sig[1], Real(1e-6))), log(max(sig[2], Real(1e-6))), 0)
        var tr = eps[0] + eps[1] + eps[2]
        var newsig: Vec3
        if tr >= 0:
            newsig = Vec3(1, 1, 1, 0)  # no tension: forget the strain
        else:
            var dev = eps - Vec3(tr / 3, tr / 3, tr / 3, 0)
            var dn = length(dev)
            var dgamma = dn + (3 * self.lam + 2 * self.mu) / (2 * self.mu) * tr * self.dp_alpha
            if dgamma <= 0 or dn < 1e-12:
                return f
            var h = eps - dev * (dgamma / dn)
            newsig = Vec3(exp(h[0]), exp(h[1]), exp(h[2]), 0)
        # F = U diag(sigma) V^T with U = R V
        var v = ev[1]
        var out = Mat3()
        for a in range(3):
            for b in range(3):
                var acc = Real(0)
                for k in range(3):
                    acc += v.get(a, k) * newsig[k] * v.get(b, k)
                out.set(a, b, acc)
        return r * out

    def _obstacle(mut self, i: Int, j: Int, k: Int, idx: Int):
        """Separate a grid node's velocity from every obstacle it is inside."""
        var x = self.lo + Vec3(Real(i), Real(j), Real(k), 0) * self.dx
        for o in range(len(self.obstacles)):
            if self.obstacles[o].distance(x) >= 0:
                continue
            var g = self.obstacles[o].gradient(x)
            var gl = length(g)
            if not (gl > 0):
                continue
            var n = g / gl
            var v = Vec3(self.gvx[idx], self.gvy[idx], self.gvz[idx], 0)
            var vn = dot(v, n)
            if vn >= 0:
                continue
            var vt = v - n * vn
            var tl = length(vt)
            var mu = self.obstacle_mu[o]
            if tl <= -mu * vn:
                v = Vec3(0, 0, 0, 0)
            else:
                v = vt * (1 + mu * vn / tl)
            self.gvx[idx] = v[0]
            self.gvy[idx] = v[1]
            self.gvz[idx] = v[2]

    def _push_out(mut self, pi: Int):
        """Move a particle that ended inside an obstacle back to its surface
        and drop its velocity into it: the grid-node projection alone let
        surface particles pick up inward velocity from the nodes outside
        (measured: 80 of 288 sand particles more than half a cell inside a
        box)."""
        for o in range(len(self.obstacles)):
            var x = self.p[pi].x
            var d = self.obstacles[o].distance(x)
            if d >= 0:
                continue
            var g = self.obstacles[o].gradient(x)
            var gl = length(g)
            if not (gl > 0):
                continue
            var n = g / gl
            self.p[pi].x = x - n * d
            var vn = dot(self.p[pi].v, n)
            if vn < 0:
                self.p[pi].v = self.p[pi].v - n * vn

    def _gi(self, i: Int, j: Int, k: Int) -> Int:
        return (k * self.n + j) * self.n + i

    def total_mass(self) -> Real:
        var m = Real(0)
        for ref q in self.p:
            m += q.mass
        return m

    def total_momentum(self) -> Vec3:
        var s = Vec3(0, 0, 0, 0)
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
            var wx = Array[Real, 3](fill=0)
            var wy = Array[Real, 3](fill=0)
            var wz = Array[Real, 3](fill=0)
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
            var jdet = det3(q.f)
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
            var wx = Array[Real, 3](fill=0)
            var wy = Array[Real, 3](fill=0)
            var wz = Array[Real, 3](fill=0)
            wx[0] = 0.5 * (1.5 - fx) * (1.5 - fx)
            wx[1] = 0.75 - (fx - 1.0) * (fx - 1.0)
            wx[2] = 0.5 * (fx - 0.5) * (fx - 0.5)
            wy[0] = 0.5 * (1.5 - fy) * (1.5 - fy)
            wy[1] = 0.75 - (fy - 1.0) * (fy - 1.0)
            wy[2] = 0.5 * (fy - 0.5) * (fy - 0.5)
            wz[0] = 0.5 * (1.5 - fz) * (1.5 - fz)
            wz[1] = 0.75 - (fz - 1.0) * (fz - 1.0)
            wz[2] = 0.5 * (fz - 0.5) * (fz - 0.5)

            var nv = Vec3(0, 0, 0, 0)
            var nc = Mat3()
            for i in range(3):
                for j in range(3):
                    for k in range(3):
                        var w = wx[i] * wy[j] * wz[k]
                        var idx = self._gi(bx + i, by + j, bz + k)
                        var gvel = Vec3(
                            self.gvx[idx], self.gvy[idx], self.gvz[idx]
                        , 0)
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
                var jd = det3(q.f)
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

    def step_ext(mut self, dt: Real, gravity: Vec3):
        """`step` plus static obstacles (grid) and Drucker-Prager sand (after
        G2P). A copy of `step` rather than a branch inside it: every way of
        adding the extension to `step` itself that was tried -- run-time
        branches in the body, the body moved into a comptime-parameterised
        helper -- changed how it compiled and moved `test_mpm`'s digits
        (spread 0.20055819 -> 0.20055932). `MpmContinuum` and callers with
        sand or obstacles use this one."""
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
            var wx = Array[Real, 3](fill=0)
            var wy = Array[Real, 3](fill=0)
            var wz = Array[Real, 3](fill=0)
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
            var jdet = det3(q.f)
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
                    self._obstacle(i, j, k, idx)
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
            var wx = Array[Real, 3](fill=0)
            var wy = Array[Real, 3](fill=0)
            var wz = Array[Real, 3](fill=0)
            wx[0] = 0.5 * (1.5 - fx) * (1.5 - fx)
            wx[1] = 0.75 - (fx - 1.0) * (fx - 1.0)
            wx[2] = 0.5 * (fx - 0.5) * (fx - 0.5)
            wy[0] = 0.5 * (1.5 - fy) * (1.5 - fy)
            wy[1] = 0.75 - (fy - 1.0) * (fy - 1.0)
            wy[2] = 0.5 * (fy - 0.5) * (fy - 0.5)
            wz[0] = 0.5 * (1.5 - fz) * (1.5 - fz)
            wz[1] = 0.75 - (fz - 1.0) * (fz - 1.0)
            wz[2] = 0.5 * (fz - 0.5) * (fz - 0.5)

            var nv = Vec3(0, 0, 0, 0)
            var nc = Mat3()
            for i in range(3):
                for j in range(3):
                    for k in range(3):
                        var w = wx[i] * wy[j] * wz[k]
                        var idx = self._gi(bx + i, by + j, bz + k)
                        var gvel = Vec3(
                            self.gvx[idx], self.gvy[idx], self.gvz[idx]
                        , 0)
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
                var jd = det3(q.f)
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
        if self.dp_alpha > 0:
            for pi in range(len(self.p)):
                self.p[pi].f = self._sand(self.p[pi].f)
        if len(self.obstacles) > 0:
            for pi in range(len(self.p)):
                self._push_out(pi)
