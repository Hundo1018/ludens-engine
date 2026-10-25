# tier: integration
"""Sequence playback into the simulation (ROADMAP 17.68,
`gameplay.sequence_player`, `Sequence` clip tracks,
`ContactScene6.set_dynamic`).

  1. Ordinary: a clip track (walk from 0 s; run from 1 s at speed 1.5 with
     a 0.25 s crossfade; idle from 3 s with no blend) gives, at 1.125 s,
     run at local 0.1875 weight 0.5 and walk at local 1.125; before the
     first key no clip; values are a pure function of t (any order).
  2. Integration: a 1 x 0.2 x 1 m platform keyed from x 0 to 4 m over 2 s
     (2 m/s) carries a box resting on it (the box slides back ~0.17 m at
     the instant start); two sequence events (0.51 s and 1.51 s) reach a
     `Channel` reader once each, at ticks 31 and 91. After the
     last tick the platform is released: it leaves at the track's velocity
     (2 m/s along x) and falls under gravity (x and y after 0.5 s more vs
     the projectile formula).
  3. Extreme: binding a missing track, `set_dynamic` on a body that is not
     kinematic, a negative blend and keys out of order raise; `dt = 0`
     does nothing.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from scheduler.events import Channel
from procedural.sequence import Sequence
from gameplay.sequence_player import SequencePlayer, SeqEvent

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def main() raises:
    var s = Suite("sequence_player")

    # ---- clip track ------------------------------------------------------------------------------------
    var cs = Sequence(4)
    var kc = cs.add_clip_track()
    cs.key_clip(kc, 0, 7)
    cs.key_clip(kc, 1, 8, 0, 1.5, 0.25)
    cs.key_clip(kc, 3, 9)
    var a = cs.clip(kc, 1.125)
    var before = Sequence(4)
    var kb = before.add_clip_track()
    before.key_clip(kb, 0.5, 7)
    var none = before.clip(kb, 0.25)
    var late = cs.clip(kc, 3.5)
    print("  at 1.125 s: clip", a.clip, "t", a.time, "weight", a.weight, "; from clip", a.prev_clip, "t", a.prev_time, ";  at 3.5 s: clip", late.clip, "t", late.time, "weight", late.weight)
    s.check(a.clip == 8 and a.time == 0.1875 and a.weight == 0.5 and a.prev_clip == 7 and a.prev_time == 1.125, "crossfade into the run clip: local times and weight")
    s.check(none.clip == -1 and late.clip == 9 and late.time == 0.5 and late.weight == 1 and late.prev_clip == -1, "no clip before the first key; a key without blend cuts")
    var same = True
    for i in range(41):
        var t = Real(40 - i) * 0.1
        var x = cs.clip(kc, t)
        var y = cs.clip(kc, t)
        same = same and x.clip == y.clip and x.time == y.time and x.weight == y.weight
    s.check(same, "clip(t) is a pure function of t")

    # ---- platform, events, release --------------------------------------------------------------------------
    var sc = ContactScene6[QuatBody6]()
    var plat = sc.add(QuatBody6.at_rest(Vec3(0, 1, 0, 0), Inertia3.box(5, 0.5, 0.1, 0.5)), Vec3(0.5, 0.1, 0.5, 0), False)
    var box = sc.add(QuatBody6.at_rest(Vec3(0, 1.3, 0, 0), Inertia3.box(1, 0.2, 0.2, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False)
    sc.set_friction(box.index(), 1.0)
    sc.set_friction(plat.index(), 1.0)
    sc.set_sleep_thresholds(box, 0, 0)
    var seq = Sequence(2)
    var kp = seq.add_vec3_track()
    seq.key_vec3(kp, 0, Vec3(0, 1, 0, 0))
    seq.key_vec3(kp, 2, Vec3(4, 1, 0, 0))
    seq.events.add(0.51, 11)
    seq.events.add(1.51, 12)
    var pl = SequencePlayer(3, seq^)
    pl.bind(sc, plat, kp, -1, True)
    var ch = Channel[SeqEvent]()
    var reader = ch.register_reader()
    var got = List[SeqEvent]()
    var ticks = List[Int]()
    var tick = 0
    var vx_release: Real
    var box_on = Real(0)
    while not pl.released:
        pl.tick(sc, DT, ch)
        sc.step_soft(DT, G)
        tick += 1
        var buf = List[SeqEvent]()
        ch.read(reader, buf)
        for e in buf:
            got.append(e)
            ticks.append(tick)
        ch.update()
        if pl.finished and not pl.released:
            box_on = sc.bset.bodies[box.index()].pos[0]
    vx_release = sc.bset.bodies[plat.index()].vel[0]
    var x0 = sc.bset.bodies[plat.index()].pos[0]
    var y0 = sc.bset.bodies[plat.index()].pos[1]
    var vy0 = sc.bset.bodies[plat.index()].vel[1]
    for _ in range(30):
        pl.tick(sc, DT, ch)
        sc.step_soft(DT, G)
    var x1 = sc.bset.bodies[plat.index()].pos[0]
    var y1 = sc.bset.bodies[plat.index()].pos[1]
    var yf = y0 + vy0 * 0.5 - 0.5 * 9.8 * 0.25
    print("  events", len(got), ":", got[0].event, "at tick", ticks[0], " ", got[1].event, "at tick", ticks[1], "(sequence", got[0].sequence, ")")
    s.check(len(got) == 2 and got[0].event == 11 and ticks[0] == 31 and got[1].event == 12 and ticks[1] == 91 and got[0].sequence == 3, "events reach the channel once, in tick order")
    print("  platform end x", x0, " box x", box_on, " released at vx", vx_release, ";  0.5 s later x", x1, "(free flight", x0 + vx_release * 0.5, ") y", y1, "(", yf, ")")
    s.check(abs(x0 - 4) < 0.05 and box_on > 3.7 and box_on < 4.1, "the platform follows the track and carries the box")
    s.check(abs(vx_release - 2) < 1e-3 and abs(x1 - (x0 + vx_release * 0.5)) < 0.02 and abs(y1 - yf) < 0.02, "released at the track's 2 m/s, then a projectile")

    # ---- extremes -------------------------------------------------------------------------------------
    var raised = 0
    var sc2 = ContactScene6[QuatBody6]()
    var b2 = sc2.add(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(1, 1, 1, 0), False)
    var p2 = SequencePlayer(0, Sequence(1))
    try:
        p2.bind(sc2, b2, 0)
    except:
        raised += 1
    try:
        sc2.set_dynamic(b2)
    except:
        raised += 1
    try:
        cs.key_clip(kc, 3.5, 1, 0, 1, -1)
    except:
        raised += 1
    try:
        cs.key_clip(kc, 2, 1)
    except:
        raised += 1
    s.check(raised == 4, "missing track, set_dynamic on a dynamic body, negative blend, out-of-order key raise")
    var t_before = pl.cursor.t
    pl.tick(sc, 0, ch)
    s.check(pl.cursor.t == t_before, "dt = 0 does nothing")
    s.finish()
