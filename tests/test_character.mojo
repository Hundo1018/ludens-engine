# tier: integration
"""ROADMAP 17.1: kinematic capsule character controller against real scenes.

Ordinary: walks on a flat floor at the commanded speed and stays grounded;
climbs a walkable ramp; is stopped by a too-steep ramp; steps onto a low
step and is stopped by a tall one; a jump under a ceiling is cut short.
Integration: rides a kinematic platform; pushes a light dynamic box.
Extreme: spawned inside a wall, standing still for 60 steps (no drift),
squeezed between two walls, standing up under a low ceiling (refused),
teleported high above the floor (falls and lands)."""

from harness.runner import Suite
from std.math import tan
from geometry.vec import Real, Vec3, length
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from gameplay.character import CharacterController, CharacterConfig
from collision.world_query import QueryFilter

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ZERO = Vec3(0, 0, 0, 0)
comptime START_Y: Real = 0.92  # foot 0.02 above a floor at y = 0 (hh 0.6 + r 0.3)


def _st(p: Vec3) -> QuatBody6:
    return QuatBody6.at_rest(p, Inertia3.box(1, 1, 1, 1))


def _floor() -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(_st(Vec3(0, -1, 0, 0)), Vec3(30, 1, 30, 0), True)
    return sc^


def _wedge(x0: Real, length_x: Real, rise: Real) -> List[Real]:
    """Ramp hull rising along +x from x0 (y = 0) to x0 + length_x (y = rise)."""
    var v = List[Real]()
    for z in range(2):
        var zz = Real(z * 4 - 2)
        for p in [(x0, Real(0)), (x0 + length_x, Real(0)), (x0 + length_x, rise)]:
            v.append(p[0])
            v.append(p[1])
            v.append(zz)
    return v^


def _run(mut c: CharacterController, mut sc: ContactScene6[QuatBody6], walk: Vec3, steps: Int, step_scene: Bool):
    for _ in range(steps):
        c.update(sc, walk, 0, DT, G)
        if step_scene:
            sc.step_soft(DT, G)


