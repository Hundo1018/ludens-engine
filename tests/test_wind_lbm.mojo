# tier: integration
"""LBM wind into a WindGrid (ROADMAP 17.61, `WindGrid.from_lbm`).

  1. Uniform lattice flow: every node holds the lattice velocity times the
     unit scale, and `sample` returns that constant anywhere in the grid.
  2. Driven periodic channel after 200 steps: the node velocities equal the
     lattice velocities times the scale, cell for cell (the mean of the nodes
     is the lattice mean), and the flow has developed in +x.
  3. Node placement: node (i, j, k) sits at origin + (i, j, k) * cell, so
     sampling there returns the node value exactly.
"""

from harness.runner import Suite
from fluid.lbm import Lbm
from geometry.vec import Real, Vec3
from physics.fields import WindGrid


def main() raises:
    var s = Suite("wind_lbm")

    # ---- uniform flow -----------------------------------------------------------------------
    var still = Lbm(8, 8, 8, 0.05)
    still.init_uniform(1.0, 0.02, 0.0, 0.0)
    var g0 = WindGrid.from_lbm(still, Vec3(0, 0, 0, 0), 0.5, 5.0)
    var worst = Real(0)
    for c in range(still.cells()):
        var v = g0.vel[c]
        worst = max(worst, abs(v[0] - 0.1) + abs(v[1]) + abs(v[2]))
    print("  uniform lattice flow 0.02 at 5 m/s per unit: worst node error", worst)
    s.check(worst < 1e-5, "every node holds the lattice velocity times the scale")
    var mid = g0.sample(Vec3(1.7, 2.2, 0.9, 0))
    s.almost(Float64(mid[0]), 0.1, "sample of a uniform grid is the constant", tol=1e-5)

    # ---- driven channel ---------------------------------------------------------------------
    var ch = Lbm(8, 8, 8, 0.05)
    ch.init_uniform(1.0, 0.0, 0.0, 0.0)
    ch.force_x = 1e-4
    for _ in range(200):
        ch.step()
    var g = WindGrid.from_lbm(ch, Vec3(0, 0, 0, 0), 0.5, 5.0)
    var lat_sum = Vec3(0, 0, 0, 0)
    var node_sum = Vec3(0, 0, 0, 0)
    var mismatch = Real(0)
    for c in range(ch.cells()):
        var lv = ch.velocity(c)
        lat_sum = lat_sum + lv
        node_sum = node_sum + g.vel[c]
        mismatch = max(mismatch, abs(g.vel[c][0] - lv[0] * 5.0) + abs(g.vel[c][1] - lv[1] * 5.0))
    print("  driven channel after 200 steps: mean ux (m/s)", node_sum[0] / Real(ch.cells()), " max node mismatch", mismatch)
    s.check(mismatch < 1e-6, "node values match the lattice cell by cell")
    var n = Real(ch.cells())
    s.almost(Float64(node_sum[0] / n), Float64(lat_sum[0] * 5.0 / n), "node mean equals the lattice mean times the scale", tol=1e-6)
    s.check(node_sum[0] > 0, "the body force drives the flow in +x")

    # ---- node placement ---------------------------------------------------------------------
    var shifted = WindGrid.from_lbm(ch, Vec3(10, -2, 3, 0), 0.5, 5.0)
    var p = Vec3(10, -2, 3, 0) + Vec3(2, 5, 7, 0) * 0.5
    var at_node = shifted.at(2, 5, 7)
    var at_sample = shifted.sample(p)
    print("  node (2, 5, 7) at", p[0], p[1], p[2], " sample ux", at_sample[0], " node ux", at_node[0])
    s.almost(Float64(at_sample[0]), Float64(at_node[0]), "sampling a node position returns that node", tol=1e-6)
    s.almost(Float64(at_sample[1]), Float64(at_node[1]), "sampling a node position returns that node (y)", tol=1e-6)
    s.finish()
