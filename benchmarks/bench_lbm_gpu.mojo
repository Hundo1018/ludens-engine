"""LBM wind tunnel follow-ups (ROADMAP 17.42): CPU vs GPU throughput in
million lattice-cell updates per second (MLUPS) over grid size, the GPU
row counting only the stepping (upload and download are once per run and
listed separately), and the CPU-side cost of interpolated bounce-back and
of the control-surface force against the half-way baseline.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from std.sys import has_accelerator
from max.gpu.host import DeviceContext
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from fluid.lbm import Lbm, BC_TUNNEL
from fluid.lbm_gpu import LbmGpu


def _tunnel(nx: Int, ny: Int) -> Lbm:
    var t = Lbm(nx, ny, ny, Real(0.02), BC_TUNNEL)
    t.init_uniform(1.0, 0.05, 0, 0)
    t.inlet_u = 0.05
    t.set_solid_sphere(Real(nx) * 0.3, Real(ny - 1) * 0.5, Real(ny - 1) * 0.5, Real(ny) / 7)
    return t^


def main() raises:
    var t = BenchTable("LBM: CPU vs GPU, and the cost of interpolated bounce-back / control-surface force")
    for size in [32, 64, 96]:
        var steps = 40 if size < 96 else 20
        var c = _tunnel(size * 2, size)
        var cells = c.cells()
        var t0 = Int(perf_counter_ns())
        for _ in range(steps):
            c.step()
        t.add("CPU, half-way bounce-back", cells, "cell-update", Int(perf_counter_ns()) - t0, cells * steps)
        keep(c.fx)
        comptime if has_accelerator():
            var ctx = DeviceContext()
            var h = _tunnel(size * 2, size)
            var tu = Int(perf_counter_ns())
            var g = LbmGpu(ctx, h)
            var t1 = Int(perf_counter_ns())
            g.step(ctx, 1)
            var t2 = Int(perf_counter_ns())
            g.step(ctx, steps * 10)
            var t3 = Int(perf_counter_ns())
            g.download(h)
            var t4 = Int(perf_counter_ns())
            keep(h.f[0])
            _ = t2 - t1
            t.add("GPU stepping", cells, "cell-update", t3 - t2, cells * steps * 10)
            t.add("GPU upload (once)", cells, "run", t1 - tu, 1)
            t.add("GPU download (once)", cells, "run", t4 - t3, 1)
    var hw = _tunnel(64, 32)
    var iw = _tunnel(64, 32)
    iw.interp = True
    var ta = Int(perf_counter_ns())
    for _ in range(40):
        hw.step()
    var tb = Int(perf_counter_ns())
    for _ in range(40):
        iw.step()
    var tc = Int(perf_counter_ns())
    _ = iw.momentum_flux_force(10, 6, 6, 32, 25, 25)
    var td = Int(perf_counter_ns())
    t.add("CPU step, half-way (64x32x32)", hw.cells(), "step", tb - ta, 40)
    t.add("CPU step, interpolated (64x32x32)", iw.cells(), "step", tc - tb, 40)
    t.add("control-surface force, one evaluation", iw.cells(), "eval", td - tc, 1)
    t.print_report()
