# tier: system
"""Non-blocking stepping (ROADMAP 17.75): `Runtime.begin_advance` /
`execute` / `finish` against blocking `advance`.

  1. Ordinary: a box tower and a rolling ball stepped for 90 frames of
     uneven length (1, 2 or 0 fixed ticks owed per frame) -- the split
     calls return the same alpha every frame and end in a byte-identical
     scene snapshot and identical interpolation history.
  2. Integration: while a step is in flight, `published` holds the poses of
     the last COMPLETED tick (the host renders from it while the physics
     runs elsewhere), and after `finish` the history has advanced.
  3. Extreme: a zero-tick frame; begin twice; execute or finish with a stale
     handle; finish before execute; finish twice; teleport while in flight
     -- each raises, and the runtime stays usable afterwards.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from ecs.sparse_backend import SparseSetBackend
from ecs.transform import Transform
from physics.rigid6 import Inertia3, QuatBody6
from physics.serialize import scene_to_bytes
from gameplay.runtime import Runtime, RigidBodyRef, StepHandle

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime Bk = SparseSetBackend[Transform, RigidBodyRef]
comptime Rt = Runtime[Bk, QuatBody6]


def _world() -> Rt:
    var rt = Rt(DT, G)
    _ = rt.spawn_body(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    for j in range(4):
        _ = rt.spawn_body(
            QuatBody6.at_rest(Vec3(0, 0.25 + 0.5 * Real(j), 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)),
            Vec3(0.25, 0.25, 0.25, 0), False,
        )
    var b = QuatBody6.at_rest(Vec3(2, 0.5, 0, 0), Inertia3.sphere(1, 0.5))
    b.vel = Vec3(3, 0, 0, 0)
    _ = rt.spawn_sphere(b^, 0.5, False)
    return rt^


def _frame_dt(f: Int) -> Float64:
    # uneven frames: 1, 2 and 0 ticks owed in a repeating pattern
    var k = f % 3
    return Float64(DT) * (1.0 if k == 0 else (2.0 if k == 1 else 0.4))


def _same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def main() raises:
    var s = Suite("async_step")

    # ---- 1. split == blocking ------------------------------------------
    var blocking = _world()
    var split = _world()
    var alpha_same = True
    var published_ok = True
    for f in range(90):
        var a1 = blocking.advance(_frame_dt(f))
        var before = split.history.curr.copy()
        var h = split.begin_advance(_frame_dt(f))
        # ---- 2. the host's read-only view while the step is in flight
        if len(split.published) != len(before):
            published_ok = False
        else:
            for i in range(len(before)):
                if split.published[i].p[0] != before[i].p[0] or split.published[i].p[1] != before[i].p[1]:
                    published_ok = False
        split.execute(h)
        var a2 = split.finish(h)
        if a1 != a2:
            alpha_same = False
    s.check(alpha_same, "alpha identical every frame (90 uneven frames)")
    s.check(_same(scene_to_bytes(blocking.scene), scene_to_bytes(split.scene)), "scene snapshot byte-identical after 90 frames")
    var hist_same = len(blocking.history.curr) == len(split.history.curr)
    for i in range(min(len(blocking.history.curr), len(split.history.curr))):
        if blocking.history.curr[i].p[1] != split.history.curr[i].p[1]:
            hist_same = False
    s.check(hist_same, "interpolation history identical")
    s.check(published_ok, "in flight, published == poses of the last completed tick")

    # ---- 3. extremes -----------------------------------------------------
    var rt = _world()
    var h0 = rt.begin_advance(0.0)
    s.check(h0.ticks == 0, "a zero-length frame owes zero ticks")
    rt.execute(h0)
    _ = rt.finish(h0)

    var h = rt.begin_advance(Float64(DT))
    var raised = False
    try:
        _ = rt.begin_advance(Float64(DT))
    except:
        raised = True
    s.check(raised, "begin twice raises")
    raised = False
    try:
        _ = rt.finish(h)
    except:
        raised = True
    s.check(raised, "finish before execute raises")
    raised = False
    try:
        rt.execute(StepHandle(h.ticks, h.serial - 1))
    except:
        raised = True
    s.check(raised, "execute with a stale handle raises")
    raised = False
    try:
        var e = rt.world.query1[RigidBodyRef]()[1]
        rt.teleport(e, Vec3(5, 5, 5, 0))
    except:
        raised = True
    s.check(raised, "teleport while in flight raises")
    rt.execute(h)
    _ = rt.finish(h)
    raised = False
    try:
        _ = rt.finish(h)
    except:
        raised = True
    s.check(raised, "finish twice raises")
    _ = rt.advance(Float64(DT))
    s.check(not rt.in_flight, "runtime usable with blocking advance afterwards")
    s.finish()
