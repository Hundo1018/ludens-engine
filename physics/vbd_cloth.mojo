"""VBD cloth prototype: vertex block descent on the same cloth as `gpu_cloth`.

VBD (vertex block descent, arXiv:2403.06321) minimizes the implicit-Euler
variational energy G(x) = Σᵢ (mᵢ/2h²)|xᵢ − yᵢ|² + Σ_c E_c(x) by block
coordinate descent: each vertex takes one LOCAL 3×3 Newton step
(xᵢ ← xᵢ − Hᵢ⁻¹gᵢ) against its incident spring energies, sweeping vertices
Gauss-Seidel style. Parallelism comes from GRAPH COLORING — on the 4-neighbour
grid a checkerboard 2-coloring makes every edge bichromatic, so all vertices
of one color update simultaneously with no races and no atomics (each vertex
writes only itself, reads only the frozen other color). That keeps the run
deterministic and lets the CPU reference execute the exact same arithmetic in
the same order — the same CPU/GPU parity scheme as `gpu_cloth` (XPBD), which
this module shares scene, layout and buffers infrastructure with.

Spring energy k/2(l−rest)²: gradient k(l−rest)·d̂, Hessian
k·d̂d̂ᵀ + k(1−rest/l)(I−d̂d̂ᵀ) with the lateral term clamped ≥ 0 (the standard
SPD projection). The floor is the same position clamp as the XPBD path — kept
identical on purpose so the XPBD-vs-VBD benchmark compares SOLVERS, not
scenes. Implicit Euler target y = x + h·v + h²·g.
"""

from std.math import sqrt, ceildiv
from std.sys import has_accelerator
from std.gpu import global_idx
from std.gpu.host import DeviceContext, DeviceBuffer
from layout import TileTensor, TensorLayout, row_major
from .gpu_cloth import ClothState, _init_grid

comptime dtype = DType.float32
comptime _G: Float32 = -9.8
comptime _DAMP: Float32 = 0.998
comptime _K: Float32 = 2e5  # spring stiffness (implicit solve: stiff is fine)


# ------------------------------------------------------------ vertex update
def _vbd_vertex(
    rest: Float32,
    mh2: Float32,
    xi0: Float32,
    yi0: Float32,
    zi0: Float32,
    tx: Float32,
    ty: Float32,
    tz: Float32,
    nx: InlineArray[Float32, 4],
    ny: InlineArray[Float32, 4],
    nz: InlineArray[Float32, 4],
    nok: InlineArray[Bool, 4],
) -> Tuple[Float32, Float32, Float32]:
    """One local Newton step for vertex `i`: returns the new position.
    Pure function of the vertex, its inertia target and its (frozen)
    neighbours — the single arithmetic body both CPU and GPU execute."""
    var gx = mh2 * (xi0 - tx)
    var gy = mh2 * (yi0 - ty)
    var gz = mh2 * (zi0 - tz)
    var h00 = mh2
    var h11 = mh2
    var h22 = mh2
    var h01: Float32 = 0
    var h02: Float32 = 0
    var h12: Float32 = 0
    for k in range(4):
        if not nok[k]:
            continue
        var dx = xi0 - nx[k]
        var dy = yi0 - ny[k]
        var dz = zi0 - nz[k]
        var l = sqrt(dx * dx + dy * dy + dz * dz)
        if l < 1e-9:
            continue
        var ux = dx / l
        var uy = dy / l
        var uz = dz / l
        var t = _K * (l - rest)
        gx += t * ux
        gy += t * uy
        gz += t * uz
        # H += (k − β)·ûûᵀ + β·I, β = k(1 − rest/l) clamped ≥ 0 (SPD)
        var beta = _K * (1 - rest / l)
        if beta < 0:
            beta = 0
        var a = _K - beta
        h00 += a * ux * ux + beta
        h11 += a * uy * uy + beta
        h22 += a * uz * uz + beta
        h01 += a * ux * uy
        h02 += a * ux * uz
        h12 += a * uy * uz
    # Cramer solve of the symmetric 3×3: H·Δ = −g
    var c00 = h11 * h22 - h12 * h12
    var c01 = h01 * h22 - h12 * h02
    var c02 = h01 * h12 - h11 * h02
    var det = h00 * c00 - h01 * c01 + h02 * c02
    if abs(det) < 1e-12:
        return (xi0, yi0, zi0)
    var inv = 1.0 / det
    var c11 = h00 * h22 - h02 * h02
    var c12 = h00 * h12 - h01 * h02
    var c22 = h00 * h11 - h01 * h01
    var ddx = -(c00 * gx - c01 * gy + c02 * gz) * inv
    var ddy = -(-c01 * gx + c11 * gy - c12 * gz) * inv
    var ddz = -(c02 * gx - c12 * gy + c22 * gz) * inv
    var xo = xi0 + ddx
    var yo = yi0 + ddy
    var zo = zi0 + ddz
    if yo < 0:
        yo = 0  # floor plane, same clamp as the XPBD path
    return (xo, yo, zo)


