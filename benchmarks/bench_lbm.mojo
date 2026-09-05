"""Lattice Boltzmann: MLUPS, and what the grid buys over particles.

MLUPS -- million lattice updates per second -- is the standard LBM figure, and
it is what makes this comparable to published numbers rather than only to
itself. One update is one cell advanced one step: collide, stream, and whatever
boundary applies.

The grid sweep is the point of the comparison. SPH and PBF spend a large part of
every step deciding WHICH particles interact; LBM never does, because a cell's
neighbours are the same 19 cells forever. There is no neighbour search, no
sorting, no global pressure solve. What it pays instead is memory: 19 floats per
cell whether that cell is doing anything or not, and a full second buffer for
streaming.

That trade shows up directly in the rows. The scan over grid size holds MLUPS
roughly flat until the working set stops fitting in cache, which is where a
method with no arithmetic intensity to hide behind starts being bound by memory
bandwidth alone. The obstacle rows price bounce-back against clear flow, and the
tunnel rows price the inlet/outlet conditions -- both are per-cell costs on a
subset of the domain, so they scale with surface rather than volume.

WHERE THIS SITS. 3.7 MLUPS is a defensible figure for a straightforward scalar
implementation and is NOT close to the best published CPU numbers, which reach
tens of MLUPS using SIMD across cells, a fused collide-stream, and an in-place
pattern that avoids the second buffer entirely. None of those are done here. Two
things that WERE done are worth recording because they were worth 20x between
them: the velocity set is materialised once into the solver instead of being
rebuilt by a function call 19 times per cell per step (the first run of this
benchmark read 0.18 MLUPS, and all of the difference was allocation), and
streaming swaps its two buffers instead of copying one into the other.

Run with: `mojo run -I build benchmarks/bench_lbm.mojo`.
"""

from std.benchmark import keep
from geometry.vec import Real, Vec3
from fluid.lbm import Lbm, CELL_SOLID, BC_PERIODIC, BC_TUNNEL
from harness.bench import BenchTable, now


