"""GPU XPBD cloth prototype: the engine's first GPU-resident physics.

A W×H grid of particles with structural distance constraints, solved as
GATHER-form Jacobi PBD (each particle reads its <=4 neighbours and computes
its own correction — no atomics, deterministic, embarrassingly parallel),
plus gravity, a floor plane, and a pinned top row.

Layout is SoA with one 1D buffer per component (x/y/z separately) — this
sidesteps the width-3 SIMD hazards entirely and is the coalesced-access
GPU layout anyway. The CPU reference (`cpu_cloth_run`) executes the same
arithmetic per particle in the same order, so CPU/GPU parity is a tight gate
(`test_gpu_cloth`), and `bench_gpu_cloth` gives the scaling story.

Everything GPU is guarded by `has_accelerator()`; on CPU-only hosts the module
still compiles and the test passes vacuously.
"""

from std.math import sqrt, ceildiv
from geometry.vec import Real
from physics.self_collide import SelfCollider, resolve_self_collisions
from std.sys import has_accelerator
from std.time import perf_counter_ns
from std.benchmark import keep
from std.gpu import global_idx
from std.gpu.host import DeviceContext, DeviceBuffer
from layout import TileTensor, TensorLayout, row_major

comptime dtype = DType.float32
comptime _G: Float32 = -9.8
comptime _OMEGA: Float32 = 0.5  # Jacobi under-relaxation
comptime _DAMP: Float32 = 0.998


# ---------------------------------------------------------------- kernels
def predict_kernel[LT: TensorLayout](
    x: TileTensor[dtype, LT, MutAnyOrigin],
    y: TileTensor[dtype, LT, MutAnyOrigin],
    z: TileTensor[dtype, LT, MutAnyOrigin],
    vy: TileTensor[dtype, LT, MutAnyOrigin],
    px: TileTensor[dtype, LT, MutAnyOrigin],
    py: TileTensor[dtype, LT, MutAnyOrigin],
    pz: TileTensor[dtype, LT, MutAnyOrigin],
    vx: TileTensor[dtype, LT, MutAnyOrigin],
    vz: TileTensor[dtype, LT, MutAnyOrigin],
    w: TileTensor[dtype, LT, MutAnyOrigin],
    n: Int,
    dt: Float32,
):
    comptime assert x.flat_rank == 1
    var i = global_idx.x
    if i < n:
        var wi = rebind[Scalar[dtype]](w[i])
        if wi > 0:
            var nvy = rebind[Scalar[dtype]](vy[i]) + _G * dt
            vy[i] = rebind[y.ElementType](nvy)
            px[i] = rebind[x.ElementType](
                rebind[Scalar[dtype]](x[i]) + rebind[Scalar[dtype]](vx[i]) * dt
            )
            py[i] = rebind[y.ElementType](
                rebind[Scalar[dtype]](y[i]) + nvy * dt
            )
            pz[i] = rebind[z.ElementType](
                rebind[Scalar[dtype]](z[i]) + rebind[Scalar[dtype]](vz[i]) * dt
            )
        else:
            px[i] = x[i]
            py[i] = y[i]
            pz[i] = z[i]


