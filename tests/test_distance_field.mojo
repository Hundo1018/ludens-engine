# tier: integration
"""One distance-field interface for analytic and sampled SDFs (ROADMAP 17.52).

`Sdf3` (analytic, CSG) and `SdfGrid` (trilinear lattice) both implement
`geometry.distance_field.DistanceField3`; `sphere_trace` and
`SdfGrid.from_field` are written once against it.

  1. Ordinary: tracing a unit sphere from 5 m out hits at t = 4 on the
     analytic field and on a 41^3 grid sampled from it (within 1e-3); the
     grid's distance at 300 random points stays within one cell of the
     analytic one.
  2. Integration: a CSG field (box minus sphere) traced through its hole
     reaches the far wall on both representations; the solver's SDF shape
     built by `from_field` from an analytic plane holds a box at the same
     rest height as the hand-filled plane grid of `test_sdf_shape`
     (bit-identical node values, so bit-identical rest height).
  3. Extreme: a ray pointing away misses on both; a ray starting inside
     reports `inside` at t = 0.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, dot
from geometry.sdf3 import Sdf3, OP_SUBTRACT
from geometry.sdf_grid import SdfGrid
from geometry.distance_field import sphere_trace
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


struct _Rng:
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed

    def next(mut self) -> Real:
        self.s = self.s * 6364136223846793005 + 1442695040888963407
        return Real(Float64((self.s >> 11) & 0xFFFFFFFF) / 4294967296.0) * 2 - 1


def _rest(var g: SdfGrid) raises -> Real:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add_sdf(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), g^)
    var b = sc.add(QuatBody6.at_rest(Vec3(0.13, 0.3, -0.21, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    sc.set_can_sleep(b, False)
    for _ in range(120):
        sc.step_soft(DT, G)
    return sc.pose(b).pos[1]


def main() raises:
    var s = Suite("distance_field")
    var z = Vec3(0, 0, 1, 0)

    # ---- sphere: analytic vs sampled --------------------------------------
    var ball = Sdf3.sphere(Vec3(0, 0, 0, 0), 1)
    var cell = Real(4) / 40
    var grid = SdfGrid.from_field(ball, 41, Vec3(-2, -2, -2, 0), cell)
    var ta = sphere_trace(ball, Vec3(0, 0, -5, 0), z, 20, 1e-5, 1.0)
    var tg = sphere_trace(grid, Vec3(0, 0, -5, 0), z, 20, 1e-5, 0.9)
    print("  unit sphere from 5 m: analytic t", ta.t, "(", ta.steps, "steps )  41^3 grid t", tg.t, "(", tg.steps, "steps )")
    s.check(ta.hit and abs(ta.t - 4) < 1e-4, "analytic trace hits at t = 4")
    s.check(tg.hit and abs(tg.t - 4) < 1e-3, "grid trace hits at t = 4 (1e-3)")
    var rng = _Rng(3)
    var worst = Real(0)
    for _ in range(300):
        var p = Vec3(rng.next() * 1.8, rng.next() * 1.8, rng.next() * 1.8, 0)
        worst = max(worst, abs(grid.distance(p) - ball.distance(p)))
    print("  300 points: worst |grid - analytic|", worst, " cell", cell)
    s.check(worst < cell, "sampled distance within one cell of the analytic one")

    # ---- CSG through a hole --------------------------------------------------
    var block = Sdf3.box(Vec3(0, 0, 0, 0), Vec3(1, 1, 1, 0))
    var hollow = block.combined(OP_SUBTRACT, Sdf3.sphere(Vec3(0, 0, 0, 0), 0.6))
    var cg = SdfGrid.from_field(hollow, 61, Vec3(-1.5, -1.5, -1.5, 0), Real(3) / 60)
    # from inside the cavity toward +z: the cavity wall at z = 0.6
    var ca = sphere_trace(hollow, Vec3(0, 0, 0, 0), z, 5, 1e-5, 1.0)
    var cgt = sphere_trace(cg, Vec3(0, 0, 0, 0), z, 5, 1e-5, 0.9)
    print("  box minus sphere, from the cavity centre: analytic t", ca.t, " grid t", cgt.t)
    s.check(ca.hit and abs(ca.t - 0.6) < 1e-4 and cgt.hit and abs(cgt.t - 0.6) < 0.05, "CSG cavity wall at t = 0.6 on both")

    # ---- solver: analytic plane sampled into the SDF shape -------------------
    var res = 13
    var org = Vec3(-6, -6, -6, 0)
    var cl = Real(12) / Real(res - 1)
    var hand = SdfGrid(res, org, cl)
    for k in range(res):
        for j in range(res):
            for i in range(res):
                hand.values[(k * res + j) * res + i] = hand.node(i, j, k)[1]
    var baked = SdfGrid.from_field(Sdf3.plane(Vec3(0, 1, 0, 0), 0), res, org, cl)
    var same_nodes = True
    for n in range(len(hand.values)):
        if hand.values[n] != baked.values[n]:
            same_nodes = False
    var y_hand = _rest(hand^)
    var y_baked = _rest(baked^)
    print("  box on the plane SDF: hand-filled y", y_hand, " from_field(Sdf3.plane) y", y_baked)
    s.check(same_nodes, "from_field(Sdf3.plane) node values equal the hand-filled grid")
    s.check(y_hand == y_baked, "same rest height, bit for bit")

    # ---- extremes ---------------------------------------------------------------
    var ma = sphere_trace(ball, Vec3(0, 0, -5, 0), -z, 20, 1e-5, 1.0)
    var mg = sphere_trace(grid, Vec3(0, 0, -5, 0), -z, 20, 1e-5, 0.9)
    s.check(not ma.hit and not mg.hit, "ray pointing away misses on both")
    var ia = sphere_trace(ball, Vec3(0, 0, 0, 0), z, 20, 1e-5, 1.0)
    var ig = sphere_trace(grid, Vec3(0, 0, 0, 0), z, 20, 1e-5, 0.9)
    s.check(ia.inside and ia.t == 0 and ig.inside and ig.t == 0, "ray starting inside: inside at t = 0")
    s.finish()
