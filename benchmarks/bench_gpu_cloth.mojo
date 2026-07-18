"""GPU vs CPU XPBD cloth (gather-Jacobi, 8 iterations, 60 steps).

Same arithmetic on both sides (`test_gpu_cloth` proves parity to ~1e-6);
this table shows what the GPU buys as the particle count scales. On hosts
without an accelerator only the CPU rows run.
"""

from std.sys import has_accelerator
from std.time import perf_counter_ns
from std.gpu.host import DeviceContext
from harness.bench import BenchTable
from physics.gpu_cloth import cpu_cloth_run, gpu_cloth_run_ctx

comptime STEPS = 60
comptime ITERS = 8


def main() raises:
    var t = BenchTable("XPBD cloth: CPU vs GPU (60 steps x 8 Jacobi iters)")

    var t0 = Int(perf_counter_ns())
    var c1 = cpu_cloth_run[64, 64](STEPS, ITERS, 1.0 / 60.0, 0.05)
    var t1 = Int(perf_counter_ns())
    t.add("CPU 64x64 (4k particles)", 4096, "step", t1 - t0, STEPS)
    _ = c1.x[0]

    var t2 = Int(perf_counter_ns())
    var c2 = cpu_cloth_run[128, 128](STEPS, ITERS, 1.0 / 60.0, 0.05)
    var t3 = Int(perf_counter_ns())
    t.add("CPU 128x128 (16k particles)", 16384, "step", t3 - t2, STEPS)
    _ = c2.x[0]

    comptime if has_accelerator():
        # ONE shared context for every GPU rollout: multiple DeviceContexts
        # per process hang on this nightly (root-caused 2026-07-13; the old
        # per-call driver is why this section produced no rows before).
        var ctx = DeviceContext()
        # warm-up launch (JIT) kept out of the timed runs
        var warm = gpu_cloth_run_ctx[64, 64](ctx, 2, ITERS, 1.0 / 60.0, 0.05)
        _ = warm.x[0]

        var g0 = Int(perf_counter_ns())
        var g1 = gpu_cloth_run_ctx[64, 64](ctx, STEPS, ITERS, 1.0 / 60.0, 0.05)
        var g0e = Int(perf_counter_ns())
        t.add("GPU 64x64 (4k particles)", 4096, "step", g0e - g0, STEPS)
        _ = g1.x[0]

        var g2s = Int(perf_counter_ns())
        var g2 = gpu_cloth_run_ctx[128, 128](ctx, STEPS, ITERS, 1.0 / 60.0, 0.05)
        var g2e = Int(perf_counter_ns())
        t.add("GPU 128x128 (16k particles)", 16384, "step", g2e - g2s, STEPS)
        _ = g2.x[0]

        var g3s = Int(perf_counter_ns())
        var g3 = gpu_cloth_run_ctx[256, 256](ctx, STEPS, ITERS, 1.0 / 60.0, 0.05)
        var g3e = Int(perf_counter_ns())
        t.add("GPU 256x256 (65k particles)", 65536, "step", g3e - g3s, STEPS)
        _ = g3.x[0]
    else:
        print("(no GPU: only CPU rows)")

    t.print_report()
