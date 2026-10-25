# tier: integration
"""Hair strands: Follow-The-Leader with bending (ROADMAP 17.57).

  1. Ordinary: a free strand (bend 0, 16 particles) released horizontal
     (air drag 2 /s) hangs straight below its root after 8 s, every segment within 1e-5 of
     its rest length (FTL keeps length exactly up to rounding); with
     bend 0.5 the same strand sags less than half as far.
  2. Integration: a ponytail (bend 0.3) on a still head comes to rest
     (largest particle speed in its tenth second < 1 cm/s; it was 2 m/s
     before the FTL shift was measured from x + v dt, see physics.strand);
     on a head bone that turns 90 degrees in 0.2 s it swings out and
     settles back to its rest shape on the turned head (within 1 cm after
     6 s; the rest shape is a 20 s run on the turned head, and the
     distance shrinks about 4x per 2 s); strands draped over a head sphere stay outside
     it; a constant 5 m/s wind blows tips downwind (steady 4.7 cm for this
     strand, reached within 2 s; asserted > 3 cm) and a uniform `WindGrid` gives
     the same result bit for bit.
  3. Extreme: a one-particle strand follows its root; zero-length segments
     stay at the root, finite; a 100 m root jump paired with `teleport` keeps
     the shape (and without it the strand is still finite); no strands steps
     fine; 0 particles raises; two identical sets stay bit-identical.
"""

from std.math import isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.rigid6 import Pose6
from physics.fields import WindGrid
from physics.strand import StrandSet, StrandSphere

comptime DT: Real = 1.0 / 120.0
comptime G = Vec3(0, -9.8, 0, 0)


def _pose(p: Vec3, yaw: Real = 0) -> Pose6:
    return Pose6(p, Quat.from_axis_angle(Vec3(0, 1, 0, 0), yaw))


def _hang(bend: Real, secs: Real, drag: Real = 0.5) raises -> StrandSet:
    var ss = StrandSet(bend, drag)
    var bones: List[Pose6] = [_pose(Vec3(0, 2, 0, 0))]
    _ = ss.add(0, bones[0], Vec3(0, 0, 0, 0), Vec3(1, 0, 0, 0), 16, 0.05)
    for _ in range(Int(secs / DT)):
        ss.step(DT, G, bones)
    return ss^


