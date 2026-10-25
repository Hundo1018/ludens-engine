# tier: integration
"""Near-incompressible FEM (ROADMAP 17.58, `nh_forces_averaged`: stable
Neo-Hookean with the averaged-nodal-pressure volumetric term, against the
per-element `StableNeoHookean`).

  1. Ordinary (patch test): a 3 x 3 x 3-cell cube on rollers compressed 1 %
     (affine field): both variants give F / (E eps A) within 2 % of 1 and a
     lateral / axial strain ratio within 2 % of nu, at nu = 0.499.
  2. Integration (Lame): a quarter thick-walled cylinder (a = 0.5, b = 1,
     plane strain by z rollers, symmetry rollers on x = 0 and y = 0) under
     internal pressure p / E = 5e-4: u(a) within 10 % of Lame's
     p a^2 (1 + nu) ((1 - 2 nu) a + b^2 / a) / (E (b^2 - a^2)) at nu = 0.3
     and 0.499 for both variants. Measured: no volumetric locking on these
     5-tet structured meshes (0.499 is no stiffer than 0.3); averaging
     changes u(a) by < 3 %.
  3. Extreme (bending): a 12 x 2 x 2 cantilever (E = 1e6, nu = 0.3) under
     gravity: averaging makes the linear tets' bending softer, closer to
     Euler-Bernoulli (tip sags printed with the beam-theory value); the
     two variants are equal at rest (no load, no motion).
"""

from std.math import cos, sin, sqrt, pi
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.fem import FemBody, make_beam
from physics.fem_material import StableNeoHookean, material_forces, step_material, nh_forces_averaged, step_nh_averaged

comptime ZERO = Vec3(0, 0, 0, 0)


def forces(b: FemBody, avg: Bool) -> Tuple[List[Real], List[Real], List[Real]]:
    var n = b.node_count()
    var fx = List[Real](length=n, fill=0)
    var fy = List[Real](length=n, fill=0)
    var fz = List[Real](length=n, fill=0)
    if avg:
        nh_forces_averaged(b, fx, fy, fz)
    else:
        material_forces[StableNeoHookean](b, fx, fy, fz)
    return (fx^, fy^, fz^)


def patch(nu: Real, avg: Bool) -> Tuple[Real, Real]:
    comptime M = 3
    comptime H: Real = 0.1
    var b = FemBody(1e5, nu, 30.0)
    make_beam(b, M, M, M, H, 0.05)
    var n = b.node_count()
    var L = Real(M) * H
    var eps = Real(0.01)
    var bottom = List[Bool]()
    var top = List[Bool]()
    for i in range(n):
        bottom.append(b.y[i] < 1e-6)
        top.append(b.y[i] > L - 1e-6)
    for _ in range(40000):
        if avg:
            step_nh_averaged(b, 2e-5, ZERO)
        else:
            step_material[StableNeoHookean](b, 2e-5, ZERO)
        for i in range(n):
            if bottom[i]:
                b.y[i] = 0
                b.vy[i] = 0
            if top[i]:
                b.y[i] = L * (1 - eps)
                b.vy[i] = 0
        b.x[0] = 0
        b.z[0] = 0
        b.vx[0] = 0
        b.vz[0] = 0
    var f = forces(b, avg)
    var react = Real(0)
    var xmin = Real(1e9)
    var xmax = Real(-1e9)
    for i in range(n):
        if top[i]:
            react += f[1][i]
        xmin = min(xmin, b.x[i])
        xmax = max(xmax, b.x[i])
    return (react / (1e5 * eps * L * L), ((xmax - xmin) / L - 1) / eps)


comptime NR = 4
comptime NT = 8
comptime CA: Real = 0.5
comptime CB: Real = 1.0
comptime CP: Real = 50.0


