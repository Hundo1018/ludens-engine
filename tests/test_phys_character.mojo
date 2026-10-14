# tier: integration
"""Dynamic character body and balance quantities (ROADMAP 17.66).

  1. Ordinary: an 80 kg `DynamicCharacter` dropped from 2 m settles with its
     centre at the ride height (1.0 m) within 1 mm; wishing 5 m/s it reaches
     5 m/s within 1 %, then stops in v^2 / (2 a) - v dt / 2 = 0.583 m (the discrete
     tick) within 1 %;
     `Mover` with `MODEL_ACCEL` at the same accel stops in the same distance
     within 1 % (backend parity on flat ground).
  2. Integration: a 100 N s impulse on the dynamic body changes its velocity
     by J / m within 2 % (the kinematic backend has no body to push); the
     ground spring pushes back: a 10 kg box under the hovering character
     falls faster than one alone.
  3. Balance: centre of mass of 1 kg at x = 0 and 3 kg at x = 4 is x = 3;
     the support polygon of a foot's four corners plus an inner point is the
     square, counter-clockwise; margin at its centre = half width; capture
     point x = v sqrt(h / g); standing still is balanced, 1 m/s with a 20 cm
     foot is not.
  4. Extreme: ride below the capsule bottom raises; zero wish in the air is
     finite; collinear contact points give no area (margin -inf).
"""

from std.math import sqrt, isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from physics.rigid6 import QuatBody6, Inertia3
from physics.body_set import BodyId
from physics.solver6 import ContactScene6
from physics.fields import WaterVolume
from gameplay.phys_character import DynamicCharacter
from gameplay.character import CharacterController
from gameplay.movement import Mover, MoveConfig, MODEL_ACCEL
from gameplay.balance import center_of_mass, support_polygon, capture_point, balance_margin, is_balanced

comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 60.0


def _floor() -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 200, 0.5, 200)), Vec3(200, 0.5, 200, 0), True)
    return sc^


def _char(mut sc: ContactScene6[QuatBody6], y: Real) raises -> DynamicCharacter:
    return DynamicCharacter.spawn(sc, QuatBody6.at_rest(Vec3(0, y, 0, 0), Inertia3.box(80, 0.3, 0.9, 0.3)), 80, 0.3, 0.3, 1.0)


