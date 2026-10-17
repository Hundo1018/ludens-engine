"""Sediment: grains suspended in lattice fluid, two-way (ROADMAP 17.61:
particle-fluid, "silt in suspension").

`Sediment` owns an `Lbm` (the `ClothAir` lattice conventions) and a set
of point grains, each of density `rho_p` and diameter `d`, in a fluid of
density `rho` and kinematic viscosity `nu`. Per step:

  * fluid velocity u at the grain (trilinear, `lattice_velocity`);
  * Stokes drag at rate beta = 18 rho nu / (rho_p d^2) toward u, gravity
    reduced by buoyancy, g (1 - rho / rho_p), integrated implicitly:
    v <- (v + beta dt u + g' dt) / (1 + beta dt), so the still-fluid
    settling speed is g' / beta (Stokes' law) for any beta dt;
  * the grain's drag impulse m beta dt (u - v_new) is removed from the
    fluid at the 8 surrounding cells (two-way), as `ClothAir` does;
  * x <- x + v dt, clamped into [lo, hi] (a grain at the floor stops);
  * the lattice step.

Grains are not resolved (d << dx) and do not collide with each other; a
dense pile is outside this model (MPM sand, 17.58). Buoyancy and weight
are not passed to the fluid (the hydrostatic part stays in the lattice's
own pressure); only drag is exchanged, so `fluid_impulse` is minus the
grains' drag impulse exactly.
"""

from geometry.vec import Real, Vec3
from fluid.lbm import Lbm
from .cloth_air import lattice_corners, lattice_velocity, lattice_momentum


struct Sediment(Movable):
    var lbm: Lbm
    var origin: Vec3
    var dx: Real
    var dt: Real
    var rho: Real
    var nu: Real
    var rho_p: Real
    var diameter: Real
    var mass: Real  # per grain
    var x: List[Vec3]
    var v: List[Vec3]
    var lo: Vec3
    var hi: Vec3
    var two_way: Bool
    var fluid_impulse: Vec3
    var grain_drag_impulse: Vec3

    def __init__(out self, var lbm: Lbm, origin: Vec3, dx: Real, dt: Real, rho: Real, nu: Real, rho_p: Real, diameter: Real, lo: Vec3, hi: Vec3, two_way: Bool = True) raises:
        if not (dx > 0) or not (dt > 0) or not (rho > 0) or not (nu > 0) or not (rho_p > 0) or not (diameter > 0):
            raise Error("Sediment: dx, dt, rho, nu, rho_p and diameter must be > 0")
        self.lbm = lbm^
        self.origin = origin
        self.dx = dx
        self.dt = dt
        self.rho = rho
        self.nu = nu
        self.rho_p = rho_p
        self.diameter = diameter
        self.mass = rho_p * Real(3.14159265358979) * diameter * diameter * diameter / 6
        self.x = List[Vec3]()
        self.v = List[Vec3]()
        self.lo = lo
        self.hi = hi
        self.two_way = two_way
        self.fluid_impulse = Vec3(0, 0, 0, 0)
        self.grain_drag_impulse = Vec3(0, 0, 0, 0)

    def add(mut self, p: Vec3):
        self.x.append(p)
        self.v.append(Vec3(0, 0, 0, 0))

    def beta(self) -> Real:
        """Stokes drag rate, 1/s."""
        return 18 * self.rho * self.nu / (self.rho_p * self.diameter * self.diameter)

    def settling_speed(self, gravity: Vec3) -> Real:
        """Stokes terminal speed in still fluid, |g| (1 - rho / rho_p) / beta."""
        var g = gravity * (1 - self.rho / self.rho_p)
        return (g[0] * g[0] + g[1] * g[1] + g[2] * g[2]) ** 0.5 / self.beta()

    def fluid_velocity(self, p: Vec3) -> Vec3:
        return lattice_velocity(self.lbm, self.origin, self.dx, self.dt, p)

    def fluid_momentum(self) -> Vec3:
        return lattice_momentum(self.lbm, self.rho, self.dx, self.dt)

    def mean_height(self) -> Real:
        var s = Real(0)
        for p in self.x:
            s += p[1]
        return s / Real(len(self.x)) if len(self.x) > 0 else Real(0)

    def step(mut self, gravity: Vec3):
        self.lbm.clear_cell_force()
        var a = self.beta() * self.dt
        var gb = gravity * (1 - self.rho / self.rho_p)
        var to_lat = self.dt / (self.rho * self.dx * self.dx * self.dx * self.dx)
        for i in range(len(self.x)):
            var u = self.fluid_velocity(self.x[i])
            var vn = (self.v[i] + u * a + gb * self.dt) * (1 / (1 + a))
            var j = (u - vn) * (self.mass * a)  # drag impulse on the grain
            self.grain_drag_impulse = self.grain_drag_impulse + j
            if self.two_way:
                self.fluid_impulse = self.fluid_impulse - j
                var cw = lattice_corners(self.lbm, self.origin, self.dx, self.x[i])
                var cs = cw[0].copy()
                var ws = cw[1].copy()
                for q in range(8):
                    self.lbm.add_cell_force(cs[q], j * (-to_lat * ws[q]))
            var p = self.x[i] + vn * self.dt
            for ax in range(3):
                if p[ax] < self.lo[ax]:
                    p[ax] = self.lo[ax]
                    vn[ax] = 0
                elif p[ax] > self.hi[ax]:
                    p[ax] = self.hi[ax]
                    vn[ax] = 0
            self.x[i] = p
            self.v[i] = vn
        self.lbm.step()