def main() raises:
    var s = Suite("strand")

    # ---- free hang and bending --------------------------------------------------------------
    var free = _hang(0, 8, 2.0)
    var tip = free.tip(0)
    print("  free strand after 8 s: tip", tip[0], tip[1], tip[2], " max stretch", free.max_stretch())
    s.check(abs(tip[0]) < 2e-3 and abs(tip[1] - 1.25) < 2e-3 and free.max_stretch() < 1e-5, "free strand hangs straight, segments at rest length")
    var f2 = _hang(0, 1)
    var b2 = _hang(0.5, 1)
    var drop_free = 2 - f2.tip(0)[1]
    var drop_bend = 2 - b2.tip(0)[1]
    print("  tip drop after 1 s: bend 0", drop_free, " bend 0.5", drop_bend)
    s.check(drop_bend < 0.5 * drop_free, "bending stiffness holds the strand up")

    # ---- head turn: swing and settle --------------------------------------------------------
    var still = StrandSet(0.3)
    var still_bones: List[Pose6] = [_pose(Vec3(0, 1.7, 0, 0))]
    _ = still.add(0, still_bones[0], Vec3(0, 0.05, -0.1, 0), Vec3(0, -0.3, -1, 0), 16, 0.025)
    var still_v = Real(0)
    for k in range(1200):
        still.step(DT, G, still_bones)
        if k >= 1080:
            for i in range(len(still.v)):
                still_v = max(still_v, length(still.v[i]))
    print("  ponytail on a still head: largest particle speed in the tenth second", still_v)
    s.check(still_v < 0.01, "a strand on a still head comes to rest")
    var head = StrandSet(0.3)
    var bones: List[Pose6] = [_pose(Vec3(0, 1.7, 0, 0))]
    _ = head.add(0, bones[0], Vec3(0, 0.05, -0.1, 0), Vec3(0, -0.3, -1, 0), 16, 0.025)
    for _ in range(240):
        head.step(DT, G, bones)
    var turn = 24
    var peak = Real(0)
    var ref_set = StrandSet(0.3)
    var final_bones: List[Pose6] = [_pose(Vec3(0, 1.7, 0, 0), 1.5707963)]
    _ = ref_set.add(0, final_bones[0], Vec3(0, 0.05, -0.1, 0), Vec3(0, -0.3, -1, 0), 16, 0.025)
    for _ in range(2400):
        ref_set.step(DT, G, final_bones)
    var rest_tip = ref_set.tip(0)
    for k in range(720 + turn):
        var yaw = Real(1.5707963) * min(Real(1), Real(k) / Real(turn))
        bones[0] = _pose(Vec3(0, 1.7, 0, 0), yaw)
        head.step(DT, G, bones)
        if k >= turn:
            peak = max(peak, length(head.tip(0) - rest_tip))
    var settle = length(head.tip(0) - rest_tip)
    print("  head turn 90 deg in 0.2 s: tip swing peak", peak, " after 6 s", settle)
    s.check(peak > 0.05 and settle < 0.01, "ponytail swings out and settles to its rest shape on the turned head")

    # ---- collision ----------------------------------------------------------------------------
    var hair = StrandSet(0.05)
    hair.spheres.append(StrandSphere(Vec3(0, 0, 0, 0), 0.1))
    var hb: List[Pose6] = [_pose(Vec3(0, 0, 0, 0))]
    for k in range(32):
        var a = Real(k) * 0.19635
        var dirv = Vec3(1, 0.2, 0, 0)
        _ = hair.add(0, hb[0], Vec3(0, 0.1, 0, 0), Quat.from_axis_angle(Vec3(0, 1, 0, 0), a).rotate(dirv), 12, 0.02)
    for _ in range(360):
        hair.step(DT, G, hb)
    var worst = Real(1)
    for st in range(hair.strands()):
        for k in range(1, hair.count[st]):  # the root sits on the surface by construction
            worst = min(worst, length(hair.x[hair.start[st] + k]) - 0.1 - hair.radius)
    print("  32 strands draped over a 10 cm head: deepest particle", worst, " max stretch", hair.max_stretch())
    s.check(worst > -1e-4, "no particle inside the head sphere")

    # ---- wind ----------------------------------------------------------------------------------
    var w1 = StrandSet(0.1)
    var w2 = StrandSet(0.1)
    var wb: List[Pose6] = [_pose(Vec3(0, 2, 0, 0))]
    _ = w1.add(0, wb[0], Vec3(0, 0, 0, 0), Vec3(0, -1, 0, 0), 10, 0.05)
    _ = w2.add(0, wb[0], Vec3(0, 0, 0, 0), Vec3(0, -1, 0, 0), 10, 0.05)
    var grid = WindGrid(2, 2, 2, Vec3(-5, -5, -5, 0), 10, Vec3(5, 0, 0, 0))
    var wsame = True
    for _ in range(240):
        w1.step(DT, G, wb, Vec3(5, 0, 0, 0))
        w2.step_wind(DT, G, wb, grid)
        for i in range(len(w1.x)):
            if w1.x[i] != w2.x[i]:
                wsame = False
    print("  wind 5 m/s: tip x", w1.tip(0)[0])
    s.check(w1.tip(0)[0] > 0.03, "wind blows the tip downwind")
    s.check(wsame, "uniform WindGrid == constant wind, bit for bit")

    # ---- extremes ----------------------------------------------------------------------------------
    var one = StrandSet()
    var ob: List[Pose6] = [_pose(Vec3(1, 2, 3, 0))]
    _ = one.add(0, ob[0], Vec3(0, 0, 0, 0), Vec3(1, 0, 0, 0), 1, 0.1)
    ob[0] = _pose(Vec3(4, 5, 6, 0))
    one.step(DT, G, ob)
    s.check(one.x[0] == Vec3(4, 5, 6, 0), "one-particle strand follows its root")
    var zero = StrandSet()
    _ = zero.add(0, ob[0], Vec3(0, 0, 0, 0), Vec3(1, 0, 0, 0), 6, 0)
    for _ in range(60):
        zero.step(DT, G, ob)
    var at_root = True
    for i in range(len(zero.x)):
        if not isfinite(zero.x[i][1]) or length(zero.x[i] - Vec3(4, 5, 6, 0)) > 1e-5:
            at_root = False
    s.check(at_root, "zero-length segments stay at the root, finite")
    var jump = _hang(0.2, 1)
    var ctrl = _hang(0.2, 1)
    var cb: List[Pose6] = [_pose(Vec3(0, 2, 0, 0))]
    var jb: List[Pose6] = [_pose(Vec3(100, 2, 0, 0))]
    jump.teleport(0, Vec3(100, 0, 0, 0))
    jump.step(DT, G, jb)
    ctrl.step(DT, G, cb)
    var shape_diff = length((jump.tip(0) - jump.x[0]) - (ctrl.tip(0) - ctrl.x[0]))
    var raw = _hang(0.2, 1)
    raw.step(DT, G, jb)
    var finite = True
    for i in range(len(raw.v)):
        if not isfinite(raw.v[i][0]) or not isfinite(raw.x[i][0]):
            finite = False
    print("  100 m root jump: with teleport, shape differs from an unmoved twin by", shape_diff, "  without: tip v", raw.v[15][0])
    s.check(shape_diff < 1e-3 and finite, "teleport keeps the shape (f32 at 100 m); a raw jump stays finite")
    var none = StrandSet()
    none.step(DT, G, ob)
    s.check(none.strands() == 0, "no strands: step is a no-op")
    var raised = False
    try:
        _ = none.add(0, ob[0], Vec3(0, 0, 0, 0), Vec3(1, 0, 0, 0), 0, 0.1)
    except:
        raised = True
    s.check(raised, "0 particles raises")
    var d1 = _hang(0.3, 1)
    var d2 = _hang(0.3, 1)
    var det = True
    for i in range(len(d1.x)):
        if d1.x[i] != d2.x[i]:
            det = False
    s.check(det, "two identical strand sets are bit-identical")
    s.finish()