def main() raises:
    var s = Suite("phys_character")

    # ---- rest height, speed, stopping ----------------------------------------------------------------
    var sc = _floor()
    var ch = _char(sc, 2)
    for _ in range(180):
        ch.update(sc, Vec3(0, 0, 0, 0), DT, G)
        sc.step_soft(DT, G)
    var y = sc.pose(ch.id).pos[1]
    print("  settled centre y", y, "(ride 1.0)  vy", sc.velocity(ch.id)[1], " on ground", ch.on_ground)
    s.check(abs(y - 1.0) < 1e-3 and ch.on_ground, "settles at the ride height")
    for _ in range(120):
        ch.update(sc, Vec3(5, 0, 0, 0), DT, G)
        sc.step_soft(DT, G)
    var vx = sc.velocity(ch.id)[0]
    var x0 = sc.pose(ch.id).pos[0]
    for _ in range(120):
        ch.update(sc, Vec3(0, 0, 0, 0), DT, G)
        sc.step_soft(DT, G)
    var stop = sc.pose(ch.id).pos[0] - x0
    var want = Real(25.0 / 40.0 - 5.0 * DT / 2)  # discrete: v^2 / 2a - v dt / 2
    var mc = _floor()
    var cfg = MoveConfig.default()
    cfg.model = MODEL_ACCEL
    cfg.accel = 20
    cfg.decel = 20
    var mv = Mover(CharacterController(Vec3(0, 0.9, 0, 0)), cfg)
    var waters = List[WaterVolume]()
    for _ in range(60):
        mv.update(mc, Vec3(0, 0, 0, 0), False, False, DT, G, waters)
    for _ in range(120):
        mv.update(mc, Vec3(5, 0, 0, 0), False, False, DT, G, waters)
    var mx0 = mv.cc.position[0]
    for _ in range(120):
        mv.update(mc, Vec3(0, 0, 0, 0), False, False, DT, G, waters)
    var mstop = mv.cc.position[0] - mx0
    print("  wish 5 m/s: speed", vx, "  stop distance dynamic", stop, " Mover", mstop, " v^2/2a", want)
    s.check(abs(vx - 5) < 0.05, "reaches the wished speed within 1 %")
    s.check(abs(stop / want - 1) < 0.01 and abs(mstop / want - 1) < 0.01, "both backends stop in v^2 / 2a - v dt / 2 within 1 %")

    # ---- pushed, and pushing back ---------------------------------------------------------------------
    var v0 = sc.velocity(ch.id)
    sc.apply_impulse(ch.id, Vec3(0, 0, 100, 0), sc.pose(ch.id).pos)
    var dv = sc.velocity(ch.id)[2] - v0[2]
    print("  100 N s impulse: dv", dv, " J / m", 100.0 / 80.0)
    s.check(abs(dv / 1.25 - 1) < 0.02, "an impulse changes the body velocity by J / m")
    var a1 = ContactScene6[QuatBody6]()
    var box1 = a1.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(10, 0.5, 0.1, 0.5)), Vec3(0.5, 0.1, 0.5, 0), False)
    var c1 = DynamicCharacter.spawn(a1, QuatBody6.at_rest(Vec3(0, 0.95, 0, 0), Inertia3.box(80, 0.3, 0.9, 0.3)), 80, 0.3, 0.3, 1.0)
    var a2 = ContactScene6[QuatBody6]()
    var box2 = a2.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(10, 0.5, 0.1, 0.5)), Vec3(0.5, 0.1, 0.5, 0), False)
    for _ in range(6):
        c1.update(a1, Vec3(0, 0, 0, 0), DT, G)
        a1.step_soft(DT, G)
        a2.step_soft(DT, G)
    var d1 = a1.pose(box1).pos[1]
    var d2 = a2.pose(box2).pos[1]
    print("  box under the character after 0.1 s: y", d1, " alone", d2)
    s.check(d1 < d2 - 0.01, "the ground spring's reaction pushes the body underneath")

    # ---- balance ------------------------------------------------------------------------------------------
    var bs = ContactScene6[QuatBody6]()
    var b1 = bs.add(QuatBody6.at_rest(Vec3(0, 1, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
    var b2 = bs.add(QuatBody6.at_rest(Vec3(4, 1, 0, 0), Inertia3.box(3, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
    var ids: List[BodyId] = [b1, b2]
    var com = center_of_mass(bs, ids)
    s.check(abs(com[0][0] - 3) < 1e-6, "centre of mass of 1 kg at 0 and 3 kg at 4 is 3")
    var foot: List[Vec3] = [Vec3(0.1, 0, -0.1, 0), Vec3(-0.1, 0, -0.1, 0), Vec3(0.02, 0, 0.01, 0), Vec3(-0.1, 0, 0.1, 0), Vec3(0.1, 0, 0.1, 0)]
    var poly = support_polygon(foot)
    var area = Real(0)
    for i in range(len(poly)):
        var a = poly[i]
        var b = poly[(i + 1) % len(poly)]
        area += a[0] * b[2] - b[0] * a[2]  # (x, z) shoelace: positive = counter-clockwise
    var m0 = balance_margin(poly, Vec3(0, 0, 0, 0))
    var cp = capture_point(Vec3(0, 1, 0, 0), Vec3(1, 0, 0, 0), 0, 9.8)
    print("  support polygon", len(poly), "vertices, signed area", area / 2, " margin at centre", m0, " capture point x", cp[0])
    s.check(len(poly) == 4 and area > 0 and abs(m0 - 0.1) < 1e-6, "foot hull: the square, counter-clockwise, margin = half width")
    s.check(abs(cp[0] - Real(sqrt(1.0 / 9.8))) < 1e-6, "capture point x = v sqrt(h / g)")
    s.check(is_balanced(poly, Vec3(0, 1, 0, 0), Vec3(0, 0, 0, 0), 0, 9.8) and not is_balanced(poly, Vec3(0, 1, 0, 0), Vec3(1, 0, 0, 0), 0, 9.8), "still: balanced; 1 m/s over a 20 cm foot: not")

    # ---- extremes -------------------------------------------------------------------------------------------
    var raised = False
    try:
        var e = ContactScene6[QuatBody6]()
        _ = DynamicCharacter.spawn(e, QuatBody6.at_rest(Vec3(0, 1, 0, 0), Inertia3.box(80, 0.3, 0.9, 0.3)), 80, 0.3, 0.3, 0.5)
    except:
        raised = True
    s.check(raised, "ride below the capsule bottom raises")
    var air = ContactScene6[QuatBody6]()
    var ca = DynamicCharacter.spawn(air, QuatBody6.at_rest(Vec3(0, 50, 0, 0), Inertia3.box(80, 0.3, 0.9, 0.3)), 80, 0.3, 0.3, 1.0)
    for _ in range(30):
        ca.update(air, Vec3(0, 0, 0, 0), DT, G)
        air.step_soft(DT, G)
    s.check(not ca.on_ground and isfinite(air.pose(ca.id).pos[1]), "in the air: no ground, finite")
    var line: List[Vec3] = [Vec3(0, 0, 0, 0), Vec3(1, 0, 0, 0), Vec3(2, 0, 0, 0)]
    s.check(balance_margin(support_polygon(line), Vec3(1, 0, 0, 0)) < -1e30, "collinear contacts: no area to stand on")
    s.finish()
