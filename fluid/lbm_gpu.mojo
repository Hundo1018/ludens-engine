"""The D3Q19 LBM on a GPU (ROADMAP 17.42 a).

The CPU `Lbm` stays the reference and the setup API: build and configure a
tunnel there (solids, inlet, viscosity), upload it with `LbmGpu(ctx, lbm)`,
step on the device, `download` the distributions back. The three kernels
are the CPU halves line for line -- BGK collide (with the uniform-force
velocity shift), pull streaming with half-way bounce-back, the tunnel's
inlet/outlet -- one thread per cell. Pull streaming writes only the cell it
processes, which is why the CPU sweep and the kernel share their indexing
with no atomics (the reason `Lbm` chose pull in the first place).

Not on the device (yet): the Smagorinsky LES term, interpolated
bounce-back, and the momentum-exchange force sum (it needs a reduction);
`LbmGpu` refuses a CPU grid configured with the first two. One
`DeviceContext` is passed in by its owner (audit F17).
"""

from std.math import ceildiv
from max.gpu import global_idx
from max.gpu.host import DeviceContext, DeviceBuffer
from layout import TileTensor, TensorLayout, row_major
from geometry.vec import Real
from .d3q19 import Q, cx, cy, cz, opposite, equilibrium
from .lbm import Lbm, CELL_FLUID, CELL_SOLID, BC_TUNNEL

comptime dtype = DType.float32
comptime _BLOCK = 128


@always_inline
def _ld[LT: TensorLayout](t: TileTensor[dtype, LT, MutAnyOrigin], i: Int) -> Float32:
    comptime assert t.flat_rank == 1
    return rebind[Scalar[dtype]](t[i])


@always_inline
def _st[LT: TensorLayout](t: TileTensor[dtype, LT, MutAnyOrigin], i: Int, v: Float32):
    comptime assert t.flat_rank == 1
    t[i] = rebind[t.ElementType](v)


def collide_kernel[LF: TensorLayout, LC: TensorLayout](
    f: TileTensor[dtype, LF, MutAnyOrigin],
    flag: TileTensor[dtype, LC, MutAnyOrigin],
    n: Int32, inv_tau: Float32, tau: Float32, force_x: Float32,
):
    var c = global_idx.x
    var nn = Int(n)
    if c >= nn or _ld(flag, c) != Float32(CELL_FLUID):
        return
    var n32 = n
    var c32 = Int32(c)
    var rho = Float32(0)
    var ux = Float32(0)
    var uy = Float32(0)
    var uz = Float32(0)
    comptime for i in range(Q):
        var v = _ld(f, Int(Int32(i) * n32 + c32))
        rho += v
        ux += v * Float32(cx(i))
        uy += v * Float32(cy(i))
        uz += v * Float32(cz(i))
    if rho <= 0:
        return
    ux /= rho
    uy /= rho
    uz /= rho
    if force_x != 0:
        ux += tau * force_x / rho
    comptime for i in range(Q):
        var k = Int(Int32(i) * n32 + c32)
        var fi = _ld(f, k)
        _st(f, k, fi + (equilibrium(i, rho, ux, uy, uz) - fi) * inv_tau)


def stream_kernel[LF: TensorLayout, LC: TensorLayout](
    f: TileTensor[dtype, LF, MutAnyOrigin],
    g: TileTensor[dtype, LF, MutAnyOrigin],
    flag: TileTensor[dtype, LC, MutAnyOrigin],
    nx: Int32, ny: Int32, nz: Int32, tunnel: Int32,
):
    # 32-bit index arithmetic: 64-bit integer division / modulo is emulated
    # on consumer GPUs and was most of this kernel's time.
    var c = Int32(global_idx.x)
    var nn = nx * ny * nz
    if c >= nn or _ld(flag, Int(c)) == Float32(CELL_SOLID):
        return
    var x = c % nx
    var yz = c / nx
    var y = yz % ny
    var z = yz / ny
    comptime for i in range(Q):
        var sx = x - Int32(cx(i))
        var sy = y - Int32(cy(i))
        var sz = z - Int32(cz(i))
        var dst = Int(Int32(i) * nn + c)
        if tunnel != 0 and (sx < 0 or sx >= nx):
            _st(g, dst, _ld(f, dst))
        else:
            if sx < 0:
                sx += nx
            elif sx >= nx:
                sx -= nx
            if sy < 0:
                sy += ny
            elif sy >= ny:
                sy -= ny
            if sz < 0:
                sz += nz
            elif sz >= nz:
                sz -= nz
            var src = (sz * ny + sy) * nx + sx
            if _ld(flag, Int(src)) == Float32(CELL_SOLID):
                _st(g, dst, _ld(f, Int(Int32(opposite(i)) * nn + c)))
            else:
                _st(g, dst, _ld(f, Int(Int32(i) * nn + src)))


