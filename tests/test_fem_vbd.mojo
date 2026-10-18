# tier: integration
"""Vertex Block Descent for stable Neo-Hookean FEM (ROADMAP 17.58,
`physics.fem_material.step_vbd_nh`), a solver variant of the implicit step.

  1. Ordinary (descent): on a bent 4 x 1 x 1 beam, the backward-Euler
     objective G(x) = sum m / (2 dt^2) |x - y|^2 + E(x) after k = 1, 2, 4,
     8, 16, 32 sweeps never increases, and its last decrease is under
     1e-4 of the first.
  2. Integration (parity): a soft cantilever (12 x 2 x 2, E = 1e5, dt 1/60)
     settles, after 2 s, to a sag that approaches `step_implicit_nh`'s as
     the sweep count grows (10, 40, 160: errors printed, decreasing), within
     3 % at 160.
  3. Extreme: pinned nodes do not move; the measured limitation is
     printed in the ROADMAP (a stiff E = 1e7 cantilever is 24x too soft at
     160 sweeps: vertex Gauss-Seidel carries information one element per
     sweep).
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.mat import Mat3
from physics.fem import FemBody, make_beam, det3
from physics.fem_material import step_vbd_nh, step_implicit_nh, deformation_gradient

comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 60.0


def beam(nx: Int, ny: Int, young: Real) -> FemBody:
    var b = FemBody(young, 0.3, 6.0)
    make_beam(b, nx, ny, ny, 0.1, 0.05)
    for i in range(b.node_count()):
        if b.x[i] < 1e-6:
            b.pin(i)
    return b^


def tip(b: FemBody) -> Real:
    var y = Real(0)
    var n = b.node_count()
    for i in range(n - 9, n):
        y += b.y[i]
    return y / 9


def objective(b: FemBody, tx: List[Real], ty: List[Real], tz: List[Real]) -> Float64:
    var g = Float64(0)
    for i in range(b.node_count()):
        if b.inv_m[i] == 0:
            continue
        var m = Float64(1) / Float64(b.inv_m[i])
        var dx = Float64(b.x[i] - tx[i])
        var dy = Float64(b.y[i] - ty[i])
        var dz = Float64(b.z[i] - tz[i])
        g += m / (2 * Float64(DT) * Float64(DT)) * (dx * dx + dy * dy + dz * dz)
    var lam_s = Float64(b.lam + b.mu)
    var alpha = 1 + Float64(b.mu) / lam_s
    for e in range(len(b.tets)):
        var f = deformation_gradient(b, e)
        var ic = Float64(0)
        for p in range(3):
            for q in range(3):
                ic += Float64(f.get(p, q)) * Float64(f.get(p, q))
        var j = Float64(det3(f))
        g += Float64(b.tets[e].vol) * (Float64(b.mu) / 2 * (ic - 3) + lam_s / 2 * (j - alpha) * (j - alpha))
    return g


def main() raises:
    var s = Suite("fem_vbd")
    var base = beam(4, 1, 1e4)
    for i in range(base.node_count()):
        base.y[i] -= 0.4 * base.x[i] * base.x[i]
    var tx = List[Real]()
    var ty = List[Real]()
    var tz = List[Real]()
    for i in range(base.node_count()):
        tx.append(base.x[i] + DT * DT * G[0])
        ty.append(base.y[i] + DT * DT * G[1])
        tz.append(base.z[i] + DT * DT * G[2])
    var gs = List[Float64]()
    for k in [1, 2, 4, 8, 16, 32]:
        var b = beam(4, 1, 1e4)
        for i in range(b.node_count()):
            b.y[i] -= 0.4 * b.x[i] * b.x[i]
        step_vbd_nh(b, DT, G, k)
        gs.append(objective(b, tx, ty, tz))
    var mono = True
    for q in range(1, len(gs)):
        mono = mono and gs[q] <= gs[q - 1] * (1 + 1e-6)
    print("objective after 1, 2, 4, 8, 16, 32 sweeps:", gs[0], gs[1], gs[2], gs[3], gs[4], gs[5])
    s.check(mono and (gs[4] - gs[5]) < 1e-4 * (gs[0] - gs[1]), "each sweep lowers the backward-Euler objective; it levels off")

    var r = beam(12, 2, 1e5)
    var y0 = tip(r)
    for _ in range(120):
        _ = step_implicit_nh(r, DT, G, -1e30, 1e-4, 4000)
    var want = y0 - tip(r)
    var errs = List[Real]()
    var pinned_still = True
    for it in [10, 40, 160]:
        var b = beam(12, 2, 1e5)
        var px = b.x[0]
        for _ in range(120):
            step_vbd_nh(b, DT, G, it)
        pinned_still = pinned_still and b.x[0] == px and b.vx[0] == 0
        errs.append(abs((y0 - tip(b)) / want - 1))
    print("E 1e5 cantilever after 2 s: implicit NH sag", want, ";  VBD relative error at 10 / 40 / 160 sweeps", errs[0], errs[1], errs[2])
    s.check(errs[0] > errs[1] and errs[1] > errs[2] and errs[2] < 0.03, "VBD approaches the implicit Neo-Hookean sag as sweeps grow (3 % at 160)")
    s.check(pinned_still, "pinned nodes do not move")
    s.finish()