# ---------------------------------------------------------------- kernels
def vbd_predict_kernel[LT: TensorLayout](
    x: TileTensor[dtype, LT, MutAnyOrigin],
    y: TileTensor[dtype, LT, MutAnyOrigin],
    z: TileTensor[dtype, LT, MutAnyOrigin],
    vx: TileTensor[dtype, LT, MutAnyOrigin],
    vy: TileTensor[dtype, LT, MutAnyOrigin],
    vz: TileTensor[dtype, LT, MutAnyOrigin],
    tx: TileTensor[dtype, LT, MutAnyOrigin],
    ty: TileTensor[dtype, LT, MutAnyOrigin],
    tz: TileTensor[dtype, LT, MutAnyOrigin],
    ox: TileTensor[dtype, LT, MutAnyOrigin],
    oy: TileTensor[dtype, LT, MutAnyOrigin],
    oz: TileTensor[dtype, LT, MutAnyOrigin],
    w: TileTensor[dtype, LT, MutAnyOrigin],
    n: Int,
    dt: Float32,
):
    comptime assert x.flat_rank == 1
    var i = global_idx.x
    if i >= n:
        return
    ox[i] = x[i]
    oy[i] = y[i]
    oz[i] = z[i]
    if rebind[Scalar[dtype]](w[i]) > 0:
        var px = rebind[Scalar[dtype]](x[i]) + rebind[Scalar[dtype]](vx[i]) * dt
        var py = rebind[Scalar[dtype]](y[i]) + (
            rebind[Scalar[dtype]](vy[i]) + _G * dt
        ) * dt
        var pz = rebind[Scalar[dtype]](z[i]) + rebind[Scalar[dtype]](vz[i]) * dt
        tx[i] = rebind[x.ElementType](px)
        ty[i] = rebind[y.ElementType](py)
        tz[i] = rebind[z.ElementType](pz)
        x[i] = rebind[x.ElementType](px)  # descent starts at the target
        y[i] = rebind[y.ElementType](py)
        z[i] = rebind[z.ElementType](pz)
    else:
        tx[i] = x[i]
        ty[i] = y[i]
        tz[i] = z[i]


