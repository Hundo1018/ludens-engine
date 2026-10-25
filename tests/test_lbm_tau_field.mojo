# tier: unit
"""Per-cell viscosity in the LBM (ROADMAP 17.61: tau(T),
`Lbm.set_viscosity_field`, `collide_var`).

  1. Ordinary: a uniform viscosity field is the plain lattice (populations
     within 1e-6 after 200 steps -- same BGK, another method).
  2. Integration: a Poiseuille channel (31 nodes across, walls half-way)
     whose lower half has nu 0.05 and upper half 0.2 -- as from a hot
     layer over a cold one -- settles to the two-layer profile
     nu du/dy = -F (y - y0), y0 = int y / nu / int 1 / nu, within 3 % of
     its peak (printed); its peak sits in the runnier layer, off centre.
  3. Extreme: a field of the wrong length or with nu <= 0 raises; an
     empty field returns to the uniform tau.
"""

from harness.runner import Suite
from geometry.vec import Real
from fluid.lbm import Lbm, BC_PERIODIC, CELL_SOLID

comptime N = 31
comptime F: Real = 1e-6


def _nu(y: Real) -> Real:
    return Real(0.05) if y < Real(N - 1) * 0.5 else Real(0.2)


def main() raises:
    var s = Suite("lbm_tau_field")
    var a = Lbm(6, 6, 6, 0.1, BC_PERIODIC)
    var b = Lbm(6, 6, 6, 0.1, BC_PERIODIC)
    a.init_uniform(1, 0.01, 0.005, 0)
    b.init_uniform(1, 0.01, 0.005, 0)
    b.set_viscosity_field(List[Real](length=b.cells(), fill=0.1))
    for _ in range(200):
        a.step()
        b.step()
    var worst = Real(0)
    for i in range(len(a.f)):
        worst = max(worst, abs(a.f[i] - b.f[i]))
    print("  uniform field vs plain lattice, 200 steps: worst population difference", worst)
    s.check(worst < 1e-6, "a uniform field is the plain lattice")

    var ch = Lbm(4, N, 4, 0.1, BC_PERIODIC)
    for z in range(4):
        for x in range(4):
            ch.flag[ch.idx(x, 0, z)] = CELL_SOLID
            ch.flag[ch.idx(x, N - 1, z)] = CELL_SOLID
    var nu = List[Real](length=ch.cells(), fill=0)
    for z in range(4):
        for y in range(N):
            for x in range(4):
                nu[ch.idx(x, y, z)] = _nu(Real(y))
    ch.set_viscosity_field(nu)
    ch.init_uniform(1, 0, 0, 0)
    ch.force_x = F
    for _ in range(40000):
        ch.step()
    # analytic: walls at 0.5 and N - 1.5; nu switches at (N - 1) / 2
    var lo = Real(0.5)
    var hi = Real(N) - 1.5
    var steps = 20000
    var dy = (hi - lo) / Real(steps)
    var i1 = Real(0)
    var iy = Real(0)
    for k in range(steps):
        var y = lo + (Real(k) + 0.5) * dy
        i1 += dy / _nu(y)
        iy += dy * y / _nu(y)
    var y0 = iy / i1
    var worst2 = Real(0)
    var peak = Real(0)
    var at = 0
    for yn in range(1, N - 1):
        var target = Real(yn)
        var u = Real(0)
        var m = Int((target - lo) / dy)
        for k in range(m):
            var y = lo + (Real(k) + 0.5) * dy
            u += -F * (y - y0) / _nu(y) * dy
        var got = ch.velocity(ch.idx(2, yn, 2))[0]
        worst2 = max(worst2, abs(got - u))
        if got > peak:
            peak = got
            at = yn
    print("  two-layer channel: peak", peak, "at y", at, "(centre", (N - 1) // 2, ", zero shear y0", y0, ");  worst |u - analytic|", worst2, " =", worst2 / peak, "of the peak")
    s.check(worst2 < 0.03 * peak and Real(at) < Real(N - 1) * 0.5, "the two-layer profile, its peak in the runnier layer")

    var raised = 0
    try:
        ch.set_viscosity_field(List[Real](length=3, fill=0.1))
    except:
        raised += 1
    try:
        ch.set_viscosity_field(List[Real](length=ch.cells(), fill=0))
    except:
        raised += 1
    ch.set_viscosity_field(List[Real]())
    s.check(raised == 2 and len(ch.tau_cell) == 0, "bad fields raise; an empty field returns to the uniform tau")
    s.finish()
