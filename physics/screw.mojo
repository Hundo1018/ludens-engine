"""Screw dynamics: rigid-body state as a PGA motor + velocity bivector.

The engine's `RigidBody[dim]` is linear-only (a known gap). Here the full rigid
state is a `Motor3` pose and a `Screw3` velocity — one bivector carrying BOTH
angular velocity and linear velocity — and integration is the Lie-group step

    pose' = normalize( pose * exp(dt · V/1) )      (V built with half-angle
                                                     factors folded in)

so rotation and translation advance in a single uniform screw per step: no
quaternion renormalization drift vs matrix orthogonalization, and a constant V
traces an exact helix. `ScrewBody` packages this as an ECS component;
`integrate_screw` is the system (generic over storage backends, like
`physics.integrator.integrate`).
"""

from ecs.component import ComponentType
from ecs.world import World
from ecs.storage import StorageBackend
from geometry.vec import Real, Vec3
from geometry.motor import Motor3
from geometry.galie import Screw3, exp_screw3


def screw_velocity(omega: Vec3, v: Vec3) -> Screw3:
    """Velocity bivector from physical angular velocity ω (rad/s, world axes)
    and linear velocity v. Half factors are folded in so `exp(dt·V)` advances
    by exactly ω·dt radians and v·dt units (sandwich doubling accounted)."""
    return Screw3(
        -omega[2] * 0.5,  # b12  (z-axis spin — quat/rotor mapping)
        omega[1] * 0.5,   # b13  (y)
        -omega[0] * 0.5,  # b23  (x)
        v[0] * 0.5,       # b10
        v[1] * 0.5,       # b20
        v[2] * 0.5,       # b30
    )


def step_screw(pose: Motor3, vel: Screw3, dt: Real) -> Motor3:
    """One Lie-group integration step along the screw."""
    return (pose * exp_screw3(vel.scaled(dt))).normalized()


@fieldwise_init
struct ScrewBody(ComponentType):
    """Full rigid state: pose motor + screw velocity (angular AND linear)."""

    comptime ID: Int = 0
    var pose: Motor3
    var vel: Screw3

    @staticmethod
    def at_rest(pos: Vec3) -> Self:
        return Self(Motor3.from_translation(pos), Screw3.zero())

    def position(self) -> Vec3:
        return self.pose.apply_point(Vec3(0, 0, 0))


def integrate_screw[B: StorageBackend](mut w: World[B], dt: Real):
    """Advance every `ScrewBody` one screw step (backend-generic system)."""
    var es = w.query1[ScrewBody]()
    for i in range(len(es)):
        var b = w.get[ScrewBody](es[i])
        b.pose = step_screw(b.pose, b.vel, dt)
        w.set(es[i], b)
