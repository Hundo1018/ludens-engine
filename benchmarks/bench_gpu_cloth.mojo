"""GPU vs CPU XPBD cloth (gather-Jacobi, 8 iterations, 60 steps).

Same arithmetic on both sides (`test_gpu_cloth` proves parity to ~1e-6);
table 1 shows what the GPU buys as the particle count scales. On hosts
without an accelerator only the CPU rows run.

Table 2 splits that end-to-end GPU number into host->device upload, device
compute, and device->host download, and adds the shape a real game loop has:
reading positions back EVERY frame. Every row is normalized per simulation
step, so the phases are additive and directly comparable — the point being
that a rollout which only drains once amortizes its transfers to near zero,
while per-frame readback pays a full device sync plus three columns across
the bus on every step.
"""

from std.sys import has_accelerator
from std.time import perf_counter_ns
from std.gpu.host import DeviceContext
from harness.bench import BenchTable
from physics.gpu_cloth import (
    cpu_cloth_run,
    gpu_cloth_run_ctx,
    gpu_cloth_run_ctx_timed,
    GpuClothTiming,
)

comptime STEPS = 60
comptime ITERS = 8
comptime DT: Float32 = 1.0 / 60.0
comptime REST: Float32 = 0.05


def add_transfer_rows[W: Int, H: Int](
    mut ctx: DeviceContext, mut t: BenchTable, label: String, n: Int
) raises:
    """Two rollouts of the same cloth: drain-once vs drain-every-frame."""
    var tm = GpuClothTiming.zero()
    var s1 = gpu_cloth_run_ctx_timed[W, H](ctx, STEPS, ITERS, DT, REST, 0, tm)
    _ = s1.x[0]
    t.add(label + " upload (h2d, once)", n, "step", tm.upload_ns, STEPS)
    t.add(label + " compute (device)", n, "step", tm.compute_ns, STEPS)
    t.add(label + " download (d2h, once)", n, "step", tm.download_ns, STEPS)
    t.add(label + " TOTAL (drain once)", n, "step", tm.total_ns, STEPS)

    var tr = GpuClothTiming.zero()
    var s2 = gpu_cloth_run_ctx_timed[W, H](ctx, STEPS, ITERS, DT, REST, 1, tr)
    _ = s2.x[0]
    t.add(label + " compute (device, synced/frame)", n, "step", tr.compute_ns, STEPS)
    t.add(label + " download (d2h, per frame)", n, "step", tr.download_ns, STEPS)
    t.add(label + " TOTAL (readback/frame)", n, "step", tr.total_ns, STEPS)


def main() raises:
    var t = BenchTable("XPBD cloth: CPU vs GPU (60 steps x 8 Jacobi iters)")

    var t0 = Int(perf_counter_ns())
    var c1 = cpu_cloth_run[64, 64](STEPS, ITERS, DT, REST)
    var t1 = Int(perf_counter_ns())
    t.add("CPU 64x64 (4k particles)", 4096, "step", t1 - t0, STEPS)
    _ = c1.x[0]

    var t2 = Int(perf_counter_ns())
    var c2 = cpu_cloth_run[128, 128](STEPS, ITERS, DT, REST)
    var t3 = Int(perf_counter_ns())
    t.add("CPU 128x128 (16k particles)", 16384, "step", t3 - t2, STEPS)
    _ = c2.x[0]

    comptime if has_accelerator():
        # ONE shared context for every GPU rollout: multiple DeviceContexts
        # per process hang on this nightly (root-caused 2026-07-13; the old
        # per-call driver is why this section produced no rows before).
        var ctx = DeviceContext()
        # warm-up launch (JIT) kept out of the timed runs
        var warm = gpu_cloth_run_ctx[64, 64](ctx, 2, ITERS, DT, REST)
        _ = warm.x[0]

        var g0 = Int(perf_counter_ns())
        var g1 = gpu_cloth_run_ctx[64, 64](ctx, STEPS, ITERS, DT, REST)
        var g0e = Int(perf_counter_ns())
        t.add("GPU 64x64 (4k particles)", 4096, "step", g0e - g0, STEPS)
        _ = g1.x[0]

        var g2s = Int(perf_counter_ns())
        var g2 = gpu_cloth_run_ctx[128, 128](ctx, STEPS, ITERS, DT, REST)
        var g2e = Int(perf_counter_ns())
        t.add("GPU 128x128 (16k particles)", 16384, "step", g2e - g2s, STEPS)
        _ = g2.x[0]

        var g3s = Int(perf_counter_ns())
        var g3 = gpu_cloth_run_ctx[256, 256](ctx, STEPS, ITERS, DT, REST)
        var g3e = Int(perf_counter_ns())
        t.add("GPU 256x256 (65k particles)", 65536, "step", g3e - g3s, STEPS)
        _ = g3.x[0]

        t.print_report()

        var tt = BenchTable(
            "GPU host<->device transfer — upload / compute / readback (per step)"
        )
        add_transfer_rows[64, 64](ctx, tt, "64x64 (4k)", 4096)
        add_transfer_rows[128, 128](ctx, tt, "128x128 (16k)", 16384)
        add_transfer_rows[256, 256](ctx, tt, "256x256 (65k)", 65536)
        tt.print_report()
    else:
        print("(no GPU: only CPU rows)")
        t.print_report()
