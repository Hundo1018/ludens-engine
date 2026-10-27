"""Melting and freezing MPM material (ROADMAP 17.61: phase change, "wax
melting").

`MpmMelt` rides on an `MpmSolver`: each particle carries a specific
enthalpy H (J/kg, f64), from which temperature and melt fraction follow
(the enthalpy method):

    H <= c Tm            solid,  T = H / c,            phi = 0
    c Tm < H < c Tm + L  mushy,  T = Tm,               phi = (H - c Tm) / L
    H >= c Tm + L        liquid, T = (H - L) / c,      phi = 1

`step(mpm, dt, gravity)`:
  1. `mpm.step_ext(dt, gravity)` (the mechanics);
  2. conduction among the particles at their new positions
     (`HeatParticles`, neighbour lists rebuilt, substepped below its bound);
     each particle's temperature change becomes c dT of enthalpy, so
     conduction moves enthalpy without creating it, also through the
     latent plateau;
  3. heat from a hot floor: particles below `floor_y` receive
     h (T_floor - T) dx^2 dt (dx = particle spacing);
  4. T and phi from H; a liquid particle (phi = 1) forgets its shear
     memory, F <- J^(1/3) I, so it keeps resisting compression but flows.
     A particle that freezes again keeps that isotropic F as its new rest
     state: the frozen shape is stress free. A mushy particle keeps a
     fraction 1 - phi of its shear modulus (`MpmParticle.shear`, set from
     phi before the next mechanics step), so it softens continuously toward
     the liquid; its volumetric stiffness is unchanged.

`heat_in` sums the floor's heat (J); the total enthalpy sum m H changes by
exactly that (up to rounding), which is what `test_mpm_melt` checks.
"""

from geometry.vec import Real, Vec3
from geometry.mat import Mat3
from physics.fem import det3
from .mpm import MpmSolver
from .thermal import HeatParticles


def melt_state(h: Float64, c: Real, latent: Real, t_melt: Real) -> Tuple[Real, Real]:
    """(T, phi) of specific enthalpy h (module note)."""
    var hs = Float64(c) * Float64(t_melt)
    if h <= hs:
        return (Real(h / Float64(c)), Real(0))
    if h < hs + Float64(latent):
        return (t_melt, Real((h - hs) / Float64(latent)))
    return (Real((h - Float64(latent)) / Float64(c)), Real(1))


struct MpmMelt(Movable):
    var heat: HeatParticles
    var c: Real  # specific heat, J / (kg K)
    var latent: Real  # J / kg
    var t_melt: Real
    var enthalpy: List[Float64]  # J / kg per particle
    var phi: List[Real]
    var spacing: Real
    var floor_y: Real
    var floor_t: Real
    var floor_h: Real  # W / (m^2 K); 0 = no floor heating
    var heat_in: Float64

    def __init__(out self, mpm: MpmSolver, spacing: Real, alpha: Real, c: Real, latent: Real, t_melt: Real, t0: Real) raises:
        if len(mpm.p) == 0:
            raise Error("MpmMelt: the solver has no particles")
        if not (c > 0) or not (latent > 0) or not (t_melt > 0) or not (spacing > 0):
            raise Error("MpmMelt: c, latent, t_melt and spacing must be > 0")
        var x = List[Vec3]()
        for ref q in mpm.p:
            x.append(q.x)
        self.heat = HeatParticles(x^, mpm.p[0].vol, spacing, alpha, t0)
        self.c = c
        self.latent = latent
        self.t_melt = t_melt
        self.spacing = spacing
        var h0 = Float64(c) * Float64(t0)
        if t0 > t_melt:
            h0 += Float64(latent)
        self.enthalpy = List[Float64](length=len(mpm.p), fill=h0)
        self.phi = List[Real](length=len(mpm.p), fill=Real(1) if t0 > t_melt else Real(0))
        self.floor_y = 0
        self.floor_t = t0
        self.floor_h = 0
        self.heat_in = 0
        for i in range(len(self.phi)):
            self.heat.t[i] = melt_state(self.enthalpy[i], c, latent, t_melt)[0]

    def heat_floor(mut self, y: Real, temp: Real, h: Real) raises:
        if not (temp > 0) or not (h >= 0):
            raise Error("MpmMelt.heat_floor: temp > 0 K and h >= 0")
        self.floor_y = y
        self.floor_t = temp
        self.floor_h = h

    def total_enthalpy(self, mpm: MpmSolver) -> Float64:
        var s = Float64(0)
        for i in range(len(self.enthalpy)):
            s += Float64(mpm.p[i].mass) * self.enthalpy[i]
        return s

    def melted(self) -> Real:
        """Mean melt fraction."""
        var s = Real(0)
        for v in self.phi:
            s += v
        return s / Real(len(self.phi))

    def step(mut self, mut mpm: MpmSolver, dt: Real, gravity: Vec3) raises:
        var n = len(self.enthalpy)
        if len(mpm.p) != n:
            raise Error("MpmMelt.step: the solver's particle count changed")
        for i in range(n):
            mpm.p[i].shear = 1 - self.phi[i]
        mpm.step_ext(dt, gravity)
        for i in range(n):
            self.heat.x[i] = mpm.p[i].x
        self.heat.rebuild()
        var t_before = self.heat.t.copy()
        var sub = Int(dt / self.heat.max_dt()) + 1
        for _ in range(sub):
            self.heat.step(dt / Real(sub))
        var area = self.spacing * self.spacing
        for i in range(n):
            var m = Float64(mpm.p[i].mass)
            self.enthalpy[i] += Float64(self.c) * Float64(self.heat.t[i] - t_before[i])
            if self.floor_h > 0 and mpm.p[i].x[1] < self.floor_y:
                var q = Float64(self.floor_h * area * (self.floor_t - self.heat.t[i]) * dt)
                self.enthalpy[i] += q / m
                self.heat_in += q
            var st = melt_state(self.enthalpy[i], self.c, self.latent, self.t_melt)
            self.heat.t[i] = st[0]
            self.phi[i] = st[1]
            if st[1] >= 1:
                var j = det3(mpm.p[i].f)
                var s = j ** (Real(1) / 3) if j > 0 else Real(1)
                var f = Mat3()
                for a in range(3):
                    f.set(a, a, s)
                mpm.p[i].f = f
