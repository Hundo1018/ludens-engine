"""Shared force integration helpers used by the contact solvers.

`apply_gravity` accelerates every dynamic body; `integrate_positions` advances
positions by the current velocity (semi-implicit Euler when called after the
velocity solve). Static bodies (`inv_mass == 0`) are never moved.
"""

from geometry.vec import WorldType, Real
from .rigidbody import RigidBody


def apply_gravity[dim: Int](
    mut bodies: List[RigidBody[dim]], dt: Real, gravity: SIMD[WorldType, dim]
):
    for ref b in bodies:
        if not b.is_static():
            b.vel = b.vel + gravity * dt


def integrate_positions[dim: Int](mut bodies: List[RigidBody[dim]], dt: Real):
    for ref b in bodies:
        if not b.is_static():
            b.pos = b.pos + b.vel * dt
