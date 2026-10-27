# tier: integration
"""Solid cells in `MacFluid2` (ROADMAP 17.61, `MacFluid2.set_solid`).

A 32^2 periodic grid, dx 1/32, nu 1e-3, dt 1/120, inflow u = 1 + 0.3 sin(2 pi i / n),
v = 0.3 sin(2 pi j / n) (nonzero divergence, so the projection does work), and a solid block of 8 x 8 cells at i, j in [12, 20). Faces touching a solid cell
carry no normal flux: the velocity there is held at zero, and the pressure
solve treats those faces as Neumann walls (the masked operator drops them
from each fluid cell's stencil and leaves solid cells as identity rows).

Predictions, written before the run:

  * Faces touching a solid cell carry zero normal velocity after every step:
    the largest such |u| or |v| is exactly 0.
  * After each projection the divergence on fluid cells is below 1e-3 of
    U / dx = 32, i.e. 0.032. The projection tolerance is 1e-6 of the rhs.
  * Stagnation and wake: at t = 1 s the mean u over the fluid cells in front
    of the block (i in [8, 12), j in [12, 20)) and behind it (i in [20, 24),
    same j) are both below 1. The block obstructs the flow.
  * An all-fluid mask (every cell fluid, mask passed explicitly) reproduces
    the unmasked path: largest |du| / U after 10 steps below 1e-5. The masked
    operator's arithmetic order differs, so this is not bit-identical.

Measured: recorded in the run output and the ROADMAP 17.61 progress note.
"""

from std.math import sin
from harness.runner import Suite
from geometry.vec import Real
from physics.mac_fluid import MacFluid2


def block_mask(n: Int) -> List[Bool]:
    var m = List[Bool](length=n * n, fill=False)
    for j in range(12, 20):
        for i in range(12, 20):
            m[j * n + i] = True
    return m^


def inflow(n: Int, dx: Real) raises -> MacFluid2:
    """Mean inflow 1 with a sinusoidal part in x and y. A purely uniform
    field has zero divergence, so the projection would solve a zero rhs and
    the all-fluid comparison would test nothing (the first run returned 0.0
    for that reason and is superseded)."""
    var f = MacFluid2(n, dx, Real(1e-3))
    for j in range(n):
        for i in range(n):
            var k = j * n + i
            f.u[k] = 1 + Real(0.3) * sin(Real(2 * 3.141592653589793) * Real(i) / Real(n))
            f.v[k] = Real(0.3) * sin(Real(2 * 3.141592653589793) * Real(j) / Real(n))
    return f^


def solid_face_max(f: MacFluid2, solid: List[Bool]) -> Real:
    """Largest normal velocity on a face that touches a solid cell."""
    var n = f.n
    var m = Real(0)
    for j in range(n):
        var jm = (j + n - 1) % n
        for i in range(n):
            var k = j * n + i
            var im = (i + n - 1) % n
            if solid[k] or solid[j * n + im]:
                m = max(m, abs(f.u[k]))
            if solid[k] or solid[jm * n + i]:
                m = max(m, abs(f.v[k]))
    return m


def fluid_div_max(f: MacFluid2, solid: List[Bool]) -> Real:
    var d = f.divergence()
    var m = Real(0)
    for k in range(len(d)):
        if not solid[k]:
            m = max(m, abs(d[k]))
    return m


def mean_u(f: MacFluid2, solid: List[Bool], i0: Int, i1: Int, j0: Int, j1: Int) -> Real:
    var n = f.n
    var sum = Float64(0)
    var cnt = 0
    for j in range(j0, j1):
        for i in range(i0, i1):
            var k = j * n + i
            if not solid[k]:
                sum += Float64(f.u[k])
                cnt += 1
    return Real(sum / Float64(cnt))


def main() raises:
    var s = Suite("fluid_solid")
    var n = 32
    var dx = Real(1) / Real(32)
    var dt = Real(1) / Real(120)
    var solid = block_mask(n)

    var f = inflow(n, dx)
    f.set_solid(solid.copy())
    var worst_face = Real(0)
    var worst_div = Real(0)
    for _ in range(120):
        f.step(dt)
        worst_face = max(worst_face, solid_face_max(f, solid))
        worst_div = max(worst_div, fluid_div_max(f, solid))
    var front = mean_u(f, solid, 8, 12, 12, 20)
    var wake = mean_u(f, solid, 20, 24, 12, 20)
    print("  solid face max |u| after 120 steps", worst_face)
    print("  fluid divergence max over the run", worst_div, "(bound 0.032)")
    print("  mean u in front", front, "behind", wake)
    s.check(worst_face == 0, "faces touching solid cells carry zero normal velocity")
    s.check(worst_div < Real(0.032), "fluid divergence after each projection below 1e-3 U / dx")
    s.check(front < 1 and wake < 1, "block slows the flow in front of and behind it")

    var a = inflow(n, dx)
    a.set_solid(List[Bool](length=n * n, fill=False))
    var b = inflow(n, dx)
    for _ in range(10):
        a.step(dt)
        b.step(dt)
    var diff = Real(0)
    for k in range(n * n):
        diff = max(diff, abs(a.u[k] - b.u[k]))
        diff = max(diff, abs(a.v[k] - b.v[k]))
    print("  all-fluid mask vs unmasked, max |du| after 10 steps", diff)
    s.check(diff < Real(1e-5), "all-fluid mask reproduces the unmasked step")

    var bad_len = False
    try:
        var g = MacFluid2(n, dx, Real(1e-3))
        g.set_solid(List[Bool](length=n * n - 1, fill=False))
    except:
        bad_len = True
    s.check(bad_len, "set_solid raises on a mask of the wrong length")

    var isolated = False
    try:
        var g = MacFluid2(n, dx, Real(1e-3))
        var m = List[Bool](length=n * n, fill=False)
        # a fluid cell (5, 5) walled in on all four sides
        m[5 * n + 4] = True
        m[5 * n + 6] = True
        m[4 * n + 5] = True
        m[6 * n + 5] = True
        g.set_solid(m^)
    except:
        isolated = True
    s.check(isolated, "set_solid raises on a fluid cell with no fluid neighbour")

    var mg_refused = False
    try:
        var g = MacFluid2(n, dx, Real(1e-3))
        g.set_solid(block_mask(n))
        g.use_multigrid()
    except:
        mg_refused = True
    s.check(mg_refused, "use_multigrid raises once a solid mask is set")
    s.finish()
