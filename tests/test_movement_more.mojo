# tier: integration
"""Ladders, sliding, gliding (ROADMAP 17.67, `gameplay.movement`).

  1. Ladder: a 3 m block with a ladder on its -x face (speed 1.5 m/s). A
     character walking at the face climbs it and steps onto the top
     (standing on y = 3, past the face); the climb takes about
     3 / 1.5 = 2 s.
  2. Jumping off a ladder half way up pushes off along the face and lands
     back on the floor in front of it.
  3. Sliding: on a 35-degree slope (walkable: the limit is 45) with
     `slide_angle` 25 degrees and friction 0.2 the character slides
     downhill; the speed along the slope after 0.5 s matches
     g (sin a - mu cos a) t within 10 %. Without `slide_angle` it stands.
  4. Gliding: dropped from 20 m with jump held and `glide_sink` 2 m/s it
     never sinks faster than 2 m/s once gliding and takes about 10 s to
     land; without holding jump it falls in about 2 s.
  5. Crushing: a kinematic lift rising at 1 m/s under a 0.5 m ceiling
     carries the character up; `crushed` is false while the gap is taller
     than the character (1.8 m) and true from the first tick it is not;
     the character is never pushed through the ceiling (it used to end up
     standing on top of it).
  6. Shapes: under a bar 0.7 m above the floor an upright character
     (1.8 m) is stopped, the same character lying along its walking
     direction crawls through; standing up under the bar is refused,
     past it allowed. A sphere character (`half_height` 0) steps up a
     0.2 m step and rests on it.
"""

from std.math import sin, cos
from harness.runner import Suite
from geometry.vec import Real, Vec3, length, dot
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3, Pose6
from physics.solver6 import ContactScene6
from physics.fields import WaterVolume
from gameplay.character import CharacterController, CharacterConfig
from gameplay.movement import Mover, Ladder, MODE_LADDER, MODE_SLIDE, MODE_GLIDE

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def floor(mut sc: ContactScene6[QuatBody6]):
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 30, 0.5, 30)), Vec3(30, 0.5, 30, 0), True)


def ladder_scene() -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    floor(sc)
    _ = sc.add(QuatBody6.at_rest(Vec3(2, 1.5, 0, 0), Inertia3.box(1, 1, 1.5, 2)), Vec3(1, 1.5, 2, 0), True)  # x 1..3, top y 3
    return sc^


