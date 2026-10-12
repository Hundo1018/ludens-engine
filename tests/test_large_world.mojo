# tier: integration
"""Large worlds: origin rebasing and world partition (ROADMAP 17.8).

1. Far out: a 3-box stack built 1e6 m from the origin with `RebasedF32`
   (the host's f64 world coordinates become small local ones) is
   bit-identical to the same stack built at the origin. What f32 loses
   there without rebasing: positions are quantised to 1/16 m, so a body
   moving 0.5 m/s along the far axis (8 mm per tick) does not move at all.
2. Rebase mid-run: shifting a resting stack's origin keeps every contact and
   adds no kick (warm start survives), and the run matches an unshifted one.
3. Save after a rebase, continue vs reload and continue: same bits
   (origin and log are in the blob).
4. Extremes: a stack at 1e7 m; a rebase in the same tick a fast sphere
   would tunnel through a wall (CCD still stops it); shift validation.
5. Strategy parity in a small world: `RebasedF32` that never triggers ==
   `AbsoluteF32` bit-for-bit.
6. Partition: cells stream in and out around a walking observer, with
   hysteresis (pacing at a border causes no events); a body moved across a
   border changes owner and survives its old cell unloading; unload + reload
   restores its pose and velocity exactly; an observer teleported 1e4 m
   unloads everything behind it; two identical walks give identical event
   logs.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from gameplay.large_world import (
    WorldPos,
    AbsoluteF32,
    RebasedF32,
    Rebaser,
    WorldPartition,
    BodySpec,
    SPEC_BOX,
    EV_LOAD,
    EV_UNLOAD,
    save_large_world,
    load_large_world,
)

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def cfg() -> SolverConfig:
    var c = SolverConfig()
    c.broadphase = True
    return c^


def add_stack[S: Copyable](mut sc: ContactScene6[QuatBody6], base: Vec3) raises:
    _ = sc.add(QuatBody6.at_rest(base + _v(0, -0.5, 0), Inertia3.box(1, 5, 0.5, 5)), _v(5, 0.5, 5), True)
    for k in range(3):
        _ = sc.add(QuatBody6.at_rest(base + _v(0, 0.25 + 0.51 * Real(k), 0), Inertia3.box(1, 0.25, 0.25, 0.25)), _v(0.25, 0.25, 0.25), False)


def stack_local(mut sc: ContactScene6[QuatBody6], base: Vec3) raises:
    add_stack[Int](sc, base)


def top_speed(sc: ContactScene6[QuatBody6]) -> Float64:
    var v = sc.bset.bodies[3].linear_velocity()
    return Float64(sqrt3(v))


def sqrt3(v: Vec3) -> Real:
    return (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) ** 0.5


def same_bits(a: ContactScene6[QuatBody6], b: ContactScene6[QuatBody6]) -> Bool:
    if len(a.bset.bodies) != len(b.bset.bodies):
        return False
    for i in range(len(a.bset.bodies)):
        var pa = a.bset.bodies[i].position()
        var pb = b.bset.bodies[i].position()
        var va = a.bset.bodies[i].linear_velocity()
        var vb = b.bset.bodies[i].linear_velocity()
        for c in range(3):
            if pa[c].to_bits() != pb[c].to_bits() or va[c].to_bits() != vb[c].to_bits():
                return False
    return True


def settle_stats(mut sc: ContactScene6[QuatBody6], ticks: Int) raises -> Tuple[Float64, Float64]:
    """(max top-box speed over the last 60 ticks, top-box drift from its start)."""
    var c = cfg()
    var p0 = sc.bset.bodies[3].position()
    var worst = Float64(0)
    for t in range(ticks):
        sc.step(DT, G, c)
        if t >= ticks - 60:
            worst = max(worst, top_speed(sc))
    var p1 = sc.bset.bodies[3].position()
    return (worst, Float64(sqrt3(p1 - p0)))


def main() raises:
    var s = Suite("large_world")

    # 1. jitter at 1e6 m
    var D = Float64(1.0e6)
    var at_origin = ContactScene6[QuatBody6]()
    stack_local(at_origin, _v(0, 0, 0))
    var r0 = settle_stats(at_origin, 240)
    var absolute = ContactScene6[QuatBody6]()
    stack_local(absolute, _v(Real(D), 0, 0))
    var ra = settle_stats(absolute, 240)
    var rb = Rebaser(RebasedF32(1024, 64))
    var rebased = ContactScene6[QuatBody6]()
    _ = rb.update(rebased, rb.local(WorldPos(D, 0, 0)), 0)  # origin follows the observer first
    stack_local(rebased, rb.local(WorldPos(D, 0, 0)))
    var rr = settle_stats(rebased, 240)
    print("  stack 1e6 m out: absolute f32 rest speed", ra[0], "settle", ra[1], "| rebased", rr[0], rr[1], "| at origin", r0[0], r0[1])
    s.check(rb.origin.x == D, "origin moved to the observer (1e6 is on the 64 m grid)")
    s.check(same_bits(rebased, at_origin), "rebased stack at 1e6 m is bit-identical to the stack at the origin")
    # what f32 loses far out: a slow body moving along the far axis.
    # 0.5 m/s * 1/60 s = 8.3 mm per tick, under half an ulp (31 mm) at 1e6:
    # the absolute body cannot move at all; the rebased one moves 0.5 m.
    var slow_abs = slow_mover_error(_v(Real(D), 0, 0))
    var rbm = Rebaser(RebasedF32(1024, 64))
    var tmp = ContactScene6[QuatBody6]()
    _ = rbm.update(tmp, rbm.local(WorldPos(D, 0, 0)), 0)
    var slow_reb = slow_mover_error(rbm.local(WorldPos(D, 0, 0)))
    print("  0.5 m/s body for 1 s at 1e6 m: |travel - 0.5| absolute", slow_abs, " rebased", slow_reb)
    s.check(slow_abs > 0.4, "absolute f32 at 1e6 m: a 0.5 m/s body does not move (the failure rebasing removes)")
    s.check(slow_reb < 1e-5, "rebased: it travels 0.5 m (error < 10 um)")

    # 2. rebase a resting stack mid-run
    var plain = ContactScene6[QuatBody6]()
    stack_local(plain, _v(0, 0, 0))
    var moved = ContactScene6[QuatBody6]()
    stack_local(moved, _v(0, 0, 0))
    var c = cfg()
    for _ in range(120):
        plain.step(DT, G, c)
        moved.step(DT, G, c)
    var contacts_before = len(moved.cache)
    var rb2 = Rebaser(AbsoluteF32())
    var d = _v(64, 0, -128)
    rb2.shift(moved, d, 120)
    s.eqi(len(moved.cache), contacts_before, "warm-start cache keeps every contact across the shift")
    var kick = Float64(0)
    for _ in range(60):
        plain.step(DT, G, c)
        moved.step(DT, G, c)
        kick = max(kick, top_speed(moved))
    var dev = Float64(0)
    for i in range(4):
        dev = max(dev, Float64(sqrt3(moved.bset.bodies[i].position() + d - plain.bset.bodies[i].position())))
    print("  rebase at tick 120: max top speed after", kick, " max |moved + d - plain|", dev)
    s.check(kick < 1e-2, "no impulse kick at the rebase tick (resting stack stays resting)")
    s.check(dev < 1e-4, "rebased run matches the unshifted run within 0.1 mm after 60 ticks")

    # 3. save after a rebase: continue vs reload + continue
    var blob = save_large_world(moved, rb2)
    for _ in range(60):
        moved.step(DT, G, c)
    var rb3 = Rebaser(AbsoluteF32())
    var back = load_large_world(blob, rb3)
    for _ in range(60):
        back.step(DT, G, c)
    s.check(same_bits(back, moved), "save after rebase, reload, continue == uninterrupted run (bits)")
    s.check(rb3.origin.x == 64 and rb3.origin.z == -128 and len(rb3.log) == 1 and rb3.log[0].tick == 120, "origin and rebase log restored")

    # 4a. 1e7 m
    var far = Rebaser(RebasedF32(1024, 64))
    var sfar = ContactScene6[QuatBody6]()
    _ = far.update(sfar, far.local(WorldPos(1.0e7, 0, -1.0e7)), 0)
    stack_local(sfar, far.local(WorldPos(1.0e7, 0, -1.0e7)))
    var rf = settle_stats(sfar, 240)
    s.check(same_bits(sfar, at_origin), "stack at (1e7, 0, -1e7) m: bit-identical to the origin stack")
    # 4b. rebase on the tick a fast sphere would tunnel
    var ccd_cfg = cfg()
    ccd_cfg.ccd = True
    var shot = ContactScene6[QuatBody6]()
    _ = shot.add(QuatBody6.at_rest(_v(2, 1, 0), Inertia3.box(1, 0.05, 1, 1)), _v(0.05, 1, 1), True)
    var ball = shot.add_sphere(QuatBody6.at_rest(_v(0, 1, 0), Inertia3.sphere(1, 0.1)), 0.1, False)
    shot.set_velocity(ball, _v(150, 0, 0), _v(0, 0, 0))
    var rb4 = Rebaser(RebasedF32(1, 64))
    _ = rb4.update(shot, _v(100, 0, 0), 0)  # shift by (128, 0, 0) right before the step
    for _ in range(3):
        shot.step(DT, Vec3(0, 0, 0, 0), ccd_cfg)
    var bx = Float64(shot.bset.bodies[ball.index()].position()[0]) + rb4.origin.x
    print("  CCD across a rebase: sphere world x", bx, " (wall face at 1.95)")
    s.check(bx < 1.96, "rebase on the tunnelling tick: CCD still stops the sphere at the wall")
    var bad = False
    try:
        shot.shift_origin(Vec3(Real(Float64(1) / Float64(0)), 0, 0, 0))
    except:
        bad = True
    s.check(bad, "non-finite shift refused")

    # 5. strategy parity, small world
    var sa = ContactScene6[QuatBody6]()
    stack_local(sa, _v(3, 0, -2))
    var sb = ContactScene6[QuatBody6]()
    var rb5 = Rebaser(RebasedF32(1024, 64))
    _ = rb5.update(sb, _v(3, 0, -2), 0)
    stack_local(sb, rb5.local(WorldPos(3, 0, -2)))
    for _ in range(120):
        sa.step(DT, G, c)
        sb.step(DT, G, c)
    s.check(len(rb5.log) == 0 and same_bits(sa, sb), "small world: RebasedF32 (never triggered) == AbsoluteF32 bit-for-bit")

    # 6. partition
    var walk1 = walk()
    var walk2 = walk()
    s.check(walk1 == walk2, "two identical walks: identical cell event logs")
    var wp = WorldPartition(32, 40, 70)
    var scene = ContactScene6[QuatBody6]()
    var origin = WorldPos(0, 0, 0)
    for i in range(12):
        _ = wp.add(BodySpec(SPEC_BOX, _v(4, 0.5, 4), 0, True, WorldPos(Float64(i) * 32 + 16, -0.5, 16), Quat.identity(), _v(0, 0, 0), _v(0, 0, 0)))
        _ = wp.add(BodySpec(SPEC_BOX, _v(0.25, 0.25, 0.25), 1, False, WorldPos(Float64(i) * 32 + 16, 0.25, 16), Quat.identity(), _v(0, 0, 0), _v(0, 0, 0)))
    var obs = List[WorldPos]()
    obs.append(WorldPos(16, 1, 16))
    wp.update(scene, origin, obs, 0)
    var loaded0 = len(wp.loaded)
    s.check(wp.body(1) and not wp.body(2 * 5 + 1), "near cell loaded, far cell not")
    # pacing across the border between cells 0 and 1 (x = 32): after both
    # positions have been visited once (which may load newly near cells),
    # no further events
    for t in range(2):
        obs[0] = WorldPos(30 + Float64(t % 2) * 4, 1, 16)
        wp.update(scene, origin, obs, t)
    var ev0 = len(wp.events)
    for t in range(2, 40):
        obs[0] = WorldPos(30 + Float64(t % 2) * 4, 1, 16)
        wp.update(scene, origin, obs, t)
    s.eqi(len(wp.events) - ev0, 0, "observer pacing over a cell border: no load / unload events (hysteresis)")
    # move a dynamic body from cell 0 into cell 1, then walk away from cell 0 only
    var b0 = wp.body(1).value()
    scene.teleport(b0, Pose6Of(_v(48, 0.25, 16)))
    obs[0] = WorldPos(80, 1, 16)
    wp.update(scene, origin, obs, 50)
    s.check(wp.owner[1] == wp.cell_of(WorldPos(48, 0, 16)), "body moved across the border changed owner")
    obs[0] = WorldPos(140, 1, 16)
    wp.update(scene, origin, obs, 60)
    s.check(not wp.is_loaded(wp.cell_of(WorldPos(16, 0, 16))), "old cell unloaded")
    s.check(wp.body(1).__bool__() == wp.is_loaded(wp.owner[1]), "the moved body follows its new cell, not the old one")
    # unload + reload restores pose and velocity exactly
    var spec = 2 * 4 + 1
    var id = wp.body(spec).value()
    scene.set_velocity(id, _v(1.5, 2.0, -0.5), _v(0, 0.3, 0))
    for _ in range(5):
        scene.step(DT, G, c)
    var p_before = scene.bset.bodies[id.index()].position()
    var v_before = scene.bset.bodies[id.index()].linear_velocity()
    obs[0] = WorldPos(5000, 1, 16)
    wp.update(scene, origin, obs, 70)
    s.check(not wp.body(spec), "teleported observer: cell behind it unloaded")
    var live = 0
    for i in range(len(wp.specs)):
        if wp.live[i]:
            live += 1
    s.eqi(live, 0, "observer 5 km away: nothing of the strip stays in the scene")
    obs[0] = WorldPos(140, 1, 16)
    wp.update(scene, origin, obs, 80)
    var id2 = wp.body(spec).value()
    var p_after = scene.bset.bodies[id2.index()].position()
    var v_after = scene.bset.bodies[id2.index()].linear_velocity()
    var exact = True
    for k in range(3):
        if p_after[k].to_bits() != p_before[k].to_bits() or v_after[k].to_bits() != v_before[k].to_bits():
            exact = False
    s.check(exact, "unload + reload restores position and velocity bit-for-bit")
    _ = loaded0
    s.finish()


def slow_mover_error(start: Vec3) raises -> Float64:
    """|distance travelled - 0.5| for a free box at 0.5 m/s along x for 1 s."""
    var sc = ContactScene6[QuatBody6]()
    var id = sc.add(QuatBody6.at_rest(start, Inertia3.box(1, 0.25, 0.25, 0.25)), _v(0.25, 0.25, 0.25), False)
    sc.set_can_sleep(id, False)
    sc.set_velocity(id, _v(0.5, 0, 0), _v(0, 0, 0))
    var c = cfg()
    for _ in range(60):
        sc.step(DT, Vec3(0, 0, 0, 0), c)
    var travel = Float64(sc.bset.bodies[0].position()[0]) - Float64(start[0])
    return abs(travel - 0.5)


def Pose6Of(p: Vec3) -> Pose6:
    return Pose6(p, Quat.identity())


from physics.rigid6 import Pose6


def walk() raises -> String:
    var wp = WorldPartition(32, 40, 70)
    var scene = ContactScene6[QuatBody6]()
    for i in range(12):
        _ = wp.add(BodySpec(SPEC_BOX, _v(0.25, 0.25, 0.25), 1, False, WorldPos(Float64(i) * 32 + 16, 0.25, 16), Quat.identity(), _v(0, 0, 0), _v(0, 0, 0)))
    var obs = List[WorldPos]()
    obs.append(WorldPos(0, 1, 16))
    var c = cfg()
    for t in range(80):
        obs[0] = WorldPos(Float64(t) * 5, 1, 16)
        wp.update(scene, WorldPos(0, 0, 0), obs, t)
        scene.step(DT, G, c)
    var out = String()
    for e in wp.events:
        out += String(e.tick) + ":" + String(e.cell) + ":" + String(e.kind) + ":" + String(e.bodies) + ";"
    return out
