"""Weakly-compressible SPH — the force-based fluid, next to PBF's projection.

Deliberately operates on the SAME `PbfFluid` particle state and the same
uniform grid, so the two solvers are compared on identical storage, identical
neighbour search and identical kernels. The only thing that differs is how
incompressibility is enforced, which is exactly the comparison worth having:

  SPH  — density is measured, an equation of state turns the excess into a
         PRESSURE, and pressure gradients become forces that are integrated.
         Incompressibility is approached by making the fluid stiff.
  PBF  — density error is a CONSTRAINT, and positions are projected to satisfy
         it directly. Incompressibility is approached by iterating.

That difference has one dominant practical consequence and this module exists
to measure it: a stiff explicit solver is CFL-limited. The pressure term acts
like a spring whose stiffness is the bulk modulus, so the stable timestep
shrinks as the fluid is made less compressible, while PBF's projection has no
such limit and trades accuracy for iterations instead. `bench_sph` sweeps the
timestep for both and reports where each one stops being usable.

Negative pressure is clamped away (`max(p, 0)`). Real SPH tension pulls
particles together and produces the same clumping PBF fights with its tensile
correction; clamping is the standard cheap fix and is what makes the free
surface hold together here.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3
from physics.pbf import PbfFluid, poly6, spiky_grad, H

comptime _STIFF: Real = 8.0  # equation-of-state stiffness (bulk modulus proxy)
comptime _VISC: Real = 0.15  # dynamic viscosity


def visc_lap(r: Real) -> Real:
    """Laplacian of the standard SPH viscosity kernel."""
    if r >= H or r < 0:
        return 0
    return 45.0 / (3.14159265 * (H ** 6)) * (H - r)


struct BoundaryParticles(Movable):
    """Static particles sampling a wall (Akinci et al. 2012). `psi` is each
    one's effective mass: rho0 over the kernel sum of its own boundary
    neighbourhood, so a densely or sparsely sampled wall contributes the
    same density to the fluid next to it."""

    var x: List[Real]
    var y: List[Real]
    var z: List[Real]
    var psi: List[Real]

    def __init__(out self):
        self.x = List[Real]()
        self.y = List[Real]()
        self.z = List[Real]()
        self.psi = List[Real]()

    def add(mut self, p: Vec3):
        self.x.append(p[0])
        self.y.append(p[1])
        self.z.append(p[2])
        self.psi.append(0)

    def finalize(mut self, rho0: Real):
        for b in range(len(self.x)):
            var delta = Real(0)
            for k in range(len(self.x)):
                var dx = self.x[b] - self.x[k]
                var dy = self.y[b] - self.y[k]
                var dz = self.z[b] - self.z[k]
                delta += poly6(dx * dx + dy * dy + dz * dz)
            self.psi[b] = rho0 / delta if delta > 0 else Real(0)


def box_floor_boundary(lo: Vec3, hi: Vec3, spacing: Real, rho0: Real) -> BoundaryParticles:
    """One layer of boundary particles half a spacing below the floor of the
    box [lo, hi], covering its footprint plus a kernel radius."""
    var b = BoundaryParticles()
    var nx = Int((hi[0] - lo[0] + 2 * H) / spacing) + 1
    var nz = Int((hi[2] - lo[2] + 2 * H) / spacing) + 1
    for i in range(nx):
        for k in range(nz):
            b.add(Vec3(lo[0] - H + Real(i) * spacing, lo[1] - spacing * 0.5, lo[2] - H + Real(k) * spacing, 0))
    b.finalize(rho0)
    return b^


def sph_step(mut f: PbfFluid, dt: Real, gravity: Vec3):
    """One explicit WCSPH step over the shared particle state, walls by
    clamping only (no boundary particles)."""
    sph_step_boundary(f, BoundaryParticles(), dt, gravity)


def sph_step_boundary(mut f: PbfFluid, bnd: BoundaryParticles, dt: Real, gravity: Vec3):
    """`sph_step` with Akinci-style boundary particles (ROADMAP 17.42 d):
    each boundary particle adds `psi_b W` to a fluid particle's density --
    so a particle at the floor is no longer missing half its neighbours --
    and pushes with the pressure term `-psi_b p_i / rho_i^2 grad W`. With no
    boundary particles the loops are empty and this IS `sph_step`."""
    var n = f.count()
    f._rebuild_grid()

    var rho = List[Real]()
    var pres = List[Real]()
    var nbr = List[Int]()
    for i in range(n):
        f._neighbors(i, nbr)
        var d = f.density(i, nbr)
        for b in range(len(bnd.x)):
            var bx = f.px[i] - bnd.x[b]
            var by = f.py[i] - bnd.y[b]
            var bz = f.pz[i] - bnd.z[b]
            d += bnd.psi[b] * poly6(bx * bx + by * by + bz * bz)
        rho.append(d)
        # clamped equation of state: tension would pull particles together and
        # reproduce the clumping PBF spends its tensile term suppressing
        var p = _STIFF * (d - f.rho0)
        pres.append(p if p > 0 else Real(0))

    var ax = List[Real]()
    var ay = List[Real]()
    var az = List[Real]()
    for i in range(n):
        f._neighbors(i, nbr)
        var fx = Real(0)
        var fy = Real(0)
        var fz = Real(0)
        var ri = rho[i] if rho[i] > 1e-9 else Real(1)
        for ref j in nbr:
            var dx = f.px[i] - f.px[j]
            var dy = f.py[i] - f.py[j]
            var dz = f.pz[i] - f.pz[j]
            var r = sqrt(dx * dx + dy * dy + dz * dz)
            if r <= 1e-9:
                continue
            var rj = rho[j] if rho[j] > 1e-9 else Real(1)
            # symmetric pressure term: momentum-conserving form
            var coeff = (pres[i] / (ri * ri) + pres[j] / (rj * rj))
            var g = spiky_grad(r) / r
            fx -= coeff * g * dx
            fy -= coeff * g * dy
            fz -= coeff * g * dz
            # viscosity
            var lap = _VISC * visc_lap(r) / rj
            fx += lap * (f.vx[j] - f.vx[i])
            fy += lap * (f.vy[j] - f.vy[i])
            fz += lap * (f.vz[j] - f.vz[i])
        for b in range(len(bnd.x)):
            var bx = f.px[i] - bnd.x[b]
            var by = f.py[i] - bnd.y[b]
            var bz = f.pz[i] - bnd.z[b]
            var r = sqrt(bx * bx + by * by + bz * bz)
            if r <= 1e-9 or r >= H:
                continue
            var coeff = bnd.psi[b] * pres[i] / (ri * ri)
            var g = spiky_grad(r) / r
            fx -= coeff * g * bx
            fy -= coeff * g * by
            fz -= coeff * g * bz
        ax.append(fx + gravity[0])
        ay.append(fy + gravity[1])
        az.append(fz + gravity[2])

    for i in range(n):
        f.vx[i] += ax[i] * dt
        f.vy[i] += ay[i] * dt
        f.vz[i] += az[i] * dt
        f.px[i] = f.x[i] + f.vx[i] * dt
        f.py[i] = f.y[i] + f.vy[i] * dt
        f.pz[i] = f.z[i] + f.vz[i] * dt
        f._clamp_to_box(i)
        # walls absorb the normal component rather than storing it: without
        # this an explicit solver bounces off the container forever
        if f.px[i] != f.x[i] + f.vx[i] * dt:
            f.vx[i] = 0
        if f.py[i] != f.y[i] + f.vy[i] * dt:
            f.vy[i] = 0
        if f.pz[i] != f.z[i] + f.vz[i] * dt:
            f.vz[i] = 0
        f.x[i] = f.px[i]
        f.y[i] = f.py[i]
        f.z[i] = f.pz[i]