def run(
    mut table: BenchTable, label: String, n: Int, steps: Int,
    mode: Int, obstacle: Bool,
):
    var l = Lbm(n, n, n, Real(0.02), mode)
    l.init_uniform(1.0, 0.05, 0, 0)
    if mode == BC_TUNNEL:
        l.inlet_u = 0.05
    if obstacle:
        l.set_solid_sphere(
            Real(n) * 0.35, Real(n) * 0.5, Real(n) * 0.5, Real(n) * 0.15
        )
    var t0 = now()
    for _ in range(steps):
        l.step()
    var t1 = now()
    keep(l.velocity(l.idx(n // 2, n // 2, n // 2))[0])
    # one "op" is one cell-update, so ns/op reads directly as 1000/MLUPS
    table.add(
        label + " cells=" + String(l.cells())
        + (" solid=" + String(l.solid_count()) if obstacle else ""),
        n, "cell-step", t1 - t0, steps * l.cells(),
    )


def cd_row(
    mut table: BenchTable, nx: Int, ny: Int, r: Real, u: Real, nu: Real,
    steps: Int, avg: Int,
):
    """Drag coefficient against resolution, with the cost of getting it.

    The number to watch is the deviation from Schiller-Naumann, which is an
    empirical fit to EXPERIMENT rather than to another simulation. A single
    resolution agreeing would prove nothing; the claim is that the deviation
    shrinks as the sphere is resolved, and that it costs what the ns/op column
    says to shrink it."""
    from std.math import pi
    var t = Lbm(nx, ny, ny, nu, BC_TUNNEL)
    t.init_uniform(1.0, u, 0, 0)
    t.inlet_u = u
    t.set_solid_sphere(Real(nx) * 0.3, Real(ny - 1) * 0.5, Real(ny - 1) * 0.5, r)
    var t0 = now()
    var acc = Real(0)
    var m = 0
    for k in range(steps):
        t.step()
        if k >= steps - avg:
            acc += t.fx
            m += 1
    var t1 = now()
    var area = Real(pi) * r * r
    var cd = (acc / Real(m)) / (Real(0.5) * u * u * area)
    var re = u * 2 * r / nu
    var sn = (24.0 / re) * (1.0 + 0.15 * (Real(re) ** Real(0.687)))
    var err = abs(cd - sn) / sn
    keep(cd)
    table.add(
        "sphere r=" + String(Int(r)) + " Re=" + String(Int(re))
        + " Cd=" + String(cd) + " vs " + String(sn)
        + " err=" + String(err),
        nx * ny * ny, "cell-step", t1 - t0, steps * t.cells(),
    )


def les_cost_row(mut table: BenchTable, label: String, n: Int, steps: Int, cs: Real):
    """Sheared channel, walls counter-driven by a body force -- the strain field
    a subgrid model is built to react to. Same grid and same step count for both
    rows; the only change is the Smagorinsky constant, so the ns/op gap between
    the rows IS the per-cell cost of computing the eddy viscosity."""
    var l = Lbm(n, n, 4, Real(0.02), BC_PERIODIC)
    l.smagorinsky = cs
    l.init_uniform(1.0, 0, 0, 0)
    for z in range(4):
        for x in range(n):
            l.flag[l.idx(x, 0, z)] = CELL_SOLID
            l.flag[l.idx(x, n - 1, z)] = CELL_SOLID
    l.force_x = Real(2e-5)
    var t0 = now()
    for _ in range(steps):
        l.step()
    var t1 = now()
    keep(l.velocity(l.idx(n // 2, n // 2, 2))[0])
    table.add(label, l.cells(), "cell-step", t1 - t0, steps * l.cells())


def les_regime_row(mut table: BenchTable, label: String, cs: Real):
    """The advantage regime, lifted from test_lbm_les.blows_up: nu=8e-4, u=0.16,
    Re~1600 past a sphere on a 48x24x24 grid -- a flow plain BGK cannot hold.
    Run up to 600 steps; if the monitored velocity leaves [-10, 10] report the
    step it diverged, otherwise report that it ran to completion (its Mops/s
    column then reads as MLUPS). A speed ratio is meaningless when one side
    diverges, so this reports the OUTCOME, not a ratio."""
    comptime STEPS = 600
    var t = Lbm(48, 24, 24, Real(0.0008), BC_TUNNEL)
    t.smagorinsky = cs
    t.init_uniform(1.0, 0.16, 0, 0)
    t.inlet_u = 0.16
    t.set_solid_sphere(14, 11.5, 11.5, 4.0)
    var t0 = now()
    var diverged_at = -1
    var done = 0
    for k in range(STEPS):
        t.step()
        done += 1
        var v = Float64(t.velocity(t.idx(30, 11, 11))[0])
        if not (v > -10.0 and v < 10.0):
            diverged_at = k
            break
    var t1 = now()
    keep(t.velocity(t.idx(30, 11, 11))[0])
    if diverged_at >= 0:
        table.add(
            label + ": DIVERGED @ step " + String(diverged_at),
            t.cells(), "cell-step", t1 - t0, done * t.cells(),
        )
    else:
        table.add(
            label + ": ran " + String(done) + " steps to completion",
            t.cells(), "cell-step", t1 - t0, done * t.cells(),
        )


def main() raises:
    var table = BenchTable("Lattice Boltzmann D3Q19 (one op = one cell update)")
    run(table, "periodic 16^3", 16, 200, BC_PERIODIC, False)
    run(table, "periodic 32^3", 32, 60, BC_PERIODIC, False)
    run(table, "periodic 48^3", 48, 20, BC_PERIODIC, False)
    run(table, "periodic 64^3", 64, 10, BC_PERIODIC, False)
    run(table, "tunnel 32^3", 32, 60, BC_TUNNEL, False)
    run(table, "tunnel 32^3 + sphere", 32, 60, BC_TUNNEL, True)
    table.print_report()

    var cdt = BenchTable("Sphere drag: resolution vs deviation from experiment")
    cd_row(cdt, 48, 24, Real(3.0), Real(0.05), Real(0.02), 1200, 300)
    cd_row(cdt, 64, 32, Real(4.0), Real(0.05), Real(0.02), 1200, 300)
    cd_row(cdt, 80, 40, Real(5.0), Real(0.05), Real(0.02), 1200, 300)
    cdt.print_report()

    # Smagorinsky LES (fluid/lbm.mojo:382 `eddy_viscosity`) is a seam:
    # `smagorinsky = 0` is bit-identical to plain BGK, `> 0` adds a strain-rate
    # eddy viscosity. test_lbm_les proves the parity and the advantage regime;
    # this table prices both. Cost rows: the per-cell overhead of the model on a
    # grid where it changes nothing. Regime rows: the low-viscosity tunnel that
    # plain BGK diverges on and LES carries to completion -- outcome, not ratio.
    var les = BenchTable("Smagorinsky LES: cost, and the regime that needs it")
    les_cost_row(les, "sheared 32^2x4, smagorinsky=0 (== plain BGK)", 32, 200, Real(0))
    les_cost_row(les, "sheared 32^2x4, smagorinsky=0.17", 32, 200, Real(0.17))
    les_regime_row(les, "Re~1600 tunnel, smagorinsky=0", Real(0))
    les_regime_row(les, "Re~1600 tunnel, smagorinsky=0.17", Real(0.17))
    les.print_report()