def jacobi_kernel[LT: TensorLayout](
    px: TileTensor[dtype, LT, MutAnyOrigin],
    py: TileTensor[dtype, LT, MutAnyOrigin],
    pz: TileTensor[dtype, LT, MutAnyOrigin],
    w: TileTensor[dtype, LT, MutAnyOrigin],
    dx: TileTensor[dtype, LT, MutAnyOrigin],
    dy: TileTensor[dtype, LT, MutAnyOrigin],
    dz: TileTensor[dtype, LT, MutAnyOrigin],
    grid_w: Int,
    grid_h: Int,
    rest: Float32,
):
    comptime assert px.flat_rank == 1
    var i = global_idx.x
    var n = grid_w * grid_h
    if i >= n:
        return
    var r = i // grid_w
    var c = i % grid_w
    var ax = rebind[Scalar[dtype]](px[i])
    var ay = rebind[Scalar[dtype]](py[i])
    var az = rebind[Scalar[dtype]](pz[i])
    var wi = rebind[Scalar[dtype]](w[i])
    var sx: Scalar[dtype] = 0
    var sy: Scalar[dtype] = 0
    var sz: Scalar[dtype] = 0
    for k in range(4):
        var rr = r
        var cc = c
        if k == 0:
            cc = c - 1
        elif k == 1:
            cc = c + 1
        elif k == 2:
            rr = r - 1
        else:
            rr = r + 1
        if rr < 0 or rr >= grid_h or cc < 0 or cc >= grid_w:
            continue
        var j = rr * grid_w + cc
        var ddx = ax - rebind[Scalar[dtype]](px[j])
        var ddy = ay - rebind[Scalar[dtype]](py[j])
        var ddz = az - rebind[Scalar[dtype]](pz[j])
        var l = sqrt(ddx * ddx + ddy * ddy + ddz * ddz)
        if l < 1e-9:
            continue
        var wj = rebind[Scalar[dtype]](w[j])
        var wsum = wi + wj
        if wsum <= 0:
            continue
        var coeff = (l - rest) / l * (wi / wsum)
        sx -= ddx * coeff
        sy -= ddy * coeff
        sz -= ddz * coeff
    dx[i] = rebind[px.ElementType](sx)
    dy[i] = rebind[py.ElementType](sy)
    dz[i] = rebind[pz.ElementType](sz)


def apply_kernel[LT: TensorLayout](
    px: TileTensor[dtype, LT, MutAnyOrigin],
    py: TileTensor[dtype, LT, MutAnyOrigin],
    pz: TileTensor[dtype, LT, MutAnyOrigin],
    dx: TileTensor[dtype, LT, MutAnyOrigin],
    dy: TileTensor[dtype, LT, MutAnyOrigin],
    dz: TileTensor[dtype, LT, MutAnyOrigin],
    n: Int,
):
    comptime assert px.flat_rank == 1
    var i = global_idx.x
    if i < n:
        px[i] = px[i] + dx[i] * _OMEGA
        var yy = rebind[Scalar[dtype]](py[i]) + rebind[Scalar[dtype]](dy[i]) * _OMEGA
        if yy < 0:
            yy = 0  # floor plane
        py[i] = rebind[py.ElementType](yy)
        pz[i] = pz[i] + dz[i] * _OMEGA


def finalize_kernel[LT: TensorLayout](
    x: TileTensor[dtype, LT, MutAnyOrigin],
    y: TileTensor[dtype, LT, MutAnyOrigin],
    z: TileTensor[dtype, LT, MutAnyOrigin],
    px: TileTensor[dtype, LT, MutAnyOrigin],
    py: TileTensor[dtype, LT, MutAnyOrigin],
    pz: TileTensor[dtype, LT, MutAnyOrigin],
    vx: TileTensor[dtype, LT, MutAnyOrigin],
    vy: TileTensor[dtype, LT, MutAnyOrigin],
    vz: TileTensor[dtype, LT, MutAnyOrigin],
    n: Int,
    inv_dt: Float32,
):
    comptime assert x.flat_rank == 1
    var i = global_idx.x
    if i < n:
        vx[i] = (px[i] - x[i]) * inv_dt * _DAMP
        vy[i] = (py[i] - y[i]) * inv_dt * _DAMP
        vz[i] = (pz[i] - z[i]) * inv_dt * _DAMP
        x[i] = px[i]
        y[i] = py[i]
        z[i] = pz[i]


# ---------------------------------------------------------------- CPU reference
struct ClothState(Movable, ImplicitlyDeletable):
    """Final particle positions (component lists — no bare List[SIMD3])."""

    var x: List[Float32]
    var y: List[Float32]
    var z: List[Float32]

    def __init__(out self):
        self.x = List[Float32]()
        self.y = List[Float32]()
        self.z = List[Float32]()