def main() raises:
    var s = Suite("movement_more")
    var no_water = List[WaterVolume]()

    # ---- ladder: climb and step off the top -----------------------------------------------------------
    var sc = ladder_scene()
    var m = Mover(CharacterController(Vec3(-1, 0.92, 0, 0)))
    m.ladders.append(Ladder(Vec3(0.6, 0, -0.5, 0), Vec3(1.0, 3, 0.5, 0), Vec3(-1, 0, 0, 0), 1.5))
    var on_at = -1
    var off_at = -1
    for k in range(400):
        var walk = off_at < 0 or k < off_at + 20  # stop on top, 20 ticks after leaving the ladder
        m.update(sc, Vec3(1.5, 0, 0, 0) if walk else Vec3(0, 0, 0, 0), False, False, DT, G, no_water)
        if on_at < 0 and m.mode == MODE_LADDER:
            on_at = k
        if on_at >= 0 and off_at < 0 and m.mode != MODE_LADDER:
            off_at = k
    var foot = m.cc.foot()
    var climb_s = Real(off_at - on_at) * DT
    print("ladder: on at tick", on_at, " off at", off_at, " (", climb_s, "s )  final foot", foot[0], foot[1])
    s.check(on_at >= 0 and off_at > on_at and abs(foot[1] - 3) < 0.05 and foot[0] > 1.0, "climbs the ladder and stands on top of the block")
    s.check(abs(climb_s - 2) < 0.3, "the climb takes about height / speed = 2 s")

    # ---- ladder: jump off half way -------------------------------------------------------------------
    var sc2 = ladder_scene()
    var j = Mover(CharacterController(Vec3(-1, 0.92, 0, 0)))
    j.ladders.append(Ladder(Vec3(0.6, 0, -0.5, 0), Vec3(1.0, 3, 0.5, 0), Vec3(-1, 0, 0, 0), 1.5))
    var jumped = False
    for _ in range(300):
        var press = j.mode == MODE_LADDER and j.cc.foot()[1] > 1.5 and not jumped
        if press:
            jumped = True
        j.update(sc2, Vec3(1.5, 0, 0, 0) if not jumped else Vec3(0, 0, 0, 0), press, press, DT, G, no_water)
    print("jump off the ladder: lands at x", j.cc.position[0], " foot y", j.cc.foot()[1], " grounded", j.cc.on_ground)
    s.check(jumped and j.cc.position[0] < 0.4 and abs(j.cc.foot()[1]) < 0.05 and j.cc.on_ground, "jumping off pushes away and lands on the floor in front")

    # ---- sliding -------------------------------------------------------------------------------------
    var a = Real(0.610865)  # 35 degrees
    var slope = ContactScene6[QuatBody6]()
    floor(slope)
    var sb = QuatBody6.at_rest(Vec3(0, 3, 0, 0), Inertia3.box(1, 10, 0.5, 4))
    sb.set_pose(Pose6(Vec3(0, 3, 0, 0), Quat.from_axis_angle(Vec3(0, 0, 1, 0), a)))
    _ = slope.add(sb^, Vec3(10, 0.5, 4, 0), True)
    # a point on the slope surface: the box's +y face, 2 m up-slope from the centre
    var nrm = Vec3(-sin(a), cos(a), 0, 0)
    var along = Vec3(cos(a), sin(a), 0, 0)
    var start = Vec3(0, 3, 0, 0) + nrm * Real(0.5 + 0.9 + 0.02) + along * 2
    var sl = Mover(CharacterController(start))
    sl.slide_angle = 0.436332  # 25 degrees
    sl.slide_friction = 0.2
    var st = Mover(CharacterController(start))
    for _ in range(20):  # settle onto the slope
        sl.update(slope, Vec3(0, 0, 0, 0), False, False, DT, G, no_water)
        st.update(slope, Vec3(0, 0, 0, 0), False, False, DT, G, no_water)
    var p0 = sl.cc.position
    var q0 = st.cc.position
    var t_slide = 30
    var sliding = 0
    for _ in range(t_slide):
        sl.update(slope, Vec3(0, 0, 0, 0), False, False, DT, G, no_water)
        st.update(slope, Vec3(0, 0, 0, 0), False, False, DT, G, no_water)
        if sl.mode == MODE_SLIDE:
            sliding += 1
    var moved = length(sl.cc.position - p0)
    var stood = length(st.cc.position - q0)
    var acc = Real(9.8) * (sin(a) - Real(0.2) * cos(a))
    var v_expect = acc * Real(20 + t_slide) * DT  # sliding since the settle began
    var v_meas = dot(sl.cc.velocity, -along) if length(sl.cc.velocity) > 0 else Real(0)
    var v_h = length(sl.vel) / cos(a)
    print("slide: ticks sliding", sliding, "/", t_slide, " moved", moved, " speed along slope", v_h, " analytic", v_expect, " without slide_angle moved", stood)
    s.check(sliding == t_slide and abs(v_h / v_expect - 1) < 0.1, "slides downhill at g (sin a - mu cos a) within 10 %")
    s.check(stood < 0.01, "without slide_angle the walkable slope holds the character")
    _ = v_meas

    # ---- gliding -------------------------------------------------------------------------------------
    var fl = ContactScene6[QuatBody6]()
    floor(fl)
    var gl = Mover(CharacterController(Vec3(0, 20, 0, 0)))
    gl.glide_sink = 2
    var ff = Mover(CharacterController(Vec3(0, 20, 0, 0)))
    var worst = Real(0)
    var t_gl = -1
    var t_ff = -1
    for k in range(900):
        gl.update(fl, Vec3(1, 0, 0, 0), False, True, DT, G, no_water)
        ff.update(fl, Vec3(0, 0, 0, 0), False, False, DT, G, no_water)
        if gl.mode == MODE_GLIDE:
            worst = min(worst, gl.cc.velocity[1])
        if t_gl < 0 and gl.cc.on_ground:
            t_gl = k
        if t_ff < 0 and ff.cc.on_ground:
            t_ff = k
    print("glide: worst sink", worst, " landed after", Real(t_gl) * DT, "s;  free fall", Real(t_ff) * DT, "s")
    s.check(worst >= -2.0001 and t_gl > 0 and abs(Real(t_gl) * DT - 9.6) < 1 and abs(Real(t_ff) * DT - 1.95) < 0.2, "gliding sinks at most 2 m/s (~10 s from 20 m); free fall ~2 s")

    # ---- crushing -------------------------------------------------------------------------------------
    var cr = ContactScene6[QuatBody6]()
    floor(cr)
    _ = cr.add(QuatBody6.at_rest(Vec3(0, 3.25, 0, 0), Inertia3.box(1, 3, 0.25, 3)), Vec3(3, 0.25, 3, 0), True)  # ceiling y 3 .. 3.5
    var lift = cr.add(QuatBody6.at_rest(Vec3(0, 0.1, 0, 0), Inertia3.box(1, 1.5, 0.1, 1.5)), Vec3(1.5, 0.1, 1.5, 0), False)
    cr.set_kinematic(lift)
    cr.set_velocity(lift, Vec3(0, 1, 0, 0), Vec3(0, 0, 0, 0))
    var c = CharacterController(Vec3(0, 0.2 + 0.9 + 0.01, 0, 0))
    var first_crush_gap = Real(-1)
    var early = False
    var worst_head = Real(0)
    for _ in range(150):
        c.update(cr, Vec3(0, 0, 0, 0), 0, DT, G)
        var gap = Real(3) - (cr.pose(lift).pos[1] + 0.1)
        if c.crushed and first_crush_gap < 0:
            first_crush_gap = gap
        if c.crushed and gap > 1.8 + 0.02:
            early = True
        worst_head = max(worst_head, c.foot()[1] + 1.8)
        cr.step(DT, G)
    print("crush: first crushed at gap", first_crush_gap, " (character 1.8 m)  highest head", worst_head, " ceiling top 3.5")
    s.check(not early and first_crush_gap > 1.8 - 0.05 and first_crush_gap <= 1.8 + 0.01, "crushed from the first tick the gap is shorter than the character")
    s.check(worst_head < 3.5, "never pushed through the ceiling")

    # ---- shapes: lying and sphere ---------------------------------------------------------------------
    var cs = ContactScene6[QuatBody6]()
    floor(cs)
    _ = cs.add(QuatBody6.at_rest(Vec3(2, 0.95, 0, 0), Inertia3.box(1, 0.5, 0.25, 3)), Vec3(0.5, 0.25, 3, 0), True)  # bar x 1.5..2.5, y 0.7..1.2
    var up_c = CharacterController(Vec3(0, 0.91, 0, 0))
    var lay = CharacterController(Vec3(0, 0.91, 0, 0))
    var laid = lay.set_lying(cs, Vec3(1, 0, 0, 0))
    var refused_under = False
    for k in range(180):
        up_c.update(cs, Vec3(1.5, 0, 0, 0), 0, DT, G)
        lay.update(cs, Vec3(1.5, 0, 0, 0), 0, DT, G)
        if k == 70:  # under the bar
            refused_under = not lay.set_lying(cs, Vec3(0, 0, 0, 0))
    var stood_after = lay.set_lying(cs, Vec3(0, 0, 0, 0))
    print("crawl: upright stops at x", up_c.position[0], "  lying reaches x", lay.position[0], " (foot y", lay.foot()[1], ")  stand under the bar refused", refused_under, " stands after", stood_after)
    s.check(laid and up_c.position[0] < 1.3 and lay.position[0] > 3 and abs(lay.foot()[1]) < 0.05, "upright is stopped by the bar, lying crawls under it")
    s.check(refused_under and stood_after, "standing up is refused under the bar and allowed past it")
    var ss = ContactScene6[QuatBody6]()
    floor(ss)
    _ = ss.add(QuatBody6.at_rest(Vec3(3, 0.1, 0, 0), Inertia3.box(1, 1, 0.1, 2)), Vec3(1, 0.1, 2, 0), True)  # step x 2..4, top 0.2
    var scfg = CharacterConfig.default()
    scfg.half_height = 0
    var ball = CharacterController(Vec3(0, 0.31, 0, 0), scfg)
    for _ in range(120):
        ball.update(ss, Vec3(1.5, 0, 0, 0), 0, DT, G)
    print("sphere character: x", ball.position[0], " foot y", ball.foot()[1], " grounded", ball.on_ground)
    s.check(ball.position[0] > 2.3 and abs(ball.foot()[1] - 0.2) < 0.03 and ball.on_ground, "a sphere character steps up 0.2 m and rests on the step")
    s.finish()
