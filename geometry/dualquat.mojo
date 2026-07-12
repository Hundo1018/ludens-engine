"""Dual quaternions — the classical 8-float rigid-transform representation.

`DualQuat = real + ε·dual` (two quaternions, ε² = 0) composes by dual-number
Hamilton product and moves points by `q p q* + t` with `t = 2·dual·real*`.

A dual quaternion is isomorphic to a PGA3 motor (both are the even subalgebra
of Cl(3,0,1)); `to_motor` / `from_motor` cross the bridge, and
`tests/test_motor_parity.mojo` asserts the two representations act identically
— a worked example of "same group, two coordinate systems".
"""

from .vec import Real, Vec3
from .quat import Quat
from .motor import Motor3


@fieldwise_init
struct DualQuat(Copyable, ImplicitlyCopyable, Movable, ImplicitlyDeletable):
    var real: Quat  # rotation
    var dual: Quat  # ε-part: encodes translation (0.5 * t * real)

    @staticmethod
    def identity() -> Self:
        return Self(Quat(0, 0, 0, 1), Quat(0, 0, 0, 0))

    @staticmethod
    def from_quat_translation(q: Quat, t: Vec3) -> Self:
        """`q + ε·(0.5 · t_vec · q)` with t as a pure-vector quaternion."""
        var tq = Quat(t[0], t[1], t[2], 0)
        var d = tq * q
        return Self(q, Quat(d.x * 0.5, d.y * 0.5, d.z * 0.5, d.w * 0.5))

    def __mul__(self, o: Self) -> Self:
        """Dual-number Hamilton product: (r1, d1)(r2, d2) = (r1r2, r1d2 + d1r2)."""
        var r = self.real * o.real
        var a = self.real * o.dual
        var b = self.dual * o.real
        return Self(r, Quat(a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w))

    def conjugate(self) -> Self:
        return Self(self.real.conjugate(), self.dual.conjugate())

    def translation(self) -> Vec3:
        """Recover t = 2 · dual · real*."""
        var t = self.dual * self.real.conjugate()
        return Vec3(t.x * 2, t.y * 2, t.z * 2)

    def transform_point(self, p: Vec3) -> Vec3:
        return self.real.rotate(p) + self.translation()

    # --- motor bridge (the isomorphism) ---
    def to_motor(self) -> Motor3:
        return Motor3.from_quat_translation(self.real, self.translation())

    @staticmethod
    def from_motor(m: Motor3) -> Self:
        """Split M = T·R: rotor part → quat, then T = M·rev(R) → translation."""
        var q = Quat(-m.b23, m.b13, -m.b12, m.s)  # inverse of Motor3.from_quat
        var rot = Motor3.from_quat(q)
        var t = m * rot.reverse()
        return Self.from_quat_translation(
            q, Vec3(t.b10 * 2, t.b20 * 2, t.b30 * 2)
        )
