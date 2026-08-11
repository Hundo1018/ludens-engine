"""D3Q19 lattice Boltzmann: the velocity set, equilibrium, and the constants.

Lattice Boltzmann is the odd one out among this engine's fluid solvers. SPH and
PBF carry particles and ask what each one's neighbours are doing; LBM carries a
fixed grid of distribution functions and each cell talks only to its 19 direct
neighbours, always the same 19, at every step. There is no neighbour search, no
global pressure solve, no Poisson equation -- pressure comes out of the density
by an equation of state. That is why it is here: it is a PURER parallel
structure than anything else in the engine, and the natural workload to measure
a grid-parallel kernel against a particle one.

D3Q19 rather than D3Q27 or D3Q15: 19 is the standard compromise for 3D flow --
D3Q15 is cheaper and known to produce spurious anisotropy in turbulent cases,
D3Q27 costs 42% more memory for accuracy that only shows at high Reynolds
number. The weights below are the standard set and satisfy the moment
conditions the equilibrium relies on, which `test_lbm` checks directly rather
than trusting.

Layout is SoA: one array per velocity direction. That is the same discipline
`gpu_cloth` follows and for the same reason -- a cell's 19 values are never
touched together, but the SAME direction of many cells is, so keeping each
direction contiguous is what makes both the CPU sweep and a future GPU kernel
read coalesced.
"""

from std.math import sqrt
from geometry.vec import Real

comptime Q = 19  # velocity directions
comptime CS2: Real = 1.0 / 3.0  # lattice speed of sound squared
comptime INV_CS2: Real = 3.0
comptime INV_2CS4: Real = 4.5  # 1 / (2 * cs^4)


def cx(i: Int) -> Int:
    """x component of velocity `i`. Direction 0 is rest; 1..6 are the axes;
    7..18 are the face diagonals."""
    var t = List[Int](capacity=Q)
    t.append(0)
    t.append(1); t.append(-1); t.append(0); t.append(0); t.append(0); t.append(0)
    t.append(1); t.append(-1); t.append(1); t.append(-1)
    t.append(1); t.append(-1); t.append(1); t.append(-1)
    t.append(0); t.append(0); t.append(0); t.append(0)
    return t[i]


def cy(i: Int) -> Int:
    var t = List[Int](capacity=Q)
    t.append(0)
    t.append(0); t.append(0); t.append(1); t.append(-1); t.append(0); t.append(0)
    t.append(1); t.append(-1); t.append(-1); t.append(1)
    t.append(0); t.append(0); t.append(0); t.append(0)
    t.append(1); t.append(-1); t.append(1); t.append(-1)
    return t[i]


def cz(i: Int) -> Int:
    var t = List[Int](capacity=Q)
    t.append(0)
    t.append(0); t.append(0); t.append(0); t.append(0); t.append(1); t.append(-1)
    t.append(0); t.append(0); t.append(0); t.append(0)
    t.append(1); t.append(-1); t.append(-1); t.append(1)
    t.append(1); t.append(-1); t.append(-1); t.append(1)
    return t[i]


def weight(i: Int) -> Real:
    """1/3 for rest, 1/18 for the six axes, 1/36 for the twelve diagonals."""
    if i == 0:
        return Real(1.0) / 3.0
    if i <= 6:
        return Real(1.0) / 18.0
    return Real(1.0) / 36.0


def opposite(i: Int) -> Int:
    """The direction pointing the other way — what bounce-back reflects into.

    Derived from the components rather than tabulated: a hand-written opposite
    table is exactly the kind of thing that stays subtly wrong for months, and
    `test_lbm` checks that c[opposite(i)] == -c[i] for every i regardless."""
    for j in range(Q):
        if cx(j) == -cx(i) and cy(j) == -cy(i) and cz(j) == -cz(i):
            return j
    return 0


def equilibrium(i: Int, rho: Real, ux: Real, uy: Real, uz: Real) -> Real:
    """The second-order Maxwell-Boltzmann expansion.

    w_i * rho * (1 + 3(c.u) + 4.5(c.u)^2 - 1.5 u^2). Truncating at second order
    is what makes this incompressible Navier-Stokes to O(Ma^2) and not
    something else, which is why the benchmarks keep the Mach number low."""
    var cu = Real(cx(i)) * ux + Real(cy(i)) * uy + Real(cz(i)) * uz
    var u2 = ux * ux + uy * uy + uz * uz
    return (
        weight(i) * rho
        * (1 + INV_CS2 * cu + INV_2CS4 * cu * cu - 1.5 * u2)
    )


def tau_from_viscosity(nu: Real) -> Real:
    """Relaxation time for a kinematic viscosity. tau = 3*nu + 0.5, so tau
    approaches 0.5 as viscosity approaches zero — the stability boundary, and
    the reason `test_lbm` drives it there on purpose."""
    return 3 * nu + 0.5


def viscosity_from_tau(tau: Real) -> Real:
    return (tau - 0.5) / 3