def vbd_solve_kernel[LT: TensorLayout](
    x: TileTensor[dtype, LT, MutAnyOrigin],
    y: TileTensor[dtype, LT, MutAnyOrigin],
    z: TileTensor[dtype, LT, MutAnyOrigin],
    tx: TileTensor[dtype, LT, MutAnyOrigin],
    ty: TileTensor[dtype, LT, MutAnyOrigin],
    tz: TileTensor[dtype, LT, MutAnyOrigin],
    w: TileTensor[dtype, LT, MutAnyOrigin],
    grid_w: Int,
    grid_h: Int,
    rest: Float32,
    mh2: Float32,
    color: Int,
):
    comptime assert x.flat_rank == 1
    var i = global_idx.x
    var n = grid_w * grid_h
    if i >= n:
        return
    var r = i // grid_w
    var c = i % grid_w
    if (r + c) % 2 != color:
        return
    if rebind[Scalar[dtype]](w[i]) <= 0:
        return
    var nx = InlineArray[Float32, 4](fill=0)
    var ny = InlineArray[Float32, 4](fill=0)
    var nz = InlineArray[Float32, 4](fill=0)
    var nok = InlineArray[Bool, 4](fill=False)
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
        nok[k] = True
        nx[k] = rebind[Scalar[dtype]](x[j])
        ny[k] = rebind[Scalar[dtype]](y[j])
        nz[k] = rebind[Scalar[dtype]](z[j])
    var res = _vbd_vertex(
        rest, mh2,
        rebind[Scalar[dtype]](x[i]),
        rebind[Scalar[dtype]](y[i]),
        rebind[Scalar[dtype]](z[i]),
        rebind[Scalar[dtype]](tx[i]),
        rebind[Scalar[dtype]](ty[i]),
        rebind[Scalar[dtype]](tz[i]),
        nx, ny, nz, nok,
    )
    x[i] = rebind[x.ElementType](res[0])
    y[i] = rebind[y.ElementType](res[1])
    z[i] = rebind[z.ElementType](res[2])


def vbd_finalize_kernel[LT: TensorLayout](
    x: TileTensor[dtype, LT, MutAnyOrigin],
    y: TileTensor[dtype, LT, MutAnyOrigin],
    z: TileTensor[dtype, LT, MutAnyOrigin],
    ox: TileTensor[dtype, LT, MutAnyOrigin],
    oy: TileTensor[dtype, LT, MutAnyOrigin],
    oz: TileTensor[dtype, LT, MutAnyOrigin],
    vx: TileTensor[dtype, LT, MutAnyOrigin],
    vy: TileTensor[dtype, LT, MutAnyOrigin],
    vz: TileTensor[dtype, LT, MutAnyOrigin],
    n: Int,
    inv_dt: Float32,
):
    comptime assert x.flat_rank == 1
    var i = global_idx.x
    if i < n:
        vx[i] = (x[i] - ox[i]) * inv_dt * _DAMP
        vy[i] = (y[i] - oy[i]) * inv_dt * _DAMP
        vz[i] = (z[i] - oz[i]) * inv_dt * _DAMP


# ---------------------------------------------------------------- CPU reference
def cpu_vbd_run[W: Int, H: Int](
    steps: Int, iters: Int, dt: Float32, rest: Float32
) -> ClothState:
    """Sequential reference: the same per-vertex Newton arithmetic, swept in
    the same two color passes (within a color the update is order-free, so
    index order here ≡ parallel on the GPU)."""
    comptime n = W * H
    var mh2 = 1.0 / (dt * dt)  # unit mass
    var s = ClothState()
    _init_grid[W, H](s, rest)
    var vx = List[Float32]()
    var vy = List[Float32]()
    var vz = List[Float32]()
    var w = List[Float32]()
    for i in range(n):
        vx.append(0)
        vy.append(0)
        vz.append(0)
        w.append(Float32(0) if i < W else Float32(1))  # top row pinned
    var tx = List[Float32]()
    var ty = List[Float32]()
    var tz = List[Float32]()
    var ox = List[Float32]()
    var oy = List[Float32]()
    var oz = List[Float32]()
    for _ in range(n):
        tx.append(0)
        ty.append(0)
        tz.append(0)
        ox.append(0)
        oy.append(0)
        oz.append(0)
    for _ in range(steps):
        for i in range(n):
            ox[i] = s.x[i]
            oy[i] = s.y[i]
            oz[i] = s.z[i]
            if w[i] > 0:
                tx[i] = s.x[i] + vx[i] * dt
                ty[i] = s.y[i] + (vy[i] + _G * dt) * dt
                tz[i] = s.z[i] + vz[i] * dt
                s.x[i] = tx[i]
                s.y[i] = ty[i]
                s.z[i] = tz[i]
            else:
                tx[i] = s.x[i]
                ty[i] = s.y[i]
                tz[i] = s.z[i]
        for _ in range(iters):
            for color in range(2):
                for i in range(n):
                    var r = i // W
                    var c = i % W
                    if (r + c) % 2 != color or w[i] <= 0:
                        continue
                    var nx = InlineArray[Float32, 4](fill=0)
                    var ny = InlineArray[Float32, 4](fill=0)
                    var nz = InlineArray[Float32, 4](fill=0)
                    var nok = InlineArray[Bool, 4](fill=False)
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
                        nok[k] = True
                        nx[k] = s.x[j]
                        ny[k] = s.y[j]
                        nz[k] = s.z[j]
                    var res = _vbd_vertex(
                        rest, mh2,
                        s.x[i], s.y[i], s.z[i],
                        tx[i], ty[i], tz[i],
                        nx, ny, nz, nok,
                    )
                    s.x[i] = res[0]
                    s.y[i] = res[1]
                    s.z[i] = res[2]
        for i in range(n):
            vx[i] = (s.x[i] - ox[i]) / dt * _DAMP
            vy[i] = (s.y[i] - oy[i]) / dt * _DAMP
            vz[i] = (s.z[i] - oz[i]) / dt * _DAMP
    return s^


