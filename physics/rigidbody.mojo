"""A dimension-generic rigid body for the contact-solver benchmark.

`RigidBody[dim]` carries linear state (position, velocity), an inverse mass
(`0` = static / infinite mass) and contact material (restitution, friction),
plus box half-extents so the step driver can build an `AABB` and feed the
existing collision pipeline. Phase 2 is *linear* dynamics — angular velocity /
inertia tensors are deferred (they need contact points the AABB narrowphase does
not yet produce). Linear-only keeps the body, the solvers and friction (a single
tangent along the sliding velocity) genuinely dimension-generic for 2D and 3D.
"""

from geometry.vec import WorldType, Real
from geometry.aabb import AABB


@fieldwise_init
struct RigidBody[dim: Int](Copyable, ImplicitlyCopyable, Movable, ImplicitlyDeletable):
    var pos: SIMD[WorldType, Self.dim]
    var vel: SIMD[WorldType, Self.dim]
    var inv_mass: Real  # 0 => static (infinite mass)
    var restitution: Real
    var friction: Real
    var half: SIMD[WorldType, Self.dim]  # box half-extents

    @staticmethod
    def dynamic(
        pos: SIMD[WorldType, Self.dim],
        half: SIMD[WorldType, Self.dim],
        mass: Real,
        restitution: Real = 0,
        friction: Real = 0,
    ) -> Self:
        var im = Real(0)
        if mass > 0:
            im = Real(1) / mass
        return Self(
            pos, SIMD[WorldType, Self.dim](0), im, restitution, friction, half
        )

    @staticmethod
    def static_box(
        pos: SIMD[WorldType, Self.dim],
        half: SIMD[WorldType, Self.dim],
        restitution: Real = 0,
        friction: Real = 0,
    ) -> Self:
        return Self(
            pos, SIMD[WorldType, Self.dim](0), 0, restitution, friction, half
        )

    def with_velocity(self, v: SIMD[WorldType, Self.dim]) -> Self:
        var r = self
        r.vel = v
        return r

    def is_static(self) -> Bool:
        return self.inv_mass == 0

    def aabb(self) -> AABB[Self.dim]:
        return AABB[Self.dim].from_center(self.pos, self.half)