def _init_grid[W: Int, H: Int](mut s: ClothState, rest: Float32):
    for r in range(H):
        for c in range(W):
            s.x.append(Float32(c) * rest)
            s.y.append(2.0)
            s.z.append(Float32(r) * rest)


def cpu_cloth_run[W: Int, H: Int](
    steps: Int, iters: Int, dt: Float32, rest: Float32,
    self_thickness: Real = 0,
) -> ClothState:
    """Sequential reference: same gather-Jacobi arithmetic as the kernels.

    `self_thickness > 0` turns on cloth self-collision
    (`physics/self_collide.mojo`), applied once per constraint iteration so it
    is solved together with the distance constraints rather than layered on
    afterwards. Zero keeps the previous behaviour bit for bit, which is what
    lets the existing tests stay untouched."""
    comptime n = W * H
    var s = ClothState()
    _init_grid[W, H](s, rest)
    # cell size = thickness: one hash cell per interaction radius, so the 27
    # neighbouring cells are exactly the candidates within range
    var sc = SelfCollider(
        self_thickness if self_thickness > 0 else Real(1)
    )
    var vx = List[Float32]()
    var vy = List[Float32]()
    var vz = List[Float32]()
    var w = List[Float32]()
    for i in range(n):
        vx.append(0)
        vy.append(0)
        vz.append(0)
        w.append(Float32(0) if i < W else Float32(1))  # top row pinned
    var px = List[Float32]()
    var py = List[Float32]()
    var pz = List[Float32]()
    var dx = List[Float32]()
    var dy = List[Float32]()
    var dz = List[Float32]()
    for _ in range(n):
        px.append(0)
        py.append(0)
        pz.append(0)
        dx.append(0)
        dy.append(0)
        dz.append(0)
    for _ in range(steps):
        for i in range(n):
            if w[i] > 0:
                vy[i] += _G * dt
                px[i] = s.x[i] + vx[i] * dt
                py[i] = s.y[i] + vy[i] * dt
                pz[i] = s.z[i] + vz[i] * dt
            else:
                px[i] = s.x[i]
                py[i] = s.y[i]
                pz[i] = s.z[i]
        for _ in range(iters):
            for i in range(n):
                var r = i // W
                var c = i % W
                var sx: Float32 = 0
                var sy: Float32 = 0
                var sz: Float32 = 0
                for k in range(4):
                    var rr = r
                    var cc = c
                    if k == 0:
                        cc = c - 1
                    elif k == 1:
                        cc = c + 1
                    elif k == 2:
                        rr = r - 1
                    else:
                        rr = r + 1
                    if rr < 0 or rr >= H or cc < 0 or cc >= W:
                        continue
                    var j = rr * W + cc
                    var ddx = px[i] - px[j]
                    var ddy = py[i] - py[j]
                    var ddz = pz[i] - pz[j]
                    var l = sqrt(ddx * ddx + ddy * ddy + ddz * ddz)
                    if l < 1e-9:
                        continue
                    var wsum = w[i] + w[j]
                    if wsum <= 0:
                        continue
                    var coeff = (l - rest) / l * (w[i] / wsum)
                    sx -= ddx * coeff
                    sy -= ddy * coeff
                    sz -= ddz * coeff
                dx[i] = sx
                dy[i] = sy
                dz[i] = sz
            for i in range(n):
                px[i] += dx[i] * _OMEGA
                py[i] += dy[i] * _OMEGA
                if py[i] < 0:
                    py[i] = 0
                pz[i] += dz[i] * _OMEGA
            if self_thickness > 0:
                _ = resolve_self_collisions(
                    px, py, pz, w, W, self_thickness, sc
                )
        for i in range(n):
            vx[i] = (px[i] - s.x[i]) / dt * _DAMP
            vy[i] = (py[i] - s.y[i]) / dt * _DAMP
            vz[i] = (pz[i] - s.z[i]) / dt * _DAMP
            s.x[i] = px[i]
            s.y[i] = py[i]
            s.z[i] = pz[i]
    return s^