def tunnel_kernel[LF: TensorLayout, LC: TensorLayout](
    f: TileTensor[dtype, LF, MutAnyOrigin],
    flag: TileTensor[dtype, LC, MutAnyOrigin],
    nx: Int32, ny: Int32, nz: Int32, inlet_u: Float32,
):
    """One thread per (y, z) column: equilibrium inlet at x = 0 with the
    cell's own density, zero-gradient outlet at x = nx - 1."""
    var k = global_idx.x
    var X = Int(nx)
    var Y = Int(ny)
    var Z = Int(nz)
    if k >= Y * Z:
        return
    var nn = X * Y * Z
    var y = k % Y
    var z = k // Y
    var ci = (z * Y + y) * X
    if _ld(flag, ci) != Float32(CELL_SOLID):
        var rho = Float32(0)
        comptime for i in range(Q):
            rho += _ld(f, i * nn + ci)
        comptime for i in range(Q):
            _st(f, i * nn + ci, equilibrium(i, rho, inlet_u, 0, 0))
    var co = ci + X - 1
    var cu = ci + X - 2
    if _ld(flag, co) != Float32(CELL_SOLID):
        comptime for i in range(Q):
            _st(f, i * nn + co, _ld(f, i * nn + cu))


struct LbmGpu(Movable):
    var fbuf: DeviceBuffer[dtype]
    var gbuf: DeviceBuffer[dtype]
    var flagbuf: DeviceBuffer[dtype]
    var nx: Int
    var ny: Int
    var nz: Int
    var tau: Real
    var inlet_u: Real
    var force_x: Real
    var tunnel: Bool

    def __init__(out self, mut ctx: DeviceContext, cpu: Lbm) raises:
        if cpu.smagorinsky > 0 or cpu.interp:
            raise Error("LbmGpu: LES and interpolated bounce-back run on the CPU only")
        self.nx = cpu.nx
        self.ny = cpu.ny
        self.nz = cpu.nz
        self.tau = cpu.tau
        self.inlet_u = cpu.inlet_u
        self.force_x = cpu.force_x
        self.tunnel = cpu.mode == BC_TUNNEL
        var n = cpu.cells()
        self.fbuf = ctx.enqueue_create_buffer[dtype](Q * n)
        self.gbuf = ctx.enqueue_create_buffer[dtype](Q * n)
        self.flagbuf = ctx.enqueue_create_buffer[dtype](n)
        with self.fbuf.map_to_host() as m:
            var t = TileTensor(m, row_major(Q * n))
            for k in range(Q * n):
                _st(t, k, cpu.f[k])
        with self.gbuf.map_to_host() as m:
            var t = TileTensor(m, row_major(Q * n))
            for k in range(Q * n):
                _st(t, k, cpu.g[k])
        with self.flagbuf.map_to_host() as m:
            var t = TileTensor(m, row_major(n))
            for k in range(n):
                _st(t, k, Float32(cpu.flag[k]))

    def step(mut self, mut ctx: DeviceContext, steps: Int) raises:
        var n = self.nx * self.ny * self.nz
        var grid = ceildiv(n, _BLOCK)
        var cols = self.ny * self.nz
        var fl = TileTensor(self.flagbuf, row_major(n))
        comptime LF = type_of(fl).LayoutType  # same runtime 1-D layout type
        comptime LC = type_of(fl).LayoutType
        comptime kc = collide_kernel[LF, LC]
        comptime ks = stream_kernel[LF, LC]
        comptime kt = tunnel_kernel[LF, LC]
        for _ in range(steps):
            var ft = TileTensor(self.fbuf, row_major(Q * n))
            var gt = TileTensor(self.gbuf, row_major(Q * n))
            ctx.enqueue_function[kc](
                ft, fl, Int32(n), Float32(1) / self.tau, self.tau, self.force_x,
                grid_dim=grid, block_dim=_BLOCK,
            )
            ctx.enqueue_function[ks](
                ft, gt, fl, Int32(self.nx), Int32(self.ny), Int32(self.nz),
                Int32(1 if self.tunnel else 0),
                grid_dim=grid, block_dim=_BLOCK,
            )
            # swap: the streamed values are the new distribution
            var tmp = self.fbuf
            self.fbuf = self.gbuf
            self.gbuf = tmp
            if self.tunnel:
                var fnew = TileTensor(self.fbuf, row_major(Q * n))
                ctx.enqueue_function[kt](
                    fnew, fl, Int32(self.nx), Int32(self.ny), Int32(self.nz), self.inlet_u,
                    grid_dim=ceildiv(cols, _BLOCK), block_dim=_BLOCK,
                )
        ctx.synchronize()

    def download(self, mut cpu: Lbm) raises:
        var n = self.nx * self.ny * self.nz
        with self.fbuf.map_to_host() as m:
            var t = TileTensor(m, row_major(Q * n))
            for k in range(Q * n):
                cpu.f[k] = _ld(t, k)