# ---------------------------------------------------------------- GPU driver
def gpu_vbd_run[W: Int, H: Int](
    steps: Int, iters: Int, dt: Float32, rest: Float32
) raises -> ClothState:
    """The same VBD sweep on the GPU (guarded: raises if no accelerator).
    Owns its context; benchmarks that run several rollouts must share one
    context via `gpu_vbd_run_ctx` (see `gpu_cloth.gpu_cloth_run` note)."""
    var ctx = DeviceContext()
    return gpu_vbd_run_ctx[W, H](ctx, steps, iters, dt, rest)


def gpu_vbd_run_ctx[W: Int, H: Int](
    mut ctx: DeviceContext, steps: Int, iters: Int, dt: Float32, rest: Float32
) raises -> ClothState:
    """VBD on a caller-provided context (shared across GPU rollouts)."""
    comptime n = W * H
    comptime layout = row_major[n]()
    comptime BLOCK = 256
    var mh2 = Float32(1.0) / (dt * dt)
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
    var btx = bufs[6]
    var bty = bufs[7]
    var btz = bufs[8]
    var box = bufs[9]
    var boy = bufs[10]
    var boz = bufs[11]
    var bw = bufs[12]
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

    var x = TileTensor(bx, layout)
    var y = TileTensor(by, layout)
    var z = TileTensor(bz, layout)
    var vx = TileTensor(bvx, layout)
    var vy = TileTensor(bvy, layout)
    var vz = TileTensor(bvz, layout)
    var tx = TileTensor(btx, layout)
    var ty = TileTensor(bty, layout)
    var tz = TileTensor(btz, layout)
    var ox = TileTensor(box, layout)
    var oy = TileTensor(boy, layout)
    var oz = TileTensor(boz, layout)
    var w = TileTensor(bw, layout)

    comptime kp = vbd_predict_kernel[type_of(layout)]
    comptime ks = vbd_solve_kernel[type_of(layout)]
    comptime kf = vbd_finalize_kernel[type_of(layout)]
    comptime GRID = ceildiv(n, BLOCK)
    for _ in range(steps):
        ctx.enqueue_function[kp](
            x, y, z, vx, vy, vz, tx, ty, tz, ox, oy, oz, w, n, dt,
            grid_dim=GRID, block_dim=BLOCK,
        )
        for _ in range(iters):
            for color in range(2):
                ctx.enqueue_function[ks](
                    x, y, z, tx, ty, tz, w, W, H, rest, mh2, color,
                    grid_dim=GRID, block_dim=BLOCK,
                )
        ctx.enqueue_function[kf](
            x, y, z, ox, oy, oz, vx, vy, vz, n, 1.0 / dt,
            grid_dim=GRID, block_dim=BLOCK,
        )
    ctx.synchronize()
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
    return out^
