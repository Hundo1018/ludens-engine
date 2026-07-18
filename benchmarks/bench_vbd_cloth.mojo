"""XPBD vs VBD on the identical cloth scene: total cost AT a quality level.

Fair-comparison rule (CATEGORY.md law v2): solvers are compared at the same
iteration budgets AND each row carries the constraint quality it bought
(worst horizontal edge stretch error, % of rest) — so "cheaper" can be read
against "converged". Same grid, gravity, pins, floor and damping on both
sides (`test_vbd_cloth` holds the physical gates + CPU/GPU parity).
Run with: `mojo run -I build benchmarks/bench_vbd_cloth.mojo`.
"""

from std.sys import has_accelerator
from std.time import perf_counter_ns
from std.gpu.host import DeviceContext
from harness.bench import BenchTable
from physics.gpu_cloth import ClothState, cpu_cloth_run, gpu_cloth_run_ctx
from physics.vbd_cloth import cpu_vbd_run, gpu_vbd_run_ctx

comptime STEPS = 60
comptime REST: Float32 = 0.05


def _err_str[W: Int, H: Int](s: ClothState) -> String:
    """Worst horizontal edge |l - rest| / rest as a percent string."""
    var worst = Float64(0)
    for r in range(H):
        for c in range(W - 1):
            var i = r * W + c
            var dxx = Float64(s.x[i + 1] - s.x[i])
            var dyy = Float64(s.y[i + 1] - s.y[i])
            var dzz = Float64(s.z[i + 1] - s.z[i])
            var l = (dxx * dxx + dyy * dyy + dzz * dzz) ** 0.5
            var e = abs(l - Float64(REST)) / Float64(REST)
            if e > worst:
                worst = e
    var pc100 = Int(worst * 10000.0 + 0.5)  # percent x 100
    var frac = pc100 % 100
    var fs = String(frac)
    if frac < 10:
        fs = "0" + fs
    return String(pc100 // 100) + "." + fs + "%"


def main() raises:
    var t = BenchTable("Cloth solvers: XPBD vs VBD (60 steps, err = worst edge stretch)")

    # CPU rows are kept small (like bench_gpu_cloth) — the point is the
    # solver-vs-solver cost AT a quality level, and VBD's per-vertex 3x3
    # Newton is heavier per iteration than XPBD's gather-Jacobi projection.
    comptime for it_idx in range(3):
        comptime ITERS = 2 if it_idx == 0 else (5 if it_idx == 1 else 10)
        var t0 = Int(perf_counter_ns())
        var xs = cpu_cloth_run[32, 32](STEPS, ITERS, 1.0 / 60.0, REST)
        var t1 = Int(perf_counter_ns())
        t.add(
            "CPU xpbd 32x32 it=" + String(ITERS) + " err=" + _err_str[32, 32](xs),
            1024, "step", t1 - t0, STEPS,
        )
        var t2 = Int(perf_counter_ns())
        var vs = cpu_vbd_run[32, 32](STEPS, ITERS, 1.0 / 60.0, REST)
        var t3 = Int(perf_counter_ns())
        t.add(
            "CPU vbd 32x32 it=" + String(ITERS) + " err=" + _err_str[32, 32](vs),
            1024, "step", t3 - t2, STEPS,
        )

    comptime if has_accelerator():
        # ONE shared context across every GPU rollout: creating several
        # DeviceContexts per process hangs on this nightly (root-caused
        # 2026-07-13 — this is why the old per-call drivers left the cloth
        # benchmark rows empty in the report).
        var ctx = DeviceContext()
        # warm-up launches (JIT) kept out of the timed runs
        var wx = gpu_cloth_run_ctx[128, 128](ctx, 2, 8, 1.0 / 60.0, REST)
        _ = wx.x[0]
        var wv = gpu_vbd_run_ctx[128, 128](ctx, 2, 8, 1.0 / 60.0, REST)
        _ = wv.x[0]

        comptime for it_idx in range(3):
            comptime ITERS = 2 if it_idx == 0 else (5 if it_idx == 1 else 10)
            var g0 = Int(perf_counter_ns())
            var gx = gpu_cloth_run_ctx[128, 128](ctx, STEPS, ITERS, 1.0 / 60.0, REST)
            var g1 = Int(perf_counter_ns())
            t.add(
                "GPU xpbd 128x128 it=" + String(ITERS) + " err="
                + _err_str[128, 128](gx),
                16384, "step", g1 - g0, STEPS,
            )
            var g2 = Int(perf_counter_ns())
            var gv = gpu_vbd_run_ctx[128, 128](ctx, STEPS, ITERS, 1.0 / 60.0, REST)
            var g3 = Int(perf_counter_ns())
            t.add(
                "GPU vbd 128x128 it=" + String(ITERS) + " err="
                + _err_str[128, 128](gv),
                16384, "step", g3 - g2, STEPS,
            )
    else:
        print("(no GPU: only CPU rows)")

    t.print_report()