def cylinder(nu: Real, avg: Bool) -> Real:
    var lat = FemBody(1e5, nu, 30.0)
    make_beam(lat, NR, NT, 1, 1.0, 0.1)
    var b = FemBody(1e5, nu, 30.0)
    for i in range(lat.node_count()):
        var r = CA + (CB - CA) * lat.x[i] / Real(NR)
        var th = (Real(pi) / 2) * lat.y[i] / Real(NT)
        b.add_node(Vec3(r * cos(th), r * sin(th), lat.z[i] * 0.1, 0), 0.1)
    for ref t in lat.tets:
        b.add_tet(t.a, t.b, t.c, t.d)
    var n = b.node_count()
    var inner = List[Bool]()
    for i in range(n):
        inner.append(abs(sqrt(b.x[i] * b.x[i] + b.y[i] * b.y[i]) - CA) < 1e-4)
    # pressure as dead radial loads: arc CA pi/2 times thickness 0.1, over
    # 2 NT full shares (the arc's end nodes carry half)
    var w = CP * CA * (Real(pi) / 2) * 0.1 / Real(2 * NT)
    for _ in range(60000):
        var f = forces(b, avg)
        for i in range(n):
            if inner[i]:
                var r = sqrt(b.x[i] * b.x[i] + b.y[i] * b.y[i])
                var end = abs(b.x[i]) < 1e-3 or abs(b.y[i]) < 1e-3
                var share = w * (Real(0.5) if end else Real(1))
                f[0][i] += share * b.x[i] / r
                f[1][i] += share * b.y[i] / r
        b.integrate(f[0], f[1], f[2], 1e-5, ZERO, -1e30)
        for i in range(n):
            b.vz[i] = 0
            if abs(b.x[i]) < 1e-3:
                b.x[i] = 0
                b.vx[i] = 0
            if abs(b.y[i]) < 1e-3:
                b.y[i] = 0
                b.vy[i] = 0
    var u = Real(0)
    var k = 0
    for i in range(n):
        if inner[i]:
            u += sqrt(b.x[i] * b.x[i] + b.y[i] * b.y[i]) - CA
            k += 1
    var lame = CP * CA * CA * (1 + nu) * ((1 - 2 * nu) * CA + CB * CB / CA) / (1e5 * (CB * CB - CA * CA))
    return (u / Real(k)) / lame


def beam() -> FemBody:
    var b = FemBody(1e6, 0.3, 20.0)
    make_beam(b, 12, 2, 2, 0.1, 0.05)
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


def main() raises:
    var s = Suite("fem_incompressible")
    var ps = patch(0.499, False)
    var pa = patch(0.499, True)
    print("patch nu 0.499: F / (E eps A) standard", ps[0], " averaged", pa[0], ";  lateral / axial standard", ps[1], " averaged", pa[1])
    s.check(abs(ps[0] - 1) < 0.02 and abs(pa[0] - 1) < 0.02 and abs(ps[1] / 0.499 - 1) < 0.02 and abs(pa[1] / 0.499 - 1) < 0.02, "patch test: uniaxial stiffness E and lateral ratio nu, both variants")

    var c3s = cylinder(0.3, False)
    var c3a = cylinder(0.3, True)
    var c5s = cylinder(0.499, False)
    var c5a = cylinder(0.499, True)
    print("cylinder u(a) / Lame: nu 0.3 standard", c3s, " averaged", c3a, ";  nu 0.499 standard", c5s, " averaged", c5a)
    s.check(abs(c3s - 1) < 0.1 and abs(c3a - 1) < 0.1 and abs(c5s - 1) < 0.1 and abs(c5a - 1) < 0.1, "thick cylinder within 10 % of Lame at nu 0.3 and 0.499, both variants")
    s.check(c5s > 0.9 * c3s and abs(c5a / c5s - 1) < 0.03, "no volumetric locking: nu 0.499 is no stiffer than 0.3; averaging changes u(a) by < 3 %")

    var bs = beam()
    var ba = beam()
    var y0 = tip(bs)
    var rest = forces(bs, False)
    var resa = forces(ba, True)
    var rest_max = Real(0)
    for i in range(bs.node_count()):
        rest_max = max(rest_max, max(abs(rest[1][i]), abs(resa[1][i])))
    # f32 rounding of mu I - lambda_s (mu / lambda_s) I at mu = 3.8e5,
    # against a node's weight of 0.49 N
    var still = rest_max < 1e-2
    for _ in range(20000):
        step_material[StableNeoHookean](bs, 3e-5, Vec3(0, -9.8, 0, 0))
        step_nh_averaged(ba, 3e-5, Vec3(0, -9.8, 0, 0))
    # Euler-Bernoulli q L^4 / (8 E I): q = free mass x g / L
    var free_mass = Real(0)
    for i in range(bs.node_count()):
        if bs.inv_m[i] != 0:
            free_mass += 0.05
    var eb = (free_mass * 9.8 / 1.2) * Real(2.0736) / (8 * Real(1e6) * Real(0.0016 / 12))
    print("at rest: largest nodal force", rest_max, "N;  cantilever E 1e6 nu 0.3: tip sag standard", y0 - tip(bs), " averaged", y0 - tip(ba), " Euler-Bernoulli", eb)
    s.check(still and y0 - tip(ba) > y0 - tip(bs) and y0 - tip(ba) < eb, "bending: averaging is softer and still below beam theory; both at rest exert no force")
    s.finish()
