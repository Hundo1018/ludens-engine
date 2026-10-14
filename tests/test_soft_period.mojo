# tier: integration
"""Per-object period for soft bodies (ROADMAP 17.85,
`ContactScene6.set_soft_period`).

  1. Ordinary: a soft lattice falling 1 m onto a static box: with period 1
     it is bit for bit the default; with period 4 it runs one step in four
     over 4 dt and comes to rest within 1 cm of the period-1 rest height,
     after the same simulated time.
  2. Integration: two lattices side by side, one at period 4, phase 1:
     it moves on 15 of the first 60 steps; a snapshot after 60 steps
     restores period and phase and the next 60 steps match the
     uninterrupted run bit for bit (both lattices).
  3. Extreme: index out of range, period 0 and a negative phase raise.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.softbody import SoftBody
from physics.serialize import scene_to_bytes, scene_from_bytes

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _scene(n_soft: Int) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 5, 0.5, 5)), Vec3(5, 0.5, 5, 0), True)
    for k in range(n_soft):
        _ = sc.add_soft(SoftBody.box_lattice(Vec3(Real(k) * 1.5, 1.2, 0, 0), Vec3(0.2, 0.2, 0.2, 0), 4, 1, 1e-4))
    return sc^


def _bottom(sc: ContactScene6[QuatBody6], s: Int) -> Real:
    var lo = Real(1e9)
    for p in sc.softs[s].pts:
        lo = min(lo, p.x[1])
    return lo


def main() raises:
    var s = Suite("soft_period")
    var a = _scene(1)
    var b = _scene(1)
    var c = _scene(1)
    b.set_soft_period(0, 1)
    c.set_soft_period(0, 4)
    for _ in range(240):
        a.step_soft(DT, G)
        b.step_soft(DT, G)
        c.step_soft(DT, G)
    var same = True
    for i in range(len(a.softs[0].pts)):
        var p = a.softs[0].pts[i].x
        var q = b.softs[0].pts[i].x
        if p[0] != q[0] or p[1] != q[1] or p[2] != q[2]:
            same = False
    print("  lattice on a box, 4 s: lowest particle  period 1", _bottom(a, 0), " period 4", _bottom(c, 0))
    s.check(same, "period 1 is the default, bit for bit")
    s.check(abs(_bottom(a, 0) - _bottom(c, 0)) < 0.01, "period 4 rests within 1 cm of period 1")

    var m = _scene(2)
    m.set_soft_period(1, 4, 1)
    var y0 = m.softs[1].pts[0].x[1]
    var moved = 0
    for k in range(120):
        var before = m.softs[1].pts[0].x[1]
        m.step_soft(DT, G)
        if m.softs[1].pts[0].x[1] != before:
            moved += 1
        if k == 59:
            var back = scene_from_bytes(scene_to_bytes(m))
            var m2 = back^
            for _ in range(60):
                m2.step_soft(DT, G)
            m = scene_from_bytes(scene_to_bytes(m2))
            break
    var r1 = _scene(2)
    r1.set_soft_period(1, 4, 1)
    for _ in range(120):
        r1.step_soft(DT, G)
    var bits = True
    for t in range(2):
        for i in range(len(r1.softs[t].pts)):
            if r1.softs[t].pts[i].x[1] != m.softs[t].pts[i].x[1]:
                bits = False
    print("  period 4 phase 1: the lattice moved on", moved, "of the first 60 steps (start y", y0, ")")
    s.check(moved == 15, "period 4 runs one step in four")
    s.check(bits and m.softs[1].period == 4 and m.softs[1].phase == 1, "snapshot mid-run keeps period and phase, bit for bit")

    var raised = 0
    var e = _scene(1)
    try:
        e.set_soft_period(3, 2)
    except:
        raised += 1
    try:
        e.set_soft_period(0, 0)
    except:
        raised += 1
    try:
        e.set_soft_period(0, 2, -1)
    except:
        raised += 1
    s.check(raised == 3, "bad index, period 0, negative phase raise")
    s.finish()
