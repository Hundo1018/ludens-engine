"""MPM <-> rigid body two-way coupling through the grid (ROADMAP 17.59).

A coupled `ContactScene6` body is an `MpmRigid` in the solver: its shape
(an `Sdf3` in the body frame) is posed from the scene each step, grid nodes
inside it take its velocity along the normal (Coulomb on the slip), and
particles that end inside are pushed out. Both changes of momentum are
summed as a force and torque on the body (`MpmSolver._rigid_node`,
`_rigid_push_out`), which the scene then integrates with the same dt -- so
material + body momentum is exchanged, not created (test_mpm_rigid), and
the body still collides with the rest of the scene.

`mpm_rigid_step(mpm, cp, scene, dt, gravity, cfg)`: pose -> `step_ext` ->
forces to the scene -> `scene.step`. Explicit: one MPM step per rigid step.
"""

from geometry.vec import Real, Vec3
from geometry.sdf3 import Sdf3
from .mpm import MpmSolver, MpmRigid
from .body_set import BodyId
from .rigid6 import Body6
from .solver6 import ContactScene6
from .solver_config import SolverConfig
from .state_io import StateWriter, StateReader


struct MpmRigidCoupler(Movable):
    var bodies: List[BodyId]
    var slots: List[Int]  # index into MpmSolver.rigids

    def __init__(out self):
        self.bodies = List[BodyId]()
        self.slots = List[Int]()

    def add[B: Body6](mut self, mut mpm: MpmSolver, mut scene: ContactScene6[B], id: BodyId, shape: Sdf3, mu: Real) raises -> Int:
        """Couple body `id` with `shape` given in its own frame."""
        if not (mu >= 0):
            raise Error("MpmRigidCoupler.add: mu must be >= 0")
        var pose = scene.pose(id)
        mpm.rigids.append(MpmRigid(shape, pose.pos, pose.rot, scene.velocity(id), scene.angular_velocity(id), mu, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0)))
        scene.set_sleep_thresholds(id, 0, 0)
        self.bodies.append(id)
        self.slots.append(len(mpm.rigids) - 1)
        return len(self.bodies) - 1


def mpm_rigid_step[B: Body6](
    mut mpm: MpmSolver,
    cp: MpmRigidCoupler,
    mut scene: ContactScene6[B],
    dt: Real,
    gravity: Vec3,
    cfg: SolverConfig,
) raises:
    """One coupled step (module note)."""
    for b in range(len(cp.bodies)):
        var pose = scene.pose(cp.bodies[b])
        ref r = mpm.rigids[cp.slots[b]]
        r.pos = pose.pos
        r.rot = pose.rot
        r.v = scene.velocity(cp.bodies[b])
        r.w = scene.angular_velocity(cp.bodies[b])
        r.force = Vec3(0, 0, 0, 0)
        r.torque = Vec3(0, 0, 0, 0)
    mpm.step_ext(dt, gravity)
    for b in range(len(cp.bodies)):
        scene.add_force(cp.bodies[b], mpm.rigids[cp.slots[b]].force)
        scene.add_torque(cp.bodies[b], mpm.rigids[cp.slots[b]].torque)
    scene.step(dt, gravity, cfg)


def mpm_rigid_write[W: StateWriter](mpm: MpmSolver, mut w: W):
    """Dynamical state of an MPM <-> rigid run (17.59): the particles (as
    `MpmContinuum.write_state`) and each coupled body's last force and
    torque; the bodies' poses and velocities are re-read from the scene
    every step, which goes through `solver6.write_state`."""
    w.wi(len(mpm.p))
    for ref q in mpm.p:
        w.wv(q.x)
        w.wv(q.v)
        for k in range(9):
            w.wf(q.f.m[k])
        for k in range(9):
            w.wf(q.c.m[k])
        w.wf(q.vol)
        w.wf(q.mass)
    w.wi(len(mpm.rigids))
    for ref r in mpm.rigids:
        w.wv(r.force)
        w.wv(r.torque)


def mpm_rigid_read[R: StateReader](mut mpm: MpmSolver, mut r: R) raises:
    """Inverse of `mpm_rigid_write` into a solver built the same way (same
    particle count, same coupled bodies); raises otherwise."""
    if r.ri() != len(mpm.p):
        raise Error("mpm_rigid_read: particle count differs from this solver")
    for k in range(len(mpm.p)):
        mpm.p[k].x = r.rv()
        mpm.p[k].v = r.rv()
        for c in range(9):
            mpm.p[k].f.m[c] = r.rf()
        for c in range(9):
            mpm.p[k].c.m[c] = r.rf()
        mpm.p[k].vol = r.rf()
        mpm.p[k].mass = r.rf()
    if r.ri() != len(mpm.rigids):
        raise Error("mpm_rigid_read: coupled body count differs from this solver")
    for k in range(len(mpm.rigids)):
        mpm.rigids[k].force = r.rv()
        mpm.rigids[k].torque = r.rv()
