# tier: integration
"""17.35 wired through production entry points: `scheduler.timers.TimerQueue`
driven by the tick count `scheduler.gameloop.FixedLoop` (the engine's real
fixed-step driver, also used by `ecs`+`scheduler` production code, not test
scaffolding) reports each frame, and `procedural.tween.Tween[Motor3]`
transporting a point across those same fixed steps.

Part A is the determinism case 17.39 replay / 17.16 rollback actually need:
the SAME timer schedule must fire bit-for-bit identically whether its ticks
arrive from `FixedLoop` stepping through 30 real frames of exactly `dt`, or
from the SAME total tick budget delivered in an irregular integer grouping
(no `FixedLoop`, no floating point at all in the grouping) -- fired timers
are a pure function of ticks elapsed, never of how those ticks were grouped
into `advance()` calls. (An earlier version of this test compared two
DIFFERENT real-valued frame-time splits expected to sum to the same total;
that is NOT a safe determinism check -- `Float32` addition is not
associative, so two splits that sum to the same total in exact math can
disagree by a tick once summed in floating point, which is a fact about
`Float32`, not a bug in `FixedLoop` or `TimerQueue`. Comparing at the
integer-tick level instead is both stronger and actually true.)

Part B drives a `Tween[Motor3, geodesic3, ...]` one fixed tick at a time
through the same `FixedLoop`, transporting a point along the screw path and
checking the transported position lands on the motor endpoints (by action)
and, under a monotonic easing, never moves backward tick to tick."""

from harness.runner import Suite
from ecs.world import World
from ecs.storage import StorageBackend
from ecs.sparse_backend import SparseSetBackend
from ecs.component import ComponentType
from scheduler.scheduler import System
from scheduler.sequential import SequentialScheduler
from scheduler.gameloop import FixedLoop
from scheduler.timers import TimerQueue, TimerHeap, TimerWheel, TimerFire
from procedural.tween import Tween, EASE_LINEAR
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from geometry.motor import Motor3
from geometry.galie import geodesic3


@fieldwise_init
struct Marker(ComponentType):
    comptime ID: Int = 0
    var n: Int


struct NoopSystem(System):
    @staticmethod
    def apply[B: StorageBackend](mut w: World[B]):
        pass


comptime Bk = SparseSetBackend[Marker]
comptime Sched = SequentialScheduler[SparseSetBackend[Marker], NoopSystem]


def _fresh_world() -> World[Bk]:
    var w = World[Bk]()
    var e = w.spawn()
    w.set(e, Marker(0))
    return w^


def _schedule_script[Q: TimerQueue](mut q: Q) raises:
    """The same schedule, used by every run in Part A -- only how ticks are
    grouped into `advance()` calls differs between runs."""
    _ = q.schedule(1, 1)
    _ = q.schedule(5, 2)
    _ = q.schedule(5, 3)
    _ = q.schedule(12, 4, repeat_every=3)


def _via_fixed_loop[Q: TimerQueue](dt: Real, n_frames: Int) raises -> List[TimerFire]:
    """Drive the schedule through `FixedLoop` stepping `n_frames` real frames
    of exactly `dt` each -- the actual production entry point."""
    var w = _fresh_world()
    var sc = Sched()
    var loop = FixedLoop.new(Float64(dt), 64)
    var q = Q()
    _schedule_script[Q](q)
    var fired = List[TimerFire]()
    for _ in range(n_frames):
        var n = loop.advance(sc, w, Float64(dt))
        q.advance(n, fired)
    return fired^