def main() raises:
    var s = Suite("character")

    # ---- flat floor ----
    var sc = _floor()
    var c = CharacterController(Vec3(0, START_Y, 0, 0))
    _run(c, sc, ZERO, 5, False)
    s.check(c.on_ground, "settles grounded on the floor")
    var y0 = c.position[1]
    _run(c, sc, Vec3(2, 0, 0, 0), 60, False)
    s.almost(Float64(c.position[0]), 2.0, "walks 2 m in 1 s at 2 m/s", 0.02)
    s.almost(Float64(c.position[1]), Float64(y0), "height unchanged while walking", 1e-3)
    s.check(c.on_ground, "still grounded after walking")

    # ---- walkable ramp (20 deg) ----
    var ramp = _floor()
    _ = ramp.add_hull(_st(ZERO), _wedge(1, 4, 4 * tan(Real(0.349066))), True)
    var cr = CharacterController(Vec3(0, START_Y, 0, 0))
    _run(cr, ramp, Vec3(2, 0, 0, 0), 150, False)
    s.check(cr.position[1] > 1.2, "climbs a 20-degree ramp (y " + String(cr.position[1]) + ")")

    # ---- too-steep ramp (60 deg) ----
    var steep = _floor()
    _ = steep.add_hull(_st(ZERO), _wedge(1, 2, 2 * tan(Real(1.047198))), True)
    var cs = CharacterController(Vec3(0, START_Y, 0, 0))
    _run(cs, steep, Vec3(2, 0, 0, 0), 120, False)
    s.check(cs.position[1] < START_Y + 0.4, "does not climb a 60-degree ramp (y " + String(cs.position[1]) + ")")
    s.check(cs.position[0] < 1.2, "is stopped at the steep ramp (x " + String(cs.position[0]) + ")")

    # ---- low step (0.2) and tall block (0.6) ----
    var step = _floor()
    _ = step.add(_st(Vec3(3, 0.1, 0, 0)), Vec3(1.5, 0.1, 2, 0), True)
    var cst = CharacterController(Vec3(0, START_Y, 0, 0))
    _run(cst, step, Vec3(2, 0, 0, 0), 90, False)
    s.almost(Float64(cst.foot()[1]), 0.2, "steps onto a 0.2 step (foot at its top)", 0.03)
    var block = _floor()
    _ = block.add(_st(Vec3(3, 0.3, 0, 0)), Vec3(1.5, 0.3, 2, 0), True)
    var cb = CharacterController(Vec3(0, START_Y, 0, 0))
    _run(cb, block, Vec3(2, 0, 0, 0), 90, False)
    s.check(cb.position[0] < 1.3 and cb.foot()[1] < 0.05, "is blocked by a 0.6 block (x " + String(cb.position[0]) + ")")

    # ---- ceiling ----
    var ceil = _floor()
    _ = ceil.add(_st(Vec3(0, 2.5, 0, 0)), Vec3(3, 0.5, 3, 0), True)  # bottom at y = 2
    var cc = CharacterController(Vec3(0, START_Y, 0, 0))
    _run(cc, ceil, ZERO, 3, False)
    var top_max = Real(0)
    var saw_ceiling = False
    cc.update(ceil, ZERO, 6, DT, G)
    saw_ceiling = cc.hit_ceiling
    for _ in range(60):
        cc.update(ceil, ZERO, 0, DT, G)
        top_max = max(top_max, cc.position[1] + 0.6 + 0.3)
        saw_ceiling = saw_ceiling or cc.hit_ceiling
    s.check(saw_ceiling, "the jump reports hitting the ceiling")
    s.check(top_max <= 2.0 + 1e-3, "head never passes the ceiling (max " + String(top_max) + ")")
    s.check(cc.on_ground, "lands back on the floor")

    # ---- moving platform ----
    var pl = _floor()
    var pid = pl.add(_st(Vec3(0, 0.1, 0, 0)), Vec3(3, 0.1, 3, 0), False)
    pl.set_kinematic(pid)
    pl.set_velocity(pid, Vec3(1, 0, 0, 0), ZERO)
    var cp = CharacterController(Vec3(0, START_Y + 0.2, 0, 0))
    _run(cp, pl, ZERO, 5, True)
    var x_start = cp.position[0]
    _run(cp, pl, ZERO, 60, True)
    s.almost(Float64(cp.position[0] - x_start), 1.0, "rides a 1 m/s platform ~1 m in 1 s", 0.1)
    s.check(cp.on_ground and cp.ground_body == pid.index(), "stands on the platform")

    # ---- pushing a dynamic box ----
    var pb = _floor()
    var box = pb.add(QuatBody6.at_rest(Vec3(1.2, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False).index()
    var cpush = CharacterController(Vec3(0, START_Y, 0, 0))
    var bx0 = pb.bset.bodies[box].position()[0]
    _run(cpush, pb, Vec3(2, 0, 0, 0), 60, True)
    s.check(pb.bset.bodies[box].position()[0] > bx0 + 0.2, "walking into a light box pushes it")

    # ---- extreme: spawned inside a wall ----
    var wall = _floor()
    _ = wall.add(_st(Vec3(1, 1, 0, 0)), Vec3(0.2, 1, 3, 0), True)
    var cw = CharacterController(Vec3(0.9, START_Y, 0, 0))
    cw.update(wall, ZERO, 0, DT, G)
    var seg_a = cw.position - Vec3(0, 0.6, 0, 0)
    var seg_b = cw.position + Vec3(0, 0.6, 0, 0)
    var left = wall.capsule_penetrations(seg_a, seg_b, 0.3 - 0.005, QueryFilter.all())
    s.eqi(len(left), 0, "pushed out of a wall it spawned in")

    # ---- extreme: no drift standing still ----
    var sd = _floor()
    var cd = CharacterController(Vec3(0, START_Y, 0, 0))
    _run(cd, sd, ZERO, 5, False)
    var p0 = cd.position
    _run(cd, sd, ZERO, 60, False)
    s.check(length(cd.position - p0) < 1e-4, "standing still for 60 steps does not drift")

    # ---- extreme: squeezed between two walls ----
    var sq = _floor()
    _ = sq.add(_st(Vec3(-0.45, 1, 0, 0)), Vec3(0.2, 1, 3, 0), True)
    _ = sq.add(_st(Vec3(0.45, 1, 0, 0)), Vec3(0.2, 1, 3, 0), True)
    var cq = CharacterController(Vec3(0, START_Y, 0, 0))
    _run(cq, sq, Vec3(1, 0, 0, 0), 30, False)
    var finite = cq.position[0] == cq.position[0] and abs(cq.position[0]) < 10
    s.check(finite, "squeezed between walls closer than its diameter: stays finite")

    # ---- extreme: stand up under a low ceiling ----
    var low = _floor()
    _ = low.add(_st(Vec3(0, 1.8, 0, 0)), Vec3(3, 0.5, 3, 0), True)  # bottom at 1.3
    var cl = CharacterController(Vec3(0, 0.62, 0, 0), CharacterConfig(0.3, 0.3, 0.7071, 0.3, 0.01, 0.25, 4, 1.0, 0xFFFFFFFF))
    _run(cl, low, ZERO, 5, False)
    s.check(not cl.set_half_height(low, 0.6), "standing up under a 1.3 m ceiling is refused")
    s.check(cl.set_half_height(low, 0.2), "crouching lower is allowed")

    # ---- extreme: teleport high, fall, land ----
    var tf = _floor()
    var ct = CharacterController(Vec3(0, START_Y, 0, 0))
    ct.teleport(Vec3(5, 20, 5, 0))
    _run(ct, tf, ZERO, 180, False)
    s.check(ct.on_ground and abs(ct.foot()[1]) < 0.05, "falls from 20 m and lands on the floor")
    s.finish()
