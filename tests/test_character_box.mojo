# tier: integration
"""ROADMAP 17.53: box-shaped character controller (`box_rounding >= 0`).

The controller sweeps a rounded box of half extents (r, hh + r, r) through
`shape_cast` and pushes out with `shape_penetrations`; the capsule path is
the default and unchanged (`test_character`).

  1. Ordinary: settles on a flat floor with its bottom a skin above it and
     walks 2 m in 1 s at 2 m/s; a wall stops it with its face a skin short
     of the wall.
  2. Integration: steps onto a 0.25 m step and is stopped by a 0.5 m one;
     standing on a ledge with its centre 0.2 m past the edge, the box stays
     level on it (0.1 m of flat bottom still on the ledge) while a capsule
     of the same radius rests on the edge with its round bottom, 0.076 m
     below the ledge top (0.3 - sqrt(0.3^2 - 0.2^2)) -- the reason to pick
     a box.
  3. Extreme: spawned 0.04 m into the floor it is pushed out within one
     update; under a 1.5 m ceiling, standing up to 1.8 m is refused and to
     1.4 m allowed; rounding 0 still
     casts (sharp box) and stands on the floor.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from gameplay.character import CharacterController, CharacterConfig

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ZERO = Vec3(0, 0, 0, 0)
comptime START_Y: Real = 0.92  # bottom 0.02 above a floor at y = 0 (hh 0.6 + r 0.3)
comptime ROUND: Real = 0.05


def _st(p: Vec3) -> QuatBody6:
    return QuatBody6.at_rest(p, Inertia3.box(1, 1, 1, 1))


def _floor() -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(_st(Vec3(0, -1, 0, 0)), Vec3(30, 1, 30, 0), True)
    return sc^


def _run(mut c: CharacterController, mut sc: ContactScene6[QuatBody6], walk: Vec3, steps: Int):
    for _ in range(steps):
        c.update(sc, walk, 0, DT, G)


def main() raises:
    var s = Suite("character_box")
    var cfg = CharacterConfig.default()

    # ---- flat floor, walking, wall --------------------------------------------------------------
    var sc = _floor()
    var c = CharacterController(Vec3(0, START_Y, 0, 0), cfg, ROUND)
    _run(c, sc, ZERO, 10)
    var bottom = c.foot()[1]
    print("  box character on the floor: bottom", bottom, " grounded", c.on_ground)
    s.check(c.on_ground and abs(bottom - cfg.skin) < 2e-3, "settles grounded, bottom a skin above the floor")
    _run(c, sc, Vec3(2, 0, 0, 0), 60)
    print("  walked 1 s at 2 m/s: x", c.position[0], " bottom", c.foot()[1])
    s.check(abs(c.position[0] - 2) < 0.02 and abs(c.foot()[1] - bottom) < 1e-3 and c.on_ground, "walks 2 m in 1 s, height unchanged")

    var wall = _floor()
    _ = wall.add(_st(Vec3(3.5, 1, 0, 0)), Vec3(0.5, 1, 2, 0), True)
    var cw = CharacterController(Vec3(0, START_Y, 0, 0), cfg, ROUND)
    _run(cw, wall, Vec3(3, 0, 0, 0), 120)
    var face = cw.position[0] + cfg.radius
    print("  against a wall at x = 3: box face at", face)
    s.check(face < 3 and face > 3 - 3 * cfg.skin, "a wall stops the box a skin short")

    # ---- steps ---------------------------------------------------------------------------------------
    var low = _floor()
    _ = low.add(_st(Vec3(3, 0.125, 0, 0)), Vec3(1, 0.125, 2, 0), True)
    var cl = CharacterController(Vec3(0, START_Y, 0, 0), cfg, ROUND)
    _run(cl, low, Vec3(2, 0, 0, 0), 90)
    print("  0.25 m step: x", cl.position[0], " bottom", cl.foot()[1])
    s.check(cl.position[0] > 2.5 and abs(cl.foot()[1] - 0.25 - cfg.skin) < 0.01, "steps onto a 0.25 m step")
    var tall = _floor()
    _ = tall.add(_st(Vec3(3, 0.25, 0, 0)), Vec3(1, 0.25, 2, 0), True)
    var ct = CharacterController(Vec3(0, START_Y, 0, 0), cfg, ROUND)
    _run(ct, tall, Vec3(2, 0, 0, 0), 90)
    print("  0.5 m step: x", ct.position[0], " bottom", ct.foot()[1])
    s.check(ct.position[0] + cfg.radius < 2.01 and ct.foot()[1] < 0.05, "a 0.5 m step stops it")

    # ---- ledge: box vs capsule -----------------------------------------------------------------------
    # a 1 m high block whose edge is at x = 0; the character's centre 0.2 m past it
    var ledge_y = Real(1)
    var lb = ContactScene6[QuatBody6]()
    _ = lb.add(_st(Vec3(-2, 0.5, 0, 0)), Vec3(2, 0.5, 2, 0), True)
    var lc = ContactScene6[QuatBody6]()
    _ = lc.add(_st(Vec3(-2, 0.5, 0, 0)), Vec3(2, 0.5, 2, 0), True)
    var box_c = CharacterController(Vec3(0.2, ledge_y + START_Y, 0, 0), cfg, ROUND)
    var cap_c = CharacterController(Vec3(0.2, ledge_y + START_Y, 0, 0), cfg)
    _run(box_c, lb, ZERO, 60)
    _run(cap_c, lc, ZERO, 60)
    print("  centre 0.2 m past a ledge, 1 s: box bottom", box_c.foot()[1], " x", box_c.position[0], " | capsule bottom", cap_c.foot()[1], " x", cap_c.position[0])
    s.check(box_c.on_ground and abs(box_c.foot()[1] - ledge_y - cfg.skin) < 2e-3 and abs(box_c.position[0] - 0.2) < 1e-3, "the box stands on the ledge with 0.1 m of bottom on it")
    var hang = Real(0.3) - (Real(0.3 * 0.3 - 0.2 * 0.2)) ** 0.5  # round bottom resting on the edge
    s.check(abs(cap_c.foot()[1] - (ledge_y - hang + cfg.skin)) < 1e-3, "a capsule of the same radius hangs on the edge, its bottom 0.076 m below the ledge (analytic, + skin)")

    # ---- extreme ---------------------------------------------------------------------------------------
    var sp = _floor()
    var cp = CharacterController(Vec3(0, 0.9 - 0.04, 0, 0), cfg, ROUND)
    _run(cp, sp, ZERO, 1)
    print("  spawned 0.04 m into the floor: bottom after one update", cp.foot()[1])
    s.check(cp.foot()[1] > -1e-3, "pushed out of the floor within one update")

    var ceil = _floor()
    _ = ceil.add(_st(Vec3(0, 1.6, 0, 0)), Vec3(2, 0.1, 2, 0), True)
    var ccfg = cfg
    ccfg.half_height = 0.3  # crouched: 1.2 m tall
    var cc = CharacterController(Vec3(0, START_Y - 0.3, 0, 0), ccfg, ROUND)
    _run(cc, ceil, ZERO, 5)
    var stood = cc.set_half_height(ceil, 0.6)  # would be 1.8 m
    var half = cc.set_half_height(ceil, 0.4)  # 1.4 m fits
    s.check(not stood and half and cc.cfg.half_height == 0.4, "under a 1.5 m ceiling: standing to 1.8 m refused, 1.4 m allowed")

    var sharp = _floor()
    var cs0 = CharacterController(Vec3(0, START_Y, 0, 0), cfg, 0)
    _run(cs0, sharp, Vec3(1, 0, 0, 0), 60)
    print("  rounding 0 (sharp box): x", cs0.position[0], " bottom", cs0.foot()[1])
    s.check(cs0.on_ground and abs(cs0.position[0] - 1) < 0.02 and abs(cs0.foot()[1] - cfg.skin) < 2e-3, "a sharp box (rounding 0) walks and stays grounded")
    s.finish()
