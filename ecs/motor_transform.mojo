"""Motor-based transform: the third propagation strategy on the transform seam.

`MotorTransform` stores the local pose as a PGA motor (rotation + translation,
8 floats) instead of TRS + matrix; hierarchy propagation is then just motor
composition — `world = parent_world * local` — with no matrix recompose step.
`propagate_motor` mirrors `propagate_full`'s walk exactly, so the parity test
(`tests/test_motor_transform.mojo`) can assert both strategies move points
identically on the same tree.

Motors are rigid motions: no scale. Use the matrix path where scale matters;
this path exists for pure rigid hierarchies (bones, physics bodies), where a
motor is smaller than a Mat4 (8 vs 16 floats) and composes in one geometric
product. Reuses `Parent`/`Hierarchy` unchanged.
"""

from .component import ComponentType
from .world import World
from .storage import StorageBackend
from .hierarchy import Hierarchy
from geometry.motor import Motor3
from geometry.quat import Quat
from geometry.vec import Vec3


@fieldwise_init
struct MotorTransform(ComponentType):
    comptime ID: Int = 0  # same slot convention as Transform (one per world)
    var local: Motor3
    var world: Motor3
    var local_dirty: Bool

    @staticmethod
    def identity() -> Self:
        return Self(Motor3.identity(), Motor3.identity(), True)

    @staticmethod
    def from_quat_translation(q: Quat, t: Vec3) -> Self:
        return Self(Motor3.from_quat_translation(q, t), Motor3.identity(), True)

    def with_local(self, m: Motor3) -> Self:
        var r = self
        r.local = m
        r.local_dirty = True
        return r


def propagate_motor[B: StorageBackend](mut w: World[B], h: Hierarchy):
    """World = parent_world * local, parents-first — pure motor composition."""
    var max_id = len(h.parent_of) - 1
    if max_id < 0:
        return
    var world_cache = List[Motor3]()
    for _ in range(max_id + 1):
        world_cache.append(Motor3.identity())

    for k in range(len(h.order)):
        var e = h.order[k]
        var t = w.get[MotorTransform](e)
        var par = h.parent_of[e.id]
        var wm = t.local
        if par >= 0 and par <= max_id:
            wm = world_cache[par] * t.local
        world_cache[e.id] = wm
        t.world = wm
        t.local_dirty = False
        w.set(e, t)