# ---------------------------------------------------------------- GPU driver
def gpu_cloth_run[W: Int, H: Int](
    steps: Int, iters: Int, dt: Float32, rest: Float32
) raises -> ClothState:
    """The same cloth on the GPU (guarded: raises if no accelerator).
    Owns its `DeviceContext`. NOTE: creating many contexts in one process
    hangs on this nightly (root-caused 2026-07-13 via the cloth benchmarks) —
    code that runs several GPU rollouts (benchmarks) must build ONE context
    and call `gpu_cloth_run_ctx` instead of looping this."""
    var ctx = DeviceContext()
    return gpu_cloth_run_ctx[W, H](ctx, steps, iters, dt, rest)


@fieldwise_init
struct GpuClothTiming(Copyable, ImplicitlyCopyable, Movable, ImplicitlyDeletable):
    """Wall-clock split of one GPU rollout: what is transfer and what is compute.

    The end-to-end GPU rows fold host<->device traffic into the total; these
    fields separate it. `download_ns` accumulates EVERY readback, so a
    per-frame-readback rollout (`readback_every=1`) shows the cost a real game
    pays when it pulls physics results back to the CPU each frame."""

    var upload_ns: Int
    var compute_ns: Int
    var download_ns: Int
    var total_ns: Int

    @staticmethod
    def zero() -> Self:
        return Self(0, 0, 0, 0)


def gpu_cloth_run_ctx[W: Int, H: Int](
    mut ctx: DeviceContext, steps: Int, iters: Int, dt: Float32, rest: Float32
) raises -> ClothState:
    """Cloth on a caller-provided context (shared across GPU rollouts)."""
    var timing = GpuClothTiming.zero()
    return gpu_cloth_run_ctx_timed[W, H](ctx, steps, iters, dt, rest, 0, timing)


