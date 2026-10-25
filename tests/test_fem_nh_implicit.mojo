# tier: integration
"""Implicit stable Neo-Hookean FEM (ROADMAP 17.58,
`physics.fem_material.NhImplicitOp` / `step_implicit_nh`).

  1. Ordinary: the tangent is the derivative of the forces: on a deformed
     4 x 2 x 2 beam, K du matches the central difference of
     `material_forces[StableNeoHookean]` along du (relative 1e-2), and K is
     symmetric (u.K v == v.K u to 1e-4).
  2. Integration: a stiff cantilever (12 x 2 x 2 cells, E = 1e7) at
     dt = 1/60 for 20 s: implicit Neo-Hookean and implicit co-rotational
     reach the same sag within 1 % (the models agree at small strain);
     every solve converges (MINRES iterations printed). Measured: NH is at
     its final sag by 3.3 s (within 0.1 %), the co-rotational step is at
     65 % then and 99.7 % at 20 s -- its tangent freezes the element
     rotations. The explicit Neo-Hookean step at the same dt blows up.
  3. Extreme: an element pushed through itself (det F = -0.2) and released
     under the implicit step comes back (det F > 0); a solve capped at 1
     iteration is dropped (state unchanged) and counted.
"""

from std.math import sqrt, isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.fem import FemBody, make_beam, det3
from physics.fem_material import (
    StableNeoHookean, material_forces, step_material, deformation_gradient, NhImplicitOp, step_implicit_nh,
)
from diag.counters import CG_NOT_CONVERGED

comptime G = Vec3(0, -9.8, 0, 0)


def beam(young: Real, nx: Int) -> FemBody:
    var b = FemBody(young, 0.3, 6.0)
    make_beam(b, nx, 2, 2, 0.1, 0.05)
    for i in range(b.node_count()):
        if b.pos(i)[0] < 1e-6:
            b.pin(i)
    return b^


def tip_y(b: FemBody) -> Real:
    var y = Real(0)
    var n = b.node_count()
    for i in range(n - 9, n):
        y += b.y[i]
    return y / 9


def forces(b: FemBody) -> List[Real]:
    var n = b.node_count()
    var fx = List[Real](length=n, fill=0)
    var fy = List[Real](length=n, fill=0)
    var fz = List[Real](length=n, fill=0)
    material_forces[StableNeoHookean](b, fx, fy, fz)
    var out = List[Real](length=3 * n, fill=0)
    for i in range(n):
        out[3 * i] = fx[i]
        out[3 * i + 1] = fy[i]
        out[3 * i + 2] = fz[i]
    return out^


def shift(mut b: FemBody, du: List[Real], s: Real):
    for i in range(b.node_count()):
        b.x[i] += s * du[3 * i]
        b.y[i] += s * du[3 * i + 1]
        b.z[i] += s * du[3 * i + 2]


