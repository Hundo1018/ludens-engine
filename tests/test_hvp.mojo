# tier: integration
"""Hessian-vector products by forward-over-reverse AD (ROADMAP 17.84,
`geometry.field.RevDual` / `DualTape` / `hvp_seed`).

  1. Ordinary: Rosenbrock f = (1 - x)^2 + 100 (y - x^2)^2 at (-1.2, 1):
     one sweep gives the gradient (equal to `RevReal`'s) and H v, which
     matches the analytic Hessian [[1200 x^2 - 400 y + 2, -400 x],
     [-400 x, 200]] for v = e1, e2 and (0.3, -0.7) (relative 1e-5).
  2. Integration: through the GA motor sandwich (`GMV[3, 0, 1, RevDual]`,
     loss x'^3 of a point moved by a translator times a rational rotor),
     H v matches the central difference of two `RevReal` gradients
     (h = 1e-2, 1 %). Through `SphereWorld` (sphere A launched at an
     off-centre sphere B, loss = B's z after 0.5 s, as a function of
     (vx0, z offset)): the gradient equals `RevReal`'s to 1e-5 of its norm
     (5e-8 measured: f32 rounding differs between the dual and plain
     tape arithmetic over 30 frames) and H is symmetric,
     w^T (H v) == v^T (H w) to 1e-4. A difference check is not possible
     there: the difference of gradients does not converge as h shrinks
     (printed) -- the sharp solver's f32 gradient is piecewise in the
     contact schedule and noisy within it, so H v is the Hessian of the
     branch the primal took, not a derivative of the gradient field.
  3. Extreme: a linear f has H v = 0 exactly; an output that never touched
     a seeded input (a constant) has zero gradient and zero H v.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.field import SolverField, RevReal, Tape, rev_seed, RevDual, DualTape, hvp_seed
from geometry.gmv import GMV
from physics.diffsolver import SphereWorld, V3

comptime DT: Real = 1.0 / 60.0


def rosen[F: SolverField](x: F, y: F) -> F:
    var a = F.const(1) - x
    var b = y - x * x
    return a * a + F.const(100) * b * b


def motor[F: SolverField](s: F, d: F) -> F:
    """The cube x'^3 of the PGA point (2, 0, 0) after the motor T(d e1) R(s), with
    R = (1 + s e12) / sqrt(1 + s^2) (no trig: root and recip)."""
    comptime E123 = 0b0111
    comptime T230 = 0b1110
    comptime B10 = 0b1001
    comptime B12 = 0b0011
    var nrm = (F.const(1) + s * s).root().recip()
    var r = GMV[3, 0, 1, F]()
    r.c[0] = nrm
    r.c[B12] = s * nrm
    var tr = GMV[3, 0, 1, F]()
    tr.c[0] = F.const(1)
    tr.c[B10] = d * F.const(0.5)
    var m = tr * r
    var pt = GMV[3, 0, 1, F]()
    pt.c[E123] = F.const(1)
    pt.c[T230] = F.const(-2)
    var moved = m * pt * m.reverse()
    var x = F.zero() - moved.c[T230]
    return x * x * x


def collide[F: SolverField](vx0: F, zoff: F) -> F:
    var w = SphereWorld[F]()
    w.mu = F.const(0.3)
    _ = w.add_plane(Vec3(0, 1, 0, 0), 0)
    _ = w.add_sphere(V3[F](F.zero(), F.const(0.5), F.zero()), V3[F](vx0, F.zero(), F.zero()), F.const(0.5), F.const(1))
    _ = w.add_sphere(V3[F](F.const(1.5), F.const(0.5), zoff), V3[F](F.zero(), F.zero(), F.zero()), F.const(0.5), F.const(1))
    for _ in range(30):
        w.step(DT)
    return w.bodies[1].pos.z


def grad2(p: Tuple[Real, Real], which: Int) -> Tuple[Real, Real]:
    var t = Tape()
    var a = rev_seed(t, p[0])
    var b = rev_seed(t, p[1])
    var f = rosen(a, b) if which == 0 else (motor(a, b) if which == 1 else collide(a, b))
    var g = t.grad(f.idx)
    return (g[a.idx], g[b.idx])


def hvp2(p: Tuple[Real, Real], v: Tuple[Real, Real], which: Int) -> Tuple[Real, Real, Real, Real]:
    """(g0, g1, (Hv)0, (Hv)1)."""
    var t = DualTape()
    var a = hvp_seed(t, p[0], v[0])
    var b = hvp_seed(t, p[1], v[1])
    var f = rosen(a, b) if which == 0 else (motor(a, b) if which == 1 else collide(a, b))
    var g = t.grad(f.idx)
    return (g[a.idx].a, g[b.idx].a, g[a.idx].b, g[b.idx].b)


def rel(got: Real, want: Real) -> Real:
    return abs(got - want) / max(abs(want), 1e-6)


def main() raises:
    var s = Suite("hvp")
    var p = (Real(-1.2), Real(1.0))
    var h00 = 1200 * p[0] * p[0] - 400 * p[1] + 2
    var h01 = -400 * p[0]
    var h11 = Real(200)
    var g = grad2(p, 0)
    var ok = True
    var worst = Real(0)
    for v in [(Real(1), Real(0)), (Real(0), Real(1)), (Real(0.3), Real(-0.7))]:
        var r = hvp2(p, v, 0)
        var w0 = h00 * v[0] + h01 * v[1]
        var w1 = h01 * v[0] + h11 * v[1]
        worst = max(worst, max(rel(r[2], w0), rel(r[3], w1)))
        ok = ok and r[0] == g[0] and r[1] == g[1]
    print("Rosenbrock: H v worst relative error", worst, " gradient", g[0], g[1])
    s.check(ok and worst < 1e-5, "Rosenbrock: gradient == RevReal's, H v == analytic Hessian times v")

    var q = (Real(0.4), Real(0.3))
    var v = (Real(0.6), Real(-0.8))
    var hv = hvp2(q, v, 1)
    var h = Real(1e-2)
    var gp = grad2((q[0] + h * v[0], q[1] + h * v[1]), 1)
    var gm = grad2((q[0] - h * v[0], q[1] - h * v[1]), 1)
    var fd0 = (gp[0] - gm[0]) / (2 * h)
    var fd1 = (gp[1] - gm[1]) / (2 * h)
    print("GA motor x'^3: H v", hv[2], hv[3], " central difference of RevReal gradients", fd0, fd1)
    s.check(rel(hv[2], fd0) < 0.01 and rel(hv[3], fd1) < 0.01, "GA motor sandwich (GMV[3,0,1,RevDual]): H v matches the central difference of gradients (1 %)")

    # contact scene: exact AD of one branch schedule is symmetric; the f32
    # gradient of the sharp solver is not smooth enough for a difference check
    var c = (Real(3), Real(0.3))
    var w = (Real(0.28), Real(0.96))
    var cv = hvp2(c, v, 2)
    var cw = hvp2(c, w, 2)
    var sym_a = w[0] * cv[2] + w[1] * cv[3]
    var sym_b = v[0] * cw[2] + v[1] * cw[3]
    var gc = grad2(c, 2)
    var spread = String()
    for hh in [Real(1e-1), Real(1e-2), Real(1e-3)]:
        var p1 = grad2((c[0] + hh * v[0], c[1] + hh * v[1]), 2)
        var m1 = grad2((c[0] - hh * v[0], c[1] - hh * v[1]), 2)
        spread += " h=" + String(hh) + ": " + String((p1[0] - m1[0]) / (2 * hh))
    print("sphere collision: gradient", cv[0], cv[1], "RevReal", gc[0], gc[1], " H v", cv[2], cv[3], " w.Hv", sym_a, " v.Hw", sym_b, ";  difference of gradients (first entry)", spread)
    var gn = max(abs(gc[0]), abs(gc[1]))
    s.check(abs(cv[0] - gc[0]) <= 1e-5 * gn and abs(cv[1] - gc[1]) <= 1e-5 * gn and abs(sym_a - sym_b) <= 1e-4 * max(abs(sym_a), 1e-3), "SphereWorld collision: gradient == RevReal's, H symmetric")

    var t = DualTape()
    var a = hvp_seed(t, 2, 1)
    var b = hvp_seed(t, -1, 1)
    var lin = RevDual.const(3) * a - b * RevDual.const(2) + RevDual.const(5)
    var gl = t.grad(lin.idx)
    var cst = RevDual.const(4) * RevDual.const(2)
    var g0 = t.grad(cst.idx)
    s.check(gl[a.idx].a == 3 and gl[b.idx].a == -2 and gl[a.idx].b == 0 and gl[b.idx].b == 0 and g0[a.idx].a == 0 and g0[b.idx].b == 0, "linear f: H v = 0; constant output: zero gradient and H v")
    s.finish()