def _via_irregular_ticks[Q: TimerQueue](total_ticks: Int) raises -> List[TimerFire]:
    """Drive the SAME schedule with the same total tick budget, grouped into
    `advance()` calls at the integer level -- no `FixedLoop`, no floating
    point, so this is exactly reproducible and isolates the property under
    test: does the GROUPING of ticks into calls change what fires."""
    var q = Q()
    _schedule_script[Q](q)
    var fired = List[TimerFire]()
    var groups = List[Int]()
    groups.append(2)
    groups.append(1)
    groups.append(4)
    groups.append(3)
    groups.append(7)
    groups.append(1)
    var done = 0
    for gi in range(len(groups)):
        var g = groups[gi]
        if done + g > total_ticks:
            g = total_ticks - done
        if g > 0:
            q.advance(g, fired)
        done += g
    if done < total_ticks:
        q.advance(total_ticks - done, fired)
    return fired^


def _same_fired(a: List[TimerFire], b: List[TimerFire]) -> Bool:
    if len(a) != len(b):
        return False
    for k in range(len(a)):
        if a[k].due_tick != b[k].due_tick or a[k].id != b[k].id:
            return False
    return True


def _part_a(mut s: Suite) raises:
    comptime dt: Real = 1.0 / 60.0
    comptime N_FRAMES = 30

    comptime for i in range(2):
        comptime if i == 0:
            var a = _via_fixed_loop[TimerHeap](dt, N_FRAMES)
            var b = _via_irregular_ticks[TimerHeap](N_FRAMES)
            s.eqi(len(a), len(b), "heap: FixedLoop-grouped vs irregular-grouped count")
            s.check(_same_fired(a, b), "heap: FixedLoop-grouped == irregular-grouped")
        else:
            var a2 = _via_fixed_loop[TimerWheel](dt, N_FRAMES)
            var b2 = _via_irregular_ticks[TimerWheel](N_FRAMES)
            s.eqi(len(a2), len(b2), "wheel: FixedLoop-grouped vs irregular-grouped count")
            s.check(_same_fired(a2, b2), "wheel: FixedLoop-grouped == irregular-grouped")


def _part_b(mut s: Suite) raises:
    comptime dt: Real = 1.0 / 60.0
    var w = _fresh_world()
    var sc = Sched()
    var loop = FixedLoop.new(Float64(dt), 64)

    var qa = Quat.from_axis_angle(Vec3(0, 0, 1, 0), 0.0)
    var qb = Quat.from_axis_angle(Vec3(0, 0, 1, 0), Real(1.5707963))
    var ma = Motor3.from_quat_translation(qa, Vec3(0, 0, 0, 0))
    var mb = Motor3.from_quat_translation(qb, Vec3(10, 0, 0, 0))
    comptime DURATION: Real = 0.5  # seconds
    var tw = Tween[Motor3, type_of(geodesic3), EASE_LINEAR](ma, mb, DURATION, geodesic3)

    var p = Vec3(1, 0, 0, 0)
    var start = ma.apply_point(p)
    var prev_dist: Real = -1.0
    var monotonic = True
    var ticks = 0
    # step one whole fixed tick at a time until the tween completes
    while not tw.done() and ticks < 200:
        var n = loop.advance(sc, w, Float64(dt))
        for _ in range(n):
            _ = tw.advance(dt)
            ticks += 1
            var cur = tw.value().apply_point(p)
            var d = cur[0] - start[0]
            var dist = d if d >= 0 else -d
            if dist + 1e-4 < prev_dist:
                monotonic = False
            prev_dist = dist
    s.check(monotonic, "linear motor tween: transported point never regresses")
    s.check(tw.done(), "motor tween completes within the tick budget")

    var end_pt = tw.value().apply_point(p)
    var direct_end = mb.apply_point(p)
    s.almost(Float64(end_pt[0]), Float64(direct_end[0]), "transported end x", 1e-2)
    s.almost(Float64(end_pt[1]), Float64(direct_end[1]), "transported end y", 1e-2)
    s.almost(Float64(end_pt[2]), Float64(direct_end[2]), "transported end z", 1e-2)


def main() raises:
    var s = Suite("timers_integration")
    _part_a(s)
    _part_b(s)
    s.finish()
