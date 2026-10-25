# tier: system
"""Runtime operations boundary (ROADMAP 17.73): outbox drained at frame
end, host config applied at frame start.

A floor and 4 falling boxes; 60 Hz frames; gameplay code writes one outbox
record per frame, the host may change config key 1 (gravity in percent).

  1. Outbox: 100 frames, one record each, the host takes after every
     frame: 100 records in tick order. A host that does not take for 20
     frames with an 8-record runtime: 8 kept, 12 counted in
     `OUTBOX_DROPPED`.
  2. Config at frame boundaries: the host sets gravity 50 % before frame
     30, and 100 % while frame 60 is in flight (`begin_advance` ..
     `finish`): the frame-60 step still runs at 50 %, frame 61 at 100 %;
     the log stamps the entries with ticks 30 and 61.
  3. Replay: a runtime whose inbox is `scripted(log)` (host posts are
     ignored) ends bit-identical to the live run; the same posts applied
     one frame later end elsewhere (timing is part of the data).
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from ecs.sparse_backend import SparseSetBackend
from ecs.transform import Transform
from physics.rigid6 import Inertia3, QuatBody6
from physics.serialize import scene_to_bytes
from diag.counters import OUTBOX_DROPPED
from gameplay.runtime import Runtime, RigidBodyRef
from gameplay.host_inbox import ConfigInbox, ConfigEntry

comptime DT: Real = 1.0 / 60.0
comptime Bk = SparseSetBackend[Transform, RigidBodyRef]
comptime Rt = Runtime[Bk, QuatBody6]
comptime GRAVITY = 1


def world(cap: Int = 4096) raises -> Rt:
    var rt = Rt(DT, Vec3(0, -9.8, 0, 0), 8, cap)
    _ = rt.spawn_body(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    for k in range(4):
        _ = rt.spawn_body(QuatBody6.at_rest(Vec3(Real(k) - 1.5, 3 + Real(k), 0, 0), Inertia3.box(1, 0.3, 0.3, 0.3)), Vec3(0.3, 0.3, 0.3, 0), False)
    return rt^


def apply_gravity(mut rt: Rt):
    var pct = rt.config.get(GRAVITY, 100)
    rt.gravity = Vec3(0, Real(-9.8) * Real(pct) / 100, 0, 0)


def frame(mut rt: Rt, post_mid: Int = -1) raises:
    """One frame: the runtime takes host config in `begin_advance`, the
    game applies it, the ticks run. `post_mid >= 0` posts that gravity
    while the step is in flight."""
    var h = rt.begin_advance(Float64(DT))
    apply_gravity(rt)
    if post_mid >= 0:
        rt.inbox.post(GRAVITY, post_mid)
    rt.execute(h)
    _ = rt.finish(h)


def same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for k in range(len(a)):
        if a[k] != b[k]:
            return False
    return True


def live_run(late: Int) raises -> Tuple[List[UInt8], List[ConfigEntry], Real, Real]:
    """120 frames; 50 % posted before frame 30 + late, 100 % during frame 60 + late."""
    var rt = world()
    var g60 = Real(0)
    var g61 = Real(0)
    for f in range(120):
        if f == 30 + late:
            rt.inbox.post(GRAVITY, 50)
        frame(rt, 100 if f == 60 + late else -1)
        if f == 60 + late:
            g60 = rt.gravity[1]
        if f == 61 + late:
            g61 = rt.gravity[1]
    return (scene_to_bytes(rt.scene), rt.inbox.log.copy(), g60, g61)


def main() raises:
    var s = Suite("runtime_ops")

    # ---- outbox -----------------------------------------------------------------------------------
    var rt = world()
    var got = 0
    var ordered = True
    var last = -1
    for f in range(100):
        _ = rt.outbox.push(1, rt.scene.step_index, 0, f)
        frame(rt)
        for r in rt.take_ops():
            got += 1
            ordered = ordered and r.tick > last and r.a == f
            last = r.tick
    var slow = world(8)
    for f in range(20):
        _ = slow.outbox.push(1, slow.scene.step_index, 0, f)
        frame(slow)
    var kept = len(slow.take_ops())
    var dropped = Int(slow.loop.counters.get(OUTBOX_DROPPED))
    print("outbox: delivered", got, " slow host kept", kept, "dropped", dropped)
    s.check(got == 100 and ordered, "one record per frame, delivered after the frame in tick order")
    s.check(kept == 8 and dropped == 12, "host that does not take: capacity kept, the rest counted")

    # ---- config at frame boundaries ----------------------------------------------------------------
    var live = live_run(0)
    var log = live[1].copy()
    print("config: log", len(log), "entries at ticks", log[0].tick, log[1].tick, " gravity in frame 60", live[2], " frame 61", live[3])
    s.check(len(log) == 2 and log[0].tick == 30 and log[0].value == 50 and log[1].tick == 61 and log[1].value == 100, "entries stamped with the first tick of the frame after they arrived")
    s.check(live[2] == Real(-4.9) and live[3] == Real(-9.8), "posted mid-flight: frame 60 keeps 50 %, frame 61 uses 100 %")

    # ---- replay ----------------------------------------------------------------------------------
    var re = world()
    re.inbox = ConfigInbox.scripted(log)
    for _ in range(120):
        re.inbox.post(GRAVITY, 5)  # ignored while scripted
        frame(re)
    var shifted = live_run(1)
    var same_replay = same(live[0], scene_to_bytes(re.scene))
    var differs = not same(live[0], shifted[0])
    print("replay: scripted run equals live", same_replay, " posts one frame later differ", differs)
    s.check(same_replay, "scripted inbox replays the live run bit for bit")
    s.check(differs, "the same data one frame later is a different run")
    s.finish()
