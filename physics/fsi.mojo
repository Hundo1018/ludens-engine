"""LBM <-> rigid body coupling (ROADMAP 17.59).

`fluid.lbm.Lbm` now carries moving solids (Ladd 1994 bounce-back, force and
torque per object by momentum exchange). This module ties one of them to a
`ContactScene6` sphere, two-way, explicitly, one lattice step per physics
step:

  1. the body's pose and velocities, in lattice units, go to `move_sphere`
     (x_lat = (x - origin) / dx, v_lat = v dt / dx, w_lat = w dt);
  2. `Lbm.step`;
  3. the fluid's force and torque on the sphere, back in SI
     (F = F_lat rho dx^4 / dt^2, T = T_lat rho dx^5 / dt^2), plus the
     buoyancy -rho V g (the lattice has no hydrostatic pressure), go to
     `add_force` / `add_torque`;
  4. `ContactScene6.step` with the same dt, so the sphere still collides
     with every other body in the scene.

Explicit partitioned coupling is unstable for light bodies (added mass);
`test_fsi` measures where (density ratios 1.5 and 1.0). Coupled bodies have
sleep disabled: a body in a moving fluid must not freeze.
"""

from std.math import pi
from geometry.vec import Real, Vec3
from fluid.lbm import Lbm
from .body_set import BodyId
from .rigid6 import Body6
from .solver6 import ContactScene6
from .solver_config import SolverConfig


struct LbmCoupler(Movable):
    var lbm: Lbm
    var dx: Real  # metres per cell
    var dt: Real  # seconds per lattice step (= physics step)
    var rho: Real  # fluid density, kg / m^3
    var origin: Vec3  # world position of cell (0, 0, 0)
    var bodies: List[BodyId]
    var objs: List[Int]
    var radii: List[Real]

    def __init__(out self, var lbm: Lbm, dx: Real, dt: Real, rho: Real, origin: Vec3):
        self.lbm = lbm^
        self.dx = dx
        self.dt = dt
        self.rho = rho
        self.origin = origin
        self.bodies = List[BodyId]()
        self.objs = List[Int]()
        self.radii = List[Real]()

    @staticmethod
    def lattice_viscosity(nu: Real, dx: Real, dt: Real) -> Real:
        """Kinematic viscosity (m^2 / s) in lattice units."""
        return nu * dt / (dx * dx)

    def _lat(self, p: Vec3) -> Vec3:
        return (p - self.origin) * (1 / self.dx)

    def add_sphere[B: Body6](mut self, mut sc: ContactScene6[B], id: BodyId, radius: Real) raises -> Int:
        var pose = sc.pose(id)
        var v = sc.velocity(id) * (self.dt / self.dx)
        var w = sc.angular_velocity(id) * self.dt
        var k = self.lbm.add_moving_sphere(self._lat(pose.pos), radius / self.dx, v, w)
        sc.set_sleep_thresholds(id, 0, 0)
        self.bodies.append(id)
        self.objs.append(k)
        self.radii.append(radius)
        return len(self.bodies) - 1

    def fluid_force(self, j: Int) -> Vec3:
        """SI force of the fluid on coupled body `j` over the last step."""
        var s = self.rho * self.dx * self.dx * self.dx * self.dx / (self.dt * self.dt)
        return self.lbm.obj_f[self.objs[j]] * s

    def fluid_torque(self, j: Int) -> Vec3:
        var s = self.rho * self.dx * self.dx * self.dx * self.dx * self.dx / (self.dt * self.dt)
        return self.lbm.obj_t[self.objs[j]] * s

    def step[B: Body6](mut self, mut sc: ContactScene6[B], gravity: Vec3, cfg: SolverConfig) raises:
        for j in range(len(self.bodies)):
            var id = self.bodies[j]
            var pose = sc.pose(id)
            var v = sc.velocity(id) * (self.dt / self.dx)
            var w = sc.angular_velocity(id) * self.dt
            self.lbm.move_sphere(self.objs[j], self._lat(pose.pos), v, w)
        self.lbm.step()
        for j in range(len(self.bodies)):
            var r = self.radii[j]
            var vol = Real(4.0 / 3.0 * pi) * r * r * r
            sc.add_force(self.bodies[j], self.fluid_force(j) - gravity * (self.rho * vol))
            sc.add_torque(self.bodies[j], self.fluid_torque(j))
        sc.step(self.dt, gravity, cfg)
