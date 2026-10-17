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
from .continuum import LbmContinuum
from .coupling import CouplingPort


@no_inline
def sphere_drive(pos: Vec3, vel: Vec3, omega: Vec3, origin: Vec3, dx: Real, dt: Real) -> Tuple[Vec3, Vec3, Vec3]:
    """Lattice position, velocity and angular velocity of a coupled sphere
    (one compiled function shared by `LbmCoupler` and `LbmSpherePort`, so
    both paths round the same way on every target: inlined copies can fuse
    multiply-adds differently, which broke their bit-for-bit parity on
    aarch64)."""
    return ((pos - origin) * (1 / dx), vel * (dt / dx), omega * dt)


@no_inline
def sphere_load(obj_f: Vec3, obj_t: Vec3, rho: Real, dx: Real, dt: Real, radius: Real, gravity: Vec3) -> Tuple[Vec3, Vec3]:
    """SI force (fluid + buoyancy) and torque on a coupled sphere from the
    lattice's momentum exchange (shared, see `sphere_drive`)."""
    var sf = rho * dx * dx * dx * dx / (dt * dt)
    var st = rho * dx * dx * dx * dx * dx / (dt * dt)
    var vol = Real(4.0 / 3.0 * pi) * radius * radius * radius
    return (obj_f * sf - gravity * (rho * vol), obj_t * st)


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
            var d = sphere_drive(sc.pose(id).pos, sc.velocity(id), sc.angular_velocity(id), self.origin, self.dx, self.dt)
            self.lbm.move_sphere(self.objs[j], d[0], d[1], d[2])
        self.lbm.step()
        for j in range(len(self.bodies)):
            var ld = sphere_load(self.lbm.obj_f[self.objs[j]], self.lbm.obj_t[self.objs[j]], self.rho, self.dx, self.dt, self.radii[j], gravity)
            sc.add_force(self.bodies[j], ld[0])
            sc.add_torque(self.bodies[j], ld[1])
        sc.step(self.dt, gravity, cfg)


struct LbmSpherePort(CouplingPort):
    """`LbmCoupler`'s exchange as a `CouplingPort` over an `LbmContinuum`
    (ROADMAP 17.55): `before` moves each coupled sphere's lattice boundary
    to the body's pose and velocity, `after` applies the fluid's force and
    torque plus buoyancy. With `couple_step` and dt equal to the lattice
    step it is `LbmCoupler.step` bit for bit (`test_coupling`)."""

    comptime S = LbmContinuum

    var dx: Real
    var rho: Real
    var origin: Vec3
    var bodies: List[BodyId]
    var objs: List[Int]
    var radii: List[Real]

    def __init__(out self, dx: Real, rho: Real, origin: Vec3):
        self.dx = dx
        self.rho = rho
        self.origin = origin
        self.bodies = List[BodyId]()
        self.objs = List[Int]()
        self.radii = List[Real]()

    def _lat(self, p: Vec3) -> Vec3:
        return (p - self.origin) * (1 / self.dx)

    def add_sphere[B: Body6](mut self, mut sc: ContactScene6[B], mut s: LbmContinuum, id: BodyId, radius: Real) raises -> Int:
        var dt = s.dt_lattice
        var pose = sc.pose(id)
        var v = sc.velocity(id) * (dt / self.dx)
        var w = sc.angular_velocity(id) * dt
        var k = s.lbm.add_moving_sphere(self._lat(pose.pos), radius / self.dx, v, w)
        sc.set_sleep_thresholds(id, 0, 0)
        self.bodies.append(id)
        self.objs.append(k)
        self.radii.append(radius)
        return len(self.bodies) - 1

    def before[B: Body6](mut self, mut scene: ContactScene6[B], mut s: LbmContinuum, dt: Real, gravity: Vec3) raises:
        var dtl = s.dt_lattice
        for j in range(len(self.bodies)):
            var id = self.bodies[j]
            var d = sphere_drive(scene.pose(id).pos, scene.velocity(id), scene.angular_velocity(id), self.origin, self.dx, dtl)
            s.lbm.move_sphere(self.objs[j], d[0], d[1], d[2])

    def after[B: Body6](mut self, mut scene: ContactScene6[B], mut s: LbmContinuum, dt: Real, gravity: Vec3) raises:
        var dtl = s.dt_lattice
        for j in range(len(self.bodies)):
            var ld = sphere_load(s.lbm.obj_f[self.objs[j]], s.lbm.obj_t[self.objs[j]], self.rho, self.dx, dtl, self.radii[j], gravity)
            scene.add_force(self.bodies[j], ld[0])
            scene.add_torque(self.bodies[j], ld[1])