def main() raises:
    var st = Suite("fem_nh_implicit")
    var b = beam(5000, 4)
    var n = b.node_count()
    for i in range(n):  # a smooth bend plus a twist: well away from rest
        var x = b.x[i]
        b.y[i] -= 0.3 * x * x
        b.z[i] += 0.1 * x * (b.y[i] - 0.1)
    var du = List[Real](length=3 * n, fill=0)
    var dw = List[Real](length=3 * n, fill=0)
    for k in range(3 * n):
        du[k] = Real(((k * 37) % 11) - 5) * 0.1
        dw[k] = Real(((k * 13) % 7) - 3) * 0.1
    var op = NhImplicitOp(b, 1.0 / 60.0)
    var ku = List[Real](length=3 * n, fill=0)
    var kw = List[Real](length=3 * n, fill=0)
    op.stiffness_apply(du, ku)
    op.stiffness_apply(dw, kw)
    var eps = Real(1e-3)
    shift(b, du, eps)
    var fp = forces(b)
    shift(b, du, -2 * eps)
    var fm = forces(b)
    shift(b, du, eps)
    var worst = Real(0)
    var big = Real(0)
    for k in range(3 * n):
        var fd = (fp[k] - fm[k]) / (2 * eps)
        worst = max(worst, abs(fd - ku[k]))
        big = max(big, abs(ku[k]))
    var uk = Float64(0)
    var wk = Float64(0)
    for k in range(3 * n):
        uk += Float64(du[k]) * Float64(kw[k])
        wk += Float64(dw[k]) * Float64(ku[k])
    print("tangent: worst |K du - central difference| / max |K du|", worst / big, ";  u.K w", uk, " w.K u", wk)
    st.check(worst <= 1e-2 * big, "K du == central difference of the Neo-Hookean forces (1 %)")
    st.check(abs(uk - wk) <= 1e-4 * abs(uk), "K is symmetric")

    var nh = beam(1e7, 12)
    var co = beam(1e7, 12)
    var y0 = tip_y(nh)
    var conv = True
    var iters = 0
    var nh_early = Real(0)
    var co_early = Real(0)
    for k in range(1200):
        var r = step_implicit_nh(nh, 1.0 / 60.0, G, -1e30, 1e-4, 2000)
        conv = conv and r.converged
        iters = max(iters, r.iters)
        _ = co.step_implicit(1.0 / 60.0, G, -1e30, 1e-6, 400)
        if k == 199:
            nh_early = y0 - tip_y(nh)
            co_early = y0 - tip_y(co)
    var sag_nh = y0 - tip_y(nh)
    var sag_co = y0 - tip_y(co)
    var ex = beam(1e7, 12)
    for _ in range(60):
        step_material[StableNeoHookean](ex, 1.0 / 60.0, G)
    var ex_tip = tip_y(ex)
    print("E = 1e7 cantilever, dt 1/60: sag at 3.3 s NH", nh_early, " corotational", co_early, ";  at 20 s NH", sag_nh, " corotational", sag_co, ";  worst MINRES iterations", iters, " dropped", nh.counters.get(CG_NOT_CONVERGED), ";  explicit NH tip after 1 s", ex_tip)
    st.check(conv and abs(sag_nh / sag_co - 1) < 0.01, "implicit Neo-Hookean and co-rotational reach the same sag (1 %); every solve converges")
    st.check(abs(nh_early / sag_nh - 1) < 1e-3 and co_early < 0.8 * sag_co, "the exact tangent settles by 3.3 s; the co-rotational step (rotations frozen in its tangent) has not")
    st.check(not isfinite(ex_tip) or abs(ex_tip) > 10, "explicit Neo-Hookean at dt 1/60 blows up")

    var t = FemBody(2000.0, 0.3, 2.0)
    t.add_node(Vec3(0, 0, 0, 0), 1)
    t.add_node(Vec3(1, 0, 0, 0), 1)
    t.add_node(Vec3(0, 1, 0, 0), 1)
    t.add_node(Vec3(0, 0, 1, 0), 1)
    t.add_tet(0, 1, 2, 3)
    t.z[3] = -0.2
    for i in range(3):
        t.pin(i)
    var j0 = det3(deformation_gradient(t, 0))
    for _ in range(200):
        _ = step_implicit_nh(t, 1e-2, Vec3(0, 0, 0, 0))
    var j1 = det3(deformation_gradient(t, 0))
    var c = beam(5000, 4)
    for i in range(c.node_count()):
        c.y[i] -= 0.2 * c.x[i] * c.x[i]
    var before = c.y.copy()
    var r1 = step_implicit_nh(c, 1.0 / 60.0, G, -1e30, 1e-9, 1)
    var same = True
    for i in range(c.node_count()):
        same = same and c.y[i] == before[i]
    print("inverted element: det F", j0, "->", j1, ";  capped solve converged", r1.converged, " counter", c.counters.get(CG_NOT_CONVERGED))
    st.check(j0 < 0 and j1 > 0, "an inverted element recovers under the implicit step")
    st.check(not r1.converged and same and c.counters.get(CG_NOT_CONVERGED) == 1, "a non-converged solve is dropped and counted")
    st.finish()
