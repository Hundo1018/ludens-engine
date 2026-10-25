# tier: integration
"""Kinematic pins from skinning on volumetric bodies (ROADMAP 17.65,
`gameplay.skin_link`, `physics.softbody`).

  1. SoftBody: a 3^3 lattice (0.4 m, 1 kg) with its top layer pinned to
     fixed skinned targets for 60 steps of 1/60 s: after every step the
     pinned particles sit exactly on their targets (before 17.65 they
     ended 6.9e-5 m low: `predict` applied gravity to inverse mass 0);
     `momentum()` is finite and equals the sum of m v over the dynamic
     particles (it divided by the zero inverse mass: nan / -inf).
     A pinned particle given no velocity stays put under gravity.
  2. FEM: a 0.4 x 0.1 x 0.1 m beam (4 x 1 x 1 cells, E 2e4, 1 ms steps)
     with its x = 0 face pinned (`pin_fem_to_skin`) to a bone turning
     45 degrees about z over 1 s: the pinned nodes equal the skinned
     targets after every step and the free end follows the turn (tip
     direction printed against 45 degrees), everything finite.
"""

from std.math import sqrt, atan2, isfinite, cos, sin, pi
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from physics.softbody import SoftBody
from physics.fem import FemBody, make_beam
from gameplay.skin_link import pin_softbody_to_skin, pin_fem_to_skin

comptime G = Vec3(0, -9.8, 0, 0)


def main() raises:
    var s = Suite("skin_pin")

    # 1. soft body on fixed pins
    var b = SoftBody.box_lattice(Vec3(0, 1, 0, 0), Vec3(0.2, 0.2, 0.2, 0), 3, 1.0, 1e-4)
    var top = List[Int]()
    var sv = List[Int]()
    var target = List[Vec3]()
    for i in range(len(b.pts)):
        if b.pts[i].x[1] > 1.19:
            sv.append(len(top))
            top.append(i)
            target.append(b.pts[i].x)
    var worst = Real(0)
    for _ in range(60):
        pin_softbody_to_skin(b, top, sv, target, 1.0 / 60)
        b.advance(1.0 / 60, G)
        for k in range(len(top)):
            worst = max(worst, length(b.pts[top[k]].x - target[k]))
    var p = b.momentum()
    var manual = Vec3(0, 0, 0, 0)
    for q in b.pts:
        if q.w != 0:
            manual = manual + q.v * (1 / q.w)
    print("  soft body: 9 pins, 60 steps: worst pin offset after a step", worst, " momentum y", p[1])
    s.check(worst == 0, "pinned particles exactly on their targets after every step")
    s.check(isfinite(p[0]) and isfinite(p[1]) and isfinite(p[2]) and length(p - manual) <= 1e-6 * (length(manual) + 1), "momentum finite, = sum of m v over dynamic particles")
    var still = SoftBody.box_lattice(Vec3(0, 1, 0, 0), Vec3(0.2, 0.2, 0.2, 0), 3, 1.0, 1e-4)
    still.pts[0].w = 0
    var x0 = still.pts[0].x
    for _ in range(30):
        still.advance(1.0 / 60, G)
    s.check(still.pts[0].x[1] == x0[1], "a pinned particle with no velocity stays put under gravity")

    # 2. FEM beam riding a turning bone
    var fb = FemBody(young=20000.0, poisson=0.3)
    make_beam(fb, 4, 1, 1, 0.1, 0.01)
    var nodes = List[Int]()
    var rest = List[Vec3]()
    var fsv = List[Int]()
    for i in range(fb.node_count()):
        if fb.x[i] < 1e-6:
            fsv.append(len(nodes))
            nodes.append(i)
            rest.append(fb.pos(i))
    var tip = -1
    for i in range(fb.node_count()):
        if fb.x[i] > 0.39 and fb.y[i] < 1e-6 and fb.z[i] < 1e-6:
            tip = i
    var dt = Real(1e-3)
    var fworst = Real(0)
    var finite = True
    var steps = 1000
    for k in range(steps):
        var ang = Real(pi / 4) * Real(k + 1) / Real(steps)
        var c = cos(ang)
        var sn = sin(ang)
        var skinned = List[Vec3]()
        for r in rest:
            skinned.append(Vec3(c * r[0] - sn * r[1], sn * r[0] + c * r[1], r[2], 0))
        pin_fem_to_skin(fb, nodes, fsv, skinned)
        fb.step(dt, G)
        for q in range(len(nodes)):
            fworst = max(fworst, length(fb.pos(nodes[q]) - skinned[q]))
        for i in range(fb.node_count()):
            finite = finite and isfinite(fb.x[i]) and isfinite(fb.y[i]) and isfinite(fb.z[i])
    var tip_deg = atan2(fb.y[tip], fb.x[tip]) * 180 / Real(pi)
    print("  FEM beam: worst pinned-node offset", fworst, " tip direction", tip_deg, "deg (bone 45, gravity sags it)")
    s.check(fworst == 0, "pinned FEM nodes equal the skinned targets after every step")
    s.check(finite and tip_deg > 30 and tip_deg < 50, "the free end follows the turn (30..50 deg), finite")
    var raised = False
    try:
        var bad: List[Int] = [0]
        var none = List[Int]()
        pin_fem_to_skin(fb, bad, none, rest)
    except:
        raised = True
    s.check(raised, "mismatched node / vertex lists raise")
    s.finish()
