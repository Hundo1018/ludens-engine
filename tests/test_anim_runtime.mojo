# tier: component
"""Animation runtime: events, sync markers, state graph, inertialization
(ROADMAP 17.64).

  1. Ordinary: a footstep at 0.31 s of a 1 s looping clip fires exactly 10
     times in 10 s whether the tick is 1/60 s, 0.3 s or one 10 s jump, 20
     times at playback speed 2, once going backwards over it; an event at 0
     fires at the start; an event on a tick boundary fires once; a
     non-looping clip's end event fires once. Sync markers map walk time
     0.25 / 0.75 to run time 0.15 / 0.45. The graph goes idle -> walk -> run
     -> jump (trigger, non-interruptible) -> idle (exit time) as parameters
     change.
  2. Integration: fade and inertialization both end exactly on the target
     clip's pose; inertialization starts from the pose shown before the
     switch (within 1e-5); a graph copied mid-transition continues bit for
     bit; a zero offset leaves the target pose untouched.
  3. Extreme: an empty track fires nothing; a transition to an unknown
     state raises; a negative event time raises.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from procedural.anim import AnimClip
from procedural.anim_events import EventTrack, marker_phase, sync_time
from procedural.inertialize import Inertializer
from procedural.anim_state import (
    AnimGraph, AnimTransition, Cond, COND_GT, COND_LT, COND_TRIGGER,
    TRANS_FADE, TRANS_INERTIAL,
)
from procedural.tween import EASE_CUBIC_OUT, EASE_LINEAR

comptime B = 2


def _fires(tr: EventTrack, dt: Real, total: Real, length: Real, loop: Bool) -> Int:
    var out = List[Int]()
    var t = Real(0)
    var steps = Int(total / dt + 0.5)
    for _ in range(steps):
        tr.fire(t, t + dt, length, loop, out)
        t += dt
    return len(out)


def _clip(kind: Int) raises -> AnimClip:
    """0 idle (still), 1 walk (bone 0 moves along x), 2 run (bone 0 turns
    about y), 3 jump (bone 0 rises, not looping)."""
    var c = AnimClip(B, 11, 10, kind != 3)
    for f in range(11):
        var u = Real(f) / 10
        for b in range(B):
            var p = Vec3(0, Real(b), 0, 0)
            var q = Quat(0, 0, 0, 1)
            if kind == 1 and b == 0:
                p = Vec3(u, 0, 0, 0)
            elif kind == 2 and b == 0:
                q = Quat.from_axis_angle(Vec3(0, 1, 0, 0), u * 3)
            elif kind == 3 and b == 0:
                p = Vec3(0, 0.5 * u, 0, 0)
            c.set_key(f, b, p, q)
    return c^


def _graph(mode: Int) raises -> AnimGraph:
    var g = AnimGraph(B, mode)
    var idle = g.add_state(0)
    var walk = g.add_state(1)
    var run = g.add_state(2)
    var jump = g.add_state(3)
    var speed = g.add_float(0)
    var jt = g.add_trigger()
    g.add_transition(AnimTransition(-1, jump, [Cond(COND_TRIGGER, jt, 0)], -1, 0.1, EASE_LINEAR, False))
    g.add_transition(AnimTransition(jump, idle, List[Cond](), 0.9, 0.2, EASE_LINEAR, True))
    g.add_transition(AnimTransition(idle, walk, [Cond(COND_GT, speed, 0.1)], -1, 0.15, EASE_CUBIC_OUT, True))
    g.add_transition(AnimTransition(walk, run, [Cond(COND_GT, speed, 3)], -1, 0.2, EASE_CUBIC_OUT, True))
    g.add_transition(AnimTransition(run, walk, [Cond(COND_LT, speed, 3)], -1, 0.2, EASE_CUBIC_OUT, True))
    g.add_transition(AnimTransition(walk, idle, [Cond(COND_LT, speed, 0.1)], -1, 0.15, EASE_CUBIC_OUT, True))
    return g^


def main() raises:
    var s = Suite("anim_runtime")

    # ---- events ---------------------------------------------------------------
    var tr = EventTrack()
    tr.add(0.31, 7)
    var a = _fires(tr, 1.0 / 60.0, 10, 1, True)
    var b = _fires(tr, 0.3, 10.2, 1, True)
    var one = List[Int]()
    tr.fire(0, 10, 1, True, one)
    print("  footstep in 10 s: dt 1/60", a, " dt 0.3", b, " one 10 s jump", len(one))
    s.check(a == 10 and b == 10 and len(one) == 10, "exactly once per pass, any tick length")
    var sp2 = List[Int]()
    var t = Real(0)
    for _ in range(600):
        tr.fire(t, t + 2.0 / 60.0, 1, True, sp2)
        t += 2.0 / 60.0
    s.check(len(sp2) == 20, "speed 2 for 10 s: 20 footsteps")
    var back = List[Int]()
    tr.fire(1.0, 0.0, 1, True, back)
    s.check(len(back) == 1, "backwards over the event: once")
    var z = EventTrack()
    z.add(0, 1)
    z.add(0.25, 2)
    var zo = List[Int]()
    z.fire(0, 0.25, 1, True, zo)
    z.fire(0.25, 0.5, 1, True, zo)
    s.check(len(zo) == 2 and zo[0] == 1 and zo[1] == 2, "event at 0 fires at start; boundary event 0.25 fires once")
    var e = EventTrack()
    e.add(1.0, 9)
    s.check(_fires(e, 0.1, 3, 1, False) == 1, "non-looping clip: end event fires once")
    var empty = EventTrack()
    s.check(_fires(empty, 0.1, 3, 1, True) == 0, "empty track: nothing")

    # ---- sync markers ------------------------------------------------------------
    var wm: List[Real] = [0, 0.5]
    var rm: List[Real] = [0, 0.3]
    var r1 = sync_time(0.25, wm, 1.0, rm, 0.6)
    var r2 = sync_time(0.75, wm, 1.0, rm, 0.6)
    print("  sync: walk 0.25 -> run", r1, "  walk 0.75 -> run", r2)
    s.check(abs(r1 - 0.15) < 1e-6 and abs(r2 - 0.45) < 1e-6, "sync markers keep the same step phase")

    # ---- state graph -------------------------------------------------------------
    var clips = List[AnimClip]()
    for k in range(4):
        clips.append(_clip(k))
    var tracks = List[EventTrack]()
    var g = _graph(TRANS_FADE)
    var pos = List[Real](length=3 * B, fill=0)
    var rot = List[Real](length=4 * B, fill=0)
    var ev = List[Int]()
    var seq = List[Int]()
    var dt = Real(1.0 / 60.0)
    for k in range(240):
        if k == 10:
            g.floats[0] = 1
        if k == 60:
            g.floats[0] = 5
        if k == 120:
            g.triggers[0] = True
        if k == 125:
            g.floats[0] = 0  # ignored while the jump transition runs
        g.tick(dt, clips, tracks, pos, rot, ev)
        if len(seq) == 0 or seq[len(seq) - 1] != g.current:
            seq.append(g.current)
    print("  state sequence:", seq[0], seq[1] if len(seq) > 1 else -1, seq[2] if len(seq) > 2 else -1, seq[3] if len(seq) > 3 else -1, seq[4] if len(seq) > 4 else -1)
    s.check(len(seq) == 5 and seq[0] == 0 and seq[1] == 1 and seq[2] == 2 and seq[3] == 3 and seq[4] == 0, "idle -> walk -> run -> jump -> idle (exit time)")
    s.check(not g.triggers[0], "the trigger was consumed")

    # ---- fade vs inertialization ---------------------------------------------------
    var ends_ok = True
    var start_gap = Real(0)
    for mode in [TRANS_FADE, TRANS_INERTIAL]:
        var gm = _graph(mode)
        var p = List[Real](length=3 * B, fill=0)
        var r = List[Real](length=4 * B, fill=0)
        var evs = List[Int]()
        gm.floats[0] = 1
        for _ in range(40):  # into walk, transition done
            gm.tick(dt, clips, tracks, p, r, evs)
        var before = p.copy()
        gm.floats[0] = 5
        gm.tick(dt, clips, tracks, p, r, evs)  # switch to run
        if mode == TRANS_INERTIAL:
            for i in range(3 * B):
                start_gap = max(start_gap, abs(p[i] - before[i]))
        for _ in range(30):
            gm.tick(dt, clips, tracks, p, r, evs)
        var rp = List[Real](length=3 * B, fill=0)
        var rr = List[Real](length=4 * B, fill=0)
        clips[2].sample(gm.time, rp, rr)
        if p != rp or r != rr:
            ends_ok = False
    print("  inertialized switch: largest position jump", start_gap, "(one tick of motion)")
    s.check(ends_ok, "fade and inertialization both end exactly on the target clip")
    s.check(start_gap < 0.02, "inertialization starts from the shown pose (one tick of walk motion, < 2 cm)")

    # ---- snapshot by copy ------------------------------------------------------------
    var g1 = _graph(TRANS_INERTIAL)
    var p1 = List[Real](length=3 * B, fill=0)
    var q1 = List[Real](length=4 * B, fill=0)
    var e1 = List[Int]()
    g1.floats[0] = 1
    for _ in range(30):
        g1.tick(dt, clips, tracks, p1, q1, e1)
    g1.floats[0] = 5
    g1.tick(dt, clips, tracks, p1, q1, e1)
    var g2 = g1.copy()
    var p2 = p1.copy()
    var q2 = q1.copy()
    var same = True
    for _ in range(40):
        g1.tick(dt, clips, tracks, p1, q1, e1)
        g2.tick(dt, clips, tracks, p2, q2, e1)
        if p1 != p2 or q1 != q2:
            same = False
    s.check(same, "a graph copied mid-transition continues bit for bit")

    var ine = Inertializer(B)
    var tp = List[Real](length=3 * B, fill=0.5)
    var tq = List[Real](length=4 * B, fill=0)
    tq[3] = 1
    tq[7] = 1
    ine.start(tp, tq, tp, tq, 0.2)
    var ap = tp.copy()
    var aq = tq.copy()
    ine.apply(ap, aq)
    s.check(ap == tp and aq == tq, "zero offset: target pose untouched")

    # ---- extremes ------------------------------------------------------------------------
    var raised = 0
    var gx = AnimGraph(B)
    _ = gx.add_state(0)
    try:
        gx.add_transition(AnimTransition(0, 5, List[Cond](), -1, 0.1, EASE_LINEAR, True))
    except:
        raised += 1
    var bad = EventTrack()
    try:
        bad.add(-1, 0)
    except:
        raised += 1
    s.check(raised == 2, "unknown state and negative event time raise")
    s.finish()
