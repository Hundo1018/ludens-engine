from std.sys import has_accelerator
from harness.runner import Suite
from physics.vbd_cloth import cpu_vbd_run, gpu_vbd_run
from physics.gpu_cloth import cpu_cloth_run


def main() raises:
    var s = Suite("vbd_cloth")
    comptime W = 32
    comptime H = 32
    comptime STEPS = 60
    comptime ITERS = 8

    # CPU reference always runs: the same physical gates as the XPBD cloth.
    var cpu = cpu_vbd_run[W, H](STEPS, ITERS, 1.0 / 60.0, 0.05)
    s.check(
        abs(Float64(cpu.y[0]) - 2.0) < 1e-6
        and abs(Float64(cpu.x[W - 1]) - 0.05 * Float64(W - 1)) < 1e-6,
        "pinned row fixed",
    )
    var sagged = True
    var above_floor = True
    for i in range(W, W * H):
        if cpu.y[i] > 2.0 + 1e-4:
            sagged = False
        if cpu.y[i] < -1e-6:
            above_floor = False
    s.check(sagged, "cloth sags under gravity")
    s.check(above_floor, "floor plane holds")
    var max_stretch = Float64(0)
    for r in range(H):
        for c in range(W - 1):
            var i = r * W + c
            var dxx = Float64(cpu.x[i + 1] - cpu.x[i])
            var dyy = Float64(cpu.y[i + 1] - cpu.y[i])
            var dzz = Float64(cpu.z[i + 1] - cpu.z[i])
            var l = (dxx * dxx + dyy * dyy + dzz * dzz) ** 0.5
            if l > max_stretch:
                max_stretch = l
    print("  max horizontal neighbour distance:", max_stretch)
    s.check(max_stretch < 0.10, "constraints bounded (rest 0.05)")

    # VBD's implicit stiff springs should hold rest length at least as well
    # as the XPBD path on the identical scene (same steps/iters budget).
    var xp = cpu_cloth_run[W, H](STEPS, ITERS, 1.0 / 60.0, 0.05)
    var xp_stretch = Float64(0)
    for r in range(H):
        for c in range(W - 1):
            var i = r * W + c
            var dxx = Float64(xp.x[i + 1] - xp.x[i])
            var dyy = Float64(xp.y[i + 1] - xp.y[i])
            var dzz = Float64(xp.z[i + 1] - xp.z[i])
            var l = (dxx * dxx + dyy * dyy + dzz * dzz) ** 0.5
            if l > xp_stretch:
                xp_stretch = l
    print("  xpbd same-budget max distance:", xp_stretch)
    s.check(
        max_stretch < xp_stretch * 1.5,
        "vbd constraint quality in xpbd's class",
    )

    comptime if has_accelerator():
        # GPU executes the same two-color Newton sweeps: tight parity.
        var gpu = gpu_vbd_run[W, H](STEPS, ITERS, 1.0 / 60.0, 0.05)
        var max_d = Float64(0)
        for i in range(W * H):
            var d = abs(Float64(gpu.x[i] - cpu.x[i]))
            if abs(Float64(gpu.y[i] - cpu.y[i])) > d:
                d = abs(Float64(gpu.y[i] - cpu.y[i]))
            if abs(Float64(gpu.z[i] - cpu.z[i])) > d:
                d = abs(Float64(gpu.z[i] - cpu.z[i]))
            if d > max_d:
                max_d = d
        print("  max CPU/GPU divergence after", STEPS, "steps:", max_d)
        s.check(max_d < 1e-3, "CPU/GPU parity (same colored Newton sweeps)")
    else:
        print("  (no GPU on this host: parity gate skipped)")

    s.finish()
