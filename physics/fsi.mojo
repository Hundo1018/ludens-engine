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

`LbmSpherePort.set_implicit(True)` (opt-in, off by default) stabilises
light bodies the way Ladd & Verberg 2001 do: the part of the lattice force
linear in the wall velocity, -Z u_w with Z = `Lbm.wall_drag` (the sum of
6 w_i c_i c_i over the sphere's boundary links, measured once per sphere
when it is added; rho Z dx^3 is about 0.68 rho V for R = 3 cells), is taken
at the new velocity instead of the old one, so the body moves as
(m + rho Z dx^3) dv = (F + m g) dt per axis, and likewise for the torque,
(I + rho Z_r dx^5) dw = T dt, Z_r the rotational link sum (without it the
spin of a light sphere flips sign every step and grows). The lagged term is what
diverges explicitly (|1 - Z/m| > 1 once the body is light). The terminal
velocity is unchanged (dv = 0 either way). Off, the port is
`LbmCoupler.step` bit for bit. `scripts/added_mass_fit.py` fits the
lattice's force response and gives the spectral radius of each scheme.
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
from .state_io import StateWriter, StateReader


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
    var implicit: Bool  # implicit wall drag (module note)
    var zeta: List[Vec3]  # per sphere: rho Z dx^3, kg per axis
    var zeta_rot: List[Vec3]  # per sphere: rho Z_r dx^5, kg m^2 per axis

    def __init__(out self, dx: Real, rho: Real, origin: Vec3):
        self.dx = dx
        self.rho = rho
        self.origin = origin
        self.bodies = List[BodyId]()
        self.objs = List[Int]()
        self.radii = List[Real]()
        self.implicit = False
        self.zeta = List[Vec3]()
        self.zeta_rot = List[Vec3]()

    def set_implicit(mut self, on: Bool):
        """Implicit wall drag for light bodies (module note)."""
        self.implicit = on

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
        var dx3 = self.dx * self.dx * self.dx
        var zd = s.lbm.wall_drag(k)
        self.zeta.append(zd[0] * (self.rho * dx3))
        self.zeta_rot.append(zd[1] * (self.rho * dx3 * self.dx * self.dx))
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
            if self.implicit:
                self._apply_implicit(scene, j, ld[0], ld[1], gravity)
            else:
                scene.add_force(self.bodies[j], ld[0])
                scene.add_torque(self.bodies[j], ld[1])

    def _apply_implicit[B: Body6](mut self, mut scene: ContactScene6[B], j: Int, f: Vec3, t: Vec3, gravity: Vec3) raises:
        var id = self.bodies[j]
        ref body = scene.bset.bodies[id.index()]
        var im = body.inv_mass()
        if not (im > 0):
            scene.add_force(id, f)
            scene.add_torque(id, t)
            return
        var m = 1 / im
        var z = self.zeta[j]
        var zr = self.zeta_rot[j]
        # per axis: dv = (F + m g) dt / (m + z), dw = T dt / (I + z_r); the
        # scene adds m g itself
        var out = Vec3(0, 0, 0, 0)
        var tout = Vec3(0, 0, 0, 0)
        for a in range(3):
            out[a] = (f[a] * m - gravity[a] * (z[a] * m)) / (m + z[a])
            var ax = Vec3(0, 0, 0, 0)
            ax[a] = 1
            var ia = 1 / body.angular_only_factor(ax)
            tout[a] = t[a] * ia / (ia + zr[a])
        scene.add_force(id, out)
        scene.add_torque(id, tout)


def lbm_write[W: StateWriter](l: Lbm, mut w: W):
    """Dynamical lattice state (17.59): populations, cell flags, moving-wall
    fields and moving spheres, plus the channel force. The rest (size,
    viscosity, mode, interpolation) is construction: restore into a lattice
    built the same way."""
    var n = l.cells()
    w.wi(n)
    for i in range(len(l.f)):
        w.wf(l.f[i])
    for c in range(n):
        w.wi(l.flag[c])
    w.wf(l.force_x)
    w.wi(1 if l.moving else 0)
    if l.moving:
        for c in range(n):
            w.wf(l.wux[c])
            w.wf(l.wuy[c])
            w.wf(l.wuz[c])
            w.wi(l.owner[c])
    w.wi(len(l.obj_c))
    for k in range(len(l.obj_c)):
        w.wv(l.obj_c[k])
        w.wf(l.obj_r[k])
        w.wv(l.obj_v[k])
        w.wv(l.obj_w[k])
        w.wv(l.obj_f[k])
        w.wv(l.obj_t[k])
        w.wv(l.obj_p[k])


def lbm_read[R: StateReader](mut l: Lbm, mut r: R) raises:
    """Inverse of `lbm_write`; raises when the cell or sphere count differs
    from this lattice's."""
    var n = l.cells()
    if r.ri() != n:
        raise Error("lbm_read: cell count differs from this lattice")
    for i in range(len(l.f)):
        l.f[i] = r.rf()
    for c in range(n):
        l.flag[c] = r.ri()
    l.force_x = r.rf()
    var mv = r.ri() == 1
    if mv != l.moving:
        raise Error("lbm_read: moving-solid state differs from this lattice")
    if mv:
        for c in range(n):
            l.wux[c] = r.rf()
            l.wuy[c] = r.rf()
            l.wuz[c] = r.rf()
            l.owner[c] = r.ri()
    if r.ri() != len(l.obj_c):
        raise Error("lbm_read: moving sphere count differs from this lattice")
    for k in range(len(l.obj_c)):
        l.obj_c[k] = r.rv()
        l.obj_r[k] = r.rf()
        l.obj_v[k] = r.rv()
        l.obj_w[k] = r.rv()
        l.obj_f[k] = r.rv()
        l.obj_t[k] = r.rv()
        l.obj_p[k] = r.rv()


def lbm_continuum_write[W: StateWriter](s: LbmContinuum, mut w: W):
    """`lbm_write` plus the continuum's sub-step carry and step count."""
    lbm_write(s.lbm, w)
    w.wf(s.carry)
    w.wi(s.steps_run)


def lbm_continuum_read[R: StateReader](mut s: LbmContinuum, mut r: R) raises:
    lbm_read(s.lbm, r)
    s.carry = r.rf()
    s.steps_run = r.ri()


def sphere_port_write[W: StateWriter](p: LbmSpherePort, mut w: W):
    """The port's measured wall drag per sphere and its mode (a restored
    port re-measures `Lbm.wall_drag` where its sphere is added; this keeps
    the original's)."""
    w.wi(1 if p.implicit else 0)
    w.wi(len(p.zeta))
    for j in range(len(p.zeta)):
        w.wv(p.zeta[j])
        w.wv(p.zeta_rot[j])


def sphere_port_read[R: StateReader](mut p: LbmSpherePort, mut r: R) raises:
    p.implicit = r.ri() == 1
    if r.ri() != len(p.zeta):
        raise Error("sphere_port_read: sphere count differs from this port")
    for j in range(len(p.zeta)):
        p.zeta[j] = r.rv()
        p.zeta_rot[j] = r.rv()
