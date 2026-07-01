"""Transform components + a parent link, built on the linear-algebra module.

`Transform` (3D) / `Transform2` (2D) are ordinary `ComponentType`s holding a
local TRS plus a *cached world matrix* and dirty flags. The split mirrors the
engine's existing dimension convention (`Body2`, `OBB` are 2D-only) because the
rotation representation differs — a `Quat` in 3D, a scalar angle in 2D — so a
single `[dim]`-parametric type would not share a field layout.

`Parent` stores the parent entity *id* (not an `Entity`) so it stays trivial
copy-in/out data under the storage contract (`get` returns a copy; the archetype
backend relocates rows). The parent→children adjacency is *derived* each pass by
`Hierarchy.build`, never stored as a growable list inside a component.

IDs: `Transform`/`Transform2` = 0, `Parent` = 1 — dense from 0 for a world whose
component set is exactly {transform, parent}.
"""

from .component import ComponentType
from geometry.vec import Vec2, Vec3, Real
from geometry.quat import Quat, compose_trs4
from geometry.mat import Mat3, Mat4, compose_trs3


@fieldwise_init
struct Transform(ComponentType):
    comptime ID: Int = 0
    var translation: Vec3
    var rotation: Quat
    var scale: Vec3
    var local_dirty: Bool  # local TRS changed since the world matrix was built
    var world: Mat4  # cached world matrix (valid when not world_dirty)
    var world_dirty: Bool  # self or an ancestor moved; world needs recompute

    @staticmethod
    def at(t: Vec3) -> Self:
        """Translation-only transform: identity rotation, unit scale, dirty."""
        return Self(t, Quat.identity(), Vec3(1, 1, 1), True, Mat4.identity(), True)

    def local_matrix(self) -> Mat4:
        return compose_trs4(self.translation, self.rotation, self.scale)

    def with_translation(self, t: Vec3) -> Self:
        var r = self
        r.translation = t
        r.local_dirty = True
        return r

    def with_rotation(self, q: Quat) -> Self:
        var r = self
        r.rotation = q
        r.local_dirty = True
        return r

    def with_scale(self, s: Vec3) -> Self:
        var r = self
        r.scale = s
        r.local_dirty = True
        return r


@fieldwise_init
struct Transform2(ComponentType):
    comptime ID: Int = 0
    var translation: Vec2
    var angle: Real
    var scale: Vec2
    var local_dirty: Bool
    var world: Mat3
    var world_dirty: Bool

    @staticmethod
    def at(t: Vec2) -> Self:
        return Self(t, Real(0), Vec2(1, 1), True, Mat3.identity(), True)

    def local_matrix(self) -> Mat3:
        return compose_trs3(self.translation, self.angle, self.scale)

    def with_translation(self, t: Vec2) -> Self:
        var r = self
        r.translation = t
        r.local_dirty = True
        return r


@fieldwise_init
struct Parent(ComponentType):
    comptime ID: Int = 1
    var entity: Int  # parent entity id; -1 (or absent component) means root
