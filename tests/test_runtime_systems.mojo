# tier: system
"""User systems in `Runtime` (ROADMAP 17.77, `Runtime.advance_with`).

  1. Ordinary: a `JobGraphScheduler` of two systems ticks once per fixed
     tick, after the physics step: `Track` copies each body's synced
     Transform y into `Height` (equal to the scene's body y after every
     frame), and `Count` bumps a `Ticks` resource (equal to the number of
     fixed ticks run, including frames that owe 0 or 3 ticks).
  2. Integration: `Lowest` reads `Height` that `Track` writes, so the
     scheduler puts it one level later; it keeps the lowest y seen in a
     resource, which equals the analytic free-fall minimum after 30 ticks.
     A parallel scheduler gives the same world bit for bit; `advance_with`
     moves the bodies exactly as `advance` does.
  3. Extreme: `advance_with` while a `begin_advance` step is in flight
     raises.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from ecs.world import World
from ecs.storage import StorageBackend
from ecs.sparse_backend import SparseSetBackend
from ecs.component import ComponentType
from ecs.transform import Transform
from physics.rigid6 import Inertia3, QuatBody6
from gameplay.runtime import Runtime, RigidBodyRef
from scheduler.jobgraph import JobGraphScheduler, DeclaredSystem

comptime DT: Real = 1.0 / 60.0


@fieldwise_init
struct Height(ComponentType):
    comptime ID: Int = 3
    var y: Real


@fieldwise_init
struct Ticks(ComponentType):
    comptime ID: Int = 4
    var n: Int


@fieldwise_init
struct Lowest(ComponentType):
    comptime ID: Int = 5
    var y: Real


comptime Bk = SparseSetBackend[Transform, RigidBodyRef, Height, Ticks, Lowest]
comptime Rt = Runtime[Bk, QuatBody6]


struct Track(DeclaredSystem):
    @staticmethod
    def apply[B: StorageBackend](mut world: World[B]):
        var es = world.query2[Transform, Height]()
        for e in es:
            world.set(e, Height(world.get[Transform](e).translation[1]))

    @staticmethod
    def reads() -> UInt64:
        return UInt64(1) << UInt64(Transform.ID)

    @staticmethod
    def writes() -> UInt64:
        return UInt64(1) << UInt64(Height.ID)


struct Count(DeclaredSystem):
    @staticmethod
    def apply[B: StorageBackend](mut world: World[B]):
        try:
            world.set_resource(Ticks(world.resource[Ticks]().n + 1))
        except:
            pass  # no Ticks resource: nothing to count

    @staticmethod
    def reads() -> UInt64:
        return UInt64(1) << UInt64(Ticks.ID)

    @staticmethod
    def writes() -> UInt64:
        return UInt64(1) << UInt64(Ticks.ID)


struct LowestSys(DeclaredSystem):
    @staticmethod
    def apply[B: StorageBackend](mut world: World[B]):
        var lo = Real(1e9)
        try:
            lo = world.resource[Lowest]().y
        except:
            pass  # first tick without the resource: start from +inf
        var es = world.query1[Height]()
        for e in es:
            lo = min(lo, world.get[Height](e).y)
        world.set_resource(Lowest(lo))

    @staticmethod
    def reads() -> UInt64:
        return (UInt64(1) << UInt64(Height.ID)) | (UInt64(1) << UInt64(Lowest.ID))

    @staticmethod
    def writes() -> UInt64:
        return UInt64(1) << UInt64(Lowest.ID)


comptime Sched = JobGraphScheduler[Bk, Track, Count, LowestSys]


def _setup(mut rt: Rt) raises:
    for k in range(3):
        var e = rt.spawn_sphere(QuatBody6.at_rest(Vec3(Real(k) * 3, 10 + Real(k), 0, 0), Inertia3.sphere(1, 0.5)), 0.5, False)
        rt.world.set(e, Height(0))
    rt.world.set_resource(Ticks(0))
    rt.world.set_resource(Lowest(1e9))


def main() raises:
    var s = Suite("runtime_systems")
    var rt = Rt(DT, Vec3(0, -9.8, 0, 0))
    _setup(rt)
    var sched = Sched()
    print("  levels: Track", sched.level[0], " Count", sched.level[1], " Lowest", sched.level[2])
    s.check(sched.level[2] > sched.level[0], "Lowest reads what Track writes: a later level")
    var frames: List[Float64] = [Float64(DT), Float64(DT) * 0.5, Float64(DT) * 0.5, Float64(DT) * 3, Float64(DT) * 0.2]
    var ticks = 0
    var synced = True
    for f in range(30):
        var before = rt.loop.accumulator
        _ = rt.advance_with(frames[f % 5], sched)
        ticks += Int((before + frames[f % 5] + 1e-12) / Float64(DT))
        var es = rt.world.query2[Height, RigidBodyRef]()
        for e in es:
            if rt.world.get[Height](e).y != rt.scene.bset.bodies[rt.body_of(e).index()].pos[1]:
                synced = False
    var n = rt.world.resource[Ticks]().n
    print("  30 frames of 0.2-3 ticks: fixed ticks run", n, "(counted", ticks, ")")
    s.check(n == ticks and n > 30, "the systems tick once per fixed tick")
    s.check(synced, "Height equals the scene's body y after every frame (systems run after the step and the sync)")

    # the lowest body started at 10 and fell for n ticks (semi-implicit
    # Euler in the step's 4 substeps)
    var v = Real(0)
    var y = Real(10)
    var hs = DT / 4
    for _ in range(4 * n):
        v -= 9.8 * hs
        y += v * hs
    var lo = rt.world.resource[Lowest]().y
    print("  lowest y seen", lo, " semi-implicit Euler", y)
    s.check(abs(lo - y) < 1e-4, "the Lowest resource tracks the free-fall minimum")

    var rp = Rt(DT, Vec3(0, -9.8, 0, 0))
    _setup(rp)
    var sp = Sched()
    sp.parallel = True
    var ra = Rt(DT, Vec3(0, -9.8, 0, 0))
    _setup(ra)
    for f in range(30):
        _ = rp.advance_with(frames[f % 5], sp)
        _ = ra.advance(frames[f % 5])
    var same = rp.world.resource[Lowest]().y == lo and rp.world.resource[Ticks]().n == n
    var same_bodies = True
    for b in range(len(rt.scene.bset.bodies)):
        if rp.scene.bset.bodies[b].pos[1] != rt.scene.bset.bodies[b].pos[1] or ra.scene.bset.bodies[b].pos[1] != rt.scene.bset.bodies[b].pos[1]:
            same_bodies = False
    s.check(same and same_bodies, "parallel scheduler: same resources; advance_with moves bodies as advance does")

    var h = rt.begin_advance(Float64(DT))
    var raised = False
    try:
        _ = rt.advance_with(Float64(DT), sched)
    except:
        raised = True
    rt.execute(h)
    _ = rt.finish(h)
    s.check(raised, "advance_with during an in-flight step raises")
    s.finish()
