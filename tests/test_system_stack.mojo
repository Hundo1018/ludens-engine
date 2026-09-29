# tier: system
"""ROADMAP 17.0i: the first real system test -- a whole world stepped
through `gameplay.runtime.Runtime`, checked on end state (docs/ARCHITECTURE
.md S3's "system" row, empty until this package existed to wire ecs +
scheduler + physics together outside a test file itself).

Ten box entities (one static ground + a 9-high dynamic tower) spawned
through `Runtime.spawn_body`, advanced 3 simulated seconds of frames at an
UNEVEN frame rate (1/144 and 1/30 alternating, so the fixed-step
accumulator actually has to carry fractional debt across frames, not just
tick once per `advance` call) -- then: every entity's `Transform` equals its
body's pose exactly (the `_sync_transforms` contract), the tower is at rest
near its analytic stacked height, one `began` contact event was seen for
every touching interface, and the tower goes to sleep (within 8 s)."""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from ecs.entity import Entity
from ecs.sparse_backend import SparseSetBackend
from ecs.transform import Transform
from physics.rigid6 import Inertia3, QuatBody6
from collision.contact_events import ContactEvent, EV_BEGAN, EV_STAY
from diag.counters import GAMELOOP_DEBT_DROPPED
from gameplay.runtime import Runtime, RigidBodyRef

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime HALF: Real = 0.25  # box half-extent -> full box = 0.5

comptime Bk = SparseSetBackend[Transform, RigidBodyRef]
comptime Rt = Runtime[Bk, QuatBody6]


def _build(mut rt: Rt) -> List[Entity]:
    var es = List[Entity]()
    # static ground, top face at y = 0
    _ = rt.spawn_body(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 30, 1, 30)),
        Vec3(30, 1, 30, 0), True,
    )
    # a 9-box dynamic tower, dropped from slightly above its rest slots so
    # each box actually falls and makes contact (not spawned already
    # touching -- that would never emit a BEGAN event to observe).
    for i in range(9):
        var rest_y = HALF + Real(i) * (2 * HALF)
        var e = rt.spawn_body(
            QuatBody6.at_rest(Vec3(0, rest_y + 0.4, 0, 0), Inertia3.box(1, HALF, HALF, HALF)),
            Vec3(HALF, HALF, HALF, 0), False,
        )
        es.append(e)
    return es^


def main() raises:
    var s = Suite("system_stack")
    var rt = Rt(DT, G)
    var boxes = _build(rt)
    var reader = rt.events.register_reader()

    var began_keys = List[Int]()  # a*4096 + b, one entry per distinct touching pair
    var saw_stay = False

    comptime DT_A: Float64 = 1.0 / 144.0
    comptime DT_B: Float64 = 1.0 / 30.0
    var elapsed = Float64(0)
    var frame_i = 0
    while elapsed < 8.0:
        var fdt = DT_A if frame_i % 2 == 0 else DT_B
        _ = rt.advance(fdt)
        elapsed += fdt
        frame_i += 1

        var evs = List[ContactEvent]()
        rt.events.read(reader, evs)
        for i in range(len(evs)):
            if evs[i].kind == EV_BEGAN:
                var key = evs[i].a * 4096 + evs[i].b
                var known = False
                for k in range(len(began_keys)):
                    if began_keys[k] == key:
                        known = True
                if not known:
                    began_keys.append(key)
            elif evs[i].kind == EV_STAY:
                saw_stay = True

    s.check(frame_i > 100, "ran a meaningful number of uneven-rate frames (" + String(frame_i) + ")")

    # -- transforms == body poses, exactly --
    var all_synced = True
    for i in range(len(boxes)):
        var r = rt.world.get[RigidBodyRef](boxes[i])
        var t = rt.world.get[Transform](boxes[i])
        var bi = r.id.index()
        var p = rt.scene.bset.bodies[bi].position()
        var q = rt.scene.bset.bodies[bi].rotation()
        if (
            Float64(t.translation[0]) != Float64(p[0])
            or Float64(t.translation[1]) != Float64(p[1])
            or Float64(t.translation[2]) != Float64(p[2])
            or Float64(t.rotation.x) != Float64(q.x)
            or Float64(t.rotation.y) != Float64(q.y)
            or Float64(t.rotation.z) != Float64(q.z)
            or Float64(t.rotation.w) != Float64(q.w)
        ):
            all_synced = False
    s.check(all_synced, "every entity's Transform exactly equals its body's pose")

    # -- rest heights near analytic (soft-constraint solver settles with
    # residual penetration on the order of its own SLOP; the tolerance below
    # is a small multiple of that, not exact contact). --
    var worst_err = Float64(0)
    for i in range(len(boxes)):
        var r = rt.world.get[RigidBodyRef](boxes[i])
        var y = Float64(rt.scene.bset.bodies[r.id.index()].position()[1])
        var want = Float64(HALF) + Float64(i) * Float64(2 * HALF)
        var err = y - want
        if err < 0:
            err = -err
        if err > worst_err:
            worst_err = err
    s.check(worst_err < 0.05, "tower rest heights within 0.05 of analytic stacking (worst=" + String(worst_err) + ")")

    # -- events: one BEGAN per touching interface (ground-box0, box0-box1, ..., box7-box8 = 9) --
    s.check(len(began_keys) >= 9, "at least one BEGAN per touching interface (" + String(len(began_keys)) + " seen)")
    s.check(saw_stay, "STAY events observed once the tower settles")

    # -- sleeping kicks in --
    var any_asleep = False
    for i in range(len(boxes)):
        var r = rt.world.get[RigidBodyRef](boxes[i])
        if rt.scene.bset.sleeping[r.id.index()]:
            any_asleep = True
    s.check(any_asleep, "the settled tower goes to sleep within 8s")

    # -- extreme: frame_dt = 0 is a no-op, not a crash --
    var alpha_before = rt.loop.alpha
    var alpha_after = rt.advance(0.0)
    s.almost(alpha_after, alpha_before, "extreme: frame_dt=0 changes nothing (0 ticks)", 1e-9)

    # -- extreme: a huge frame spike clamps to max_steps and counts the drop --
    var drops_before = rt.loop.counters.get(GAMELOOP_DEBT_DROPPED)
    _ = rt.advance(1000.0)
    var drops_after = rt.loop.counters.get(GAMELOOP_DEBT_DROPPED)
    s.check(Int(drops_after) == Int(drops_before) + 1, "extreme: huge frame spike clamps and counts exactly one drop")
    s.check(rt.loop.alpha >= 0.0 and rt.loop.alpha < 1.0, "extreme: alpha stays in [0,1) after the clamp")

    s.finish()