def gpu_cloth_run_ctx_timed[W: Int, H: Int](
    mut ctx: DeviceContext,
    steps: Int,
    iters: Int,
    dt: Float32,
    rest: Float32,
    readback_every: Int,
    mut timing: GpuClothTiming,
) raises -> ClothState:
    """The single GPU rollout body, instrumented.

    `readback_every == 0` downloads the final state once (what
    `gpu_cloth_run_ctx` does, and what the end-to-end rows measure).
    `readback_every == k > 0` also drains x/y/z back to the host every `k`
    steps — the per-frame-readback shape of a real game loop, which forces a
    device sync per frame and cannot hide latency behind the enqueue pipeline.
    Phase timings land in `timing`; the returned state is identical either way
    (the readback is a copy, not a mutation), so `test_gpu_cloth` parity holds
    for both settings."""
    var fn_t0 = Int(perf_counter_ns())
    comptime n = W * H
    comptime layout = row_major[n]()
    comptime BLOCK = 256
    var host = ClothState()
    _init_grid[W, H](host, rest)

    var bufs = List[DeviceBuffer[dtype]]()
    for _ in range(13):
        var b = ctx.enqueue_create_buffer[dtype](n)
        b.enqueue_fill(0.0)
        bufs.append(b^)
    var bx = bufs[0]
    var by = bufs[1]
    var bz = bufs[2]
    var bvx = bufs[3]
    var bvy = bufs[4]
    var bvz = bufs[5]
    var bpx = bufs[6]
    var bpy = bufs[7]
    var bpz = bufs[8]
    var bdx = bufs[9]
    var bdy = bufs[10]
    var bdz = bufs[11]
    var bw = bufs[12]
    # upload initial state (host -> device)
    var up_t0 = Int(perf_counter_ns())
    with bx.map_to_host() as m:
        var t = TileTensor(m, layout)
        for i in range(n):
            t[i] = host.x[i]
    with by.map_to_host() as m:
        var t = TileTensor(m, layout)
        for i in range(n):
            t[i] = host.y[i]
    with bz.map_to_host() as m:
        var t = TileTensor(m, layout)
        for i in range(n):
            t[i] = host.z[i]
    with bw.map_to_host() as m:
        var t = TileTensor(m, layout)
        for i in range(n):
            t[i] = 0 if i < W else 1
    timing.upload_ns = Int(perf_counter_ns()) - up_t0

    var x = TileTensor(bx, layout)
    var y = TileTensor(by, layout)
    var z = TileTensor(bz, layout)
    var vx = TileTensor(bvx, layout)
    var vy = TileTensor(bvy, layout)
    var vz = TileTensor(bvz, layout)
    var px = TileTensor(bpx, layout)
    var py = TileTensor(bpy, layout)
    var pz = TileTensor(bpz, layout)
    var dx = TileTensor(bdx, layout)
    var dy = TileTensor(bdy, layout)
    var dz = TileTensor(bdz, layout)
    var w = TileTensor(bw, layout)

    comptime kp = predict_kernel[type_of(layout)]
    comptime kj = jacobi_kernel[type_of(layout)]
    comptime ka = apply_kernel[type_of(layout)]
    comptime kf = finalize_kernel[type_of(layout)]
    comptime GRID = ceildiv(n, BLOCK)
    # Compute is enqueued asynchronously, so the timed compute region must
    # include the `synchronize()` that actually waits for the device — timing
    # the enqueue loop alone would only price the launch calls.
    var compute_ns = 0
    var download_ns = 0
    var rb_sink = Float32(0)
    var phase_t0 = Int(perf_counter_ns())
    for stp in range(steps):
        ctx.enqueue_function[kp](
            x, y, z, vy, px, py, pz, vx, vz, w, n, dt,
            grid_dim=GRID, block_dim=BLOCK,
        )
        for _ in range(iters):
            ctx.enqueue_function[kj](
                px, py, pz, w, dx, dy, dz, W, H, rest,
                grid_dim=GRID, block_dim=BLOCK,
            )
            ctx.enqueue_function[ka](
                px, py, pz, dx, dy, dz, n, grid_dim=GRID, block_dim=BLOCK
            )
        ctx.enqueue_function[kf](
            x, y, z, px, py, pz, vx, vy, vz, n, 1.0 / dt,
            grid_dim=GRID, block_dim=BLOCK,
        )
        if readback_every > 0 and (stp + 1) % readback_every == 0:
            # A game reading positions back each frame: the sync drains the
            # pipeline (no launch overlap left to hide), then three columns
            # cross the bus. Summed into a sink so the copy cannot be elided.
            ctx.synchronize()
            compute_ns += Int(perf_counter_ns()) - phase_t0
            var rb_t0 = Int(perf_counter_ns())
            with bx.map_to_host() as m:
                var t = TileTensor(m, layout)
                for i in range(n):
                    rb_sink += rebind[Scalar[dtype]](t[i])
            with by.map_to_host() as m:
                var t = TileTensor(m, layout)
                for i in range(n):
                    rb_sink += rebind[Scalar[dtype]](t[i])
            with bz.map_to_host() as m:
                var t = TileTensor(m, layout)
                for i in range(n):
                    rb_sink += rebind[Scalar[dtype]](t[i])
            download_ns += Int(perf_counter_ns()) - rb_t0
            phase_t0 = Int(perf_counter_ns())
    ctx.synchronize()
    compute_ns += Int(perf_counter_ns()) - phase_t0
    timing.compute_ns = compute_ns
    keep(rb_sink)
    var dl_t0 = Int(perf_counter_ns())
    var out = ClothState()
    with bx.map_to_host() as m:
        var t = TileTensor(m, layout)
        for i in range(n):
            out.x.append(rebind[Scalar[dtype]](t[i]))
    with by.map_to_host() as m:
        var t = TileTensor(m, layout)
        for i in range(n):
            out.y.append(rebind[Scalar[dtype]](t[i]))
    with bz.map_to_host() as m:
        var t = TileTensor(m, layout)
        for i in range(n):
            out.z.append(rebind[Scalar[dtype]](t[i]))
    timing.download_ns = download_ns + (Int(perf_counter_ns()) - dl_t0)
    timing.total_ns = Int(perf_counter_ns()) - fn_t0
    return out^
