"""GPU contact solver: the graph-coloured sweep of `ContactScene6` on a device
(ROADMAP 17.17).

The CPU keeps what it is good at and what the GPU gains nothing from at this
scale: broadphase + narrowphase collection, island labels, the colouring,
and after the frame the restitution pass, sleep, NaN quarantine, events and
the warm-start cache (`ContactScene6.begin_external_solve` /
`end_external_solve`). The device runs the substep loop: gravity, warm start
per colour, `iters` soft sweeps per colour, pose integration, two relax
sweeps per colour -- the exact order of `ContactScene6.step(cfg.colored=True)`.

Inside a colour no two contacts share a dynamic body, so one thread per
contact writes disjoint bodies: Jacobi within the colour, Gauss-Seidel
across colours, the same schedule the CPU runs serially. The kernels load a
body into a real `QuatBody6` and call its own `velocity_at` /
`angular_factor` / `apply_impulse` / `integrate_force` / `integrate_pose`, so
the device runs the production body arithmetic rather than a re-derivation;
what can differ from the CPU is only the compiler's contraction of
multiply-adds (`test_gpu_contact` measures it).

Scope: `QuatBody6` scenes without joints, soft bodies or CCD (`raise`s
otherwise). One `DeviceContext` is passed in by its single owner (audit F17):
nothing here creates one.

Layout: bodies are `_BS` floats each (pos, vel, omega, q, mass, principal
inertia, and the solver's per-frame flags), contacts `_CS` floats each (ids,
point count, combined friction, normal, per point depth / anchors /
accumulators). Both are uploaded every frame and read back at its end; the
bench isolates that transfer.
"""

from std.math import ceildiv
from std.time import perf_counter_ns
from max.gpu import global_idx
from max.gpu.host import DeviceContext, DeviceBuffer
from layout import TileTensor, TensorLayout, row_major
from geometry.vec import Real, Vec3, dot, tangent_basis
from geometry.quat import Quat
from .rigid6 import QuatBody6, Inertia3
from .contact6 import ContactConstraint
from .material import combine
from .solver_config import SolverConfig
from .solver6 import ContactScene6

comptime dtype = DType.float32
comptime _BS = 24  # floats per body
comptime _CS = 48  # floats per contact
comptime _BLOCK = 128

# body record offsets
comptime _POS = 0
comptime _VEL = 3
comptime _OMG = 6
comptime _Q = 9
comptime _MASS = 13
comptime _INR = 14
comptime _DYN = 17  # is_dynamic
comptime _MOV = 18  # moves (dynamic or kinematic)
comptime _INACT = 19  # inactive: static, removed or sleeping
comptime _GRAV = 20  # dynamic and awake
comptime _INERT = 21  # impulse_inert

# contact record offsets
comptime _A = 0
comptime _B = 1
comptime _CNT = 2
comptime _MU = 3
comptime _N = 4
comptime _DEP = 7
comptime _RA = 11
comptime _RB = 23
comptime _ACC = 35
comptime _AT1 = 39
comptime _AT2 = 43


# ------------------------------------------------------------ device helpers


@always_inline
def _ld[LT: TensorLayout](t: TileTensor[dtype, LT, MutAnyOrigin], i: Int) -> Float32:
    comptime assert t.flat_rank == 1
    return rebind[Scalar[dtype]](t[i])


@always_inline
def _st[LT: TensorLayout](t: TileTensor[dtype, LT, MutAnyOrigin], i: Int, v: Float32):
    comptime assert t.flat_rank == 1
    t[i] = rebind[t.ElementType](v)


@always_inline
def _v3[LT: TensorLayout](t: TileTensor[dtype, LT, MutAnyOrigin], o: Int) -> Vec3:
    return Vec3(_ld(t, o), _ld(t, o + 1), _ld(t, o + 2), 0)


@always_inline
def _put3[LT: TensorLayout](t: TileTensor[dtype, LT, MutAnyOrigin], o: Int, v: Vec3):
    _st(t, o, v[0])
    _st(t, o + 1, v[1])
    _st(t, o + 2, v[2])


@always_inline
def _body[LT: TensorLayout](b: TileTensor[dtype, LT, MutAnyOrigin], i: Int) -> QuatBody6:
    var o = i * _BS
    return QuatBody6(
        _v3(b, o + _POS),
        Quat(_ld(b, o + _Q), _ld(b, o + _Q + 1), _ld(b, o + _Q + 2), _ld(b, o + _Q + 3)),
        _v3(b, o + _VEL),
        _v3(b, o + _OMG),
        Inertia3(_ld(b, o + _MASS), _ld(b, o + _INR), _ld(b, o + _INR + 1), _ld(b, o + _INR + 2)),
    )


@always_inline
def _save[LT: TensorLayout](b: TileTensor[dtype, LT, MutAnyOrigin], i: Int, body: QuatBody6):
    var o = i * _BS
    _put3(b, o + _POS, body.pos)
    _put3(b, o + _VEL, body.vel)
    _put3(b, o + _OMG, body.omega)
    _st(b, o + _Q, body.q.x)
    _st(b, o + _Q + 1, body.q.y)
    _st(b, o + _Q + 2, body.q.z)
    _st(b, o + _Q + 3, body.q.w)


def _b(x: Bool) -> Float32:
    return Float32(1) if x else Float32(0)


@always_inline
def _flag[LT: TensorLayout](b: TileTensor[dtype, LT, MutAnyOrigin], i: Int, f: Int) -> Bool:
    return _ld(b, i * _BS + f) != 0


# ------------------------------------------------------------------ kernels


def gravity_kernel[LT: TensorLayout](
    b: TileTensor[dtype, LT, MutAnyOrigin],
    n: Int32, h: Float32, gx: Float32, gy: Float32, gz: Float32,
):
    var i = global_idx.x
    if i < Int(n) and _flag(b, i, _GRAV):
        var body = _body(b, i)
        var f = Vec3(gx, gy, gz, 0) / body.inv_mass()
        body.integrate_force(h, f, Vec3(0, 0, 0, 0))
        _save(b, i, body)


def integrate_kernel[LT: TensorLayout](
    b: TileTensor[dtype, LT, MutAnyOrigin], n: Int32, h: Float32
):
    var i = global_idx.x
    if i < Int(n) and not _flag(b, i, _INACT):
        var body = _body(b, i)
        body.integrate_pose(h)
        _save(b, i, body)


def warm_kernel[LT: TensorLayout, LC: TensorLayout](
    b: TileTensor[dtype, LT, MutAnyOrigin],
    c: TileTensor[dtype, LC, MutAnyOrigin],
    lo: Int32, count: Int32,
):
    """`contact6.warm_start_contacts` for one colour's contacts."""
    var k = global_idx.x
    if k >= Int(count):
        return
    var o = (Int(lo) + k) * _CS
    var ia = Int(_ld(c, o + _A))
    var ib = Int(_ld(c, o + _B))
    if _flag(b, ia, _INERT) and _flag(b, ib, _INERT):
        return
    var A = _body(b, ia)
    var B = _body(b, ib)
    var dyn_a = _flag(b, ia, _DYN)
    var dyn_b = _flag(b, ib, _DYN)
    var n = _v3(c, o + _N)
    var tb = tangent_basis(n)
    for p in range(Int(_ld(c, o + _CNT))):
        var j = (
            n * _ld(c, o + _ACC + p)
            + tb[0] * _ld(c, o + _AT1 + p)
            + tb[1] * _ld(c, o + _AT2 + p)
        )
        if dyn_a:
            A.apply_impulse(-j, A.act(_v3(c, o + _RA + 3 * p)))
        if dyn_b:
            B.apply_impulse(j, B.act(_v3(c, o + _RB + 3 * p)))
    if dyn_a:
        _save(b, ia, A)
    if dyn_b:
        _save(b, ib, B)


def solve_kernel[LT: TensorLayout, LC: TensorLayout](
    b: TileTensor[dtype, LT, MutAnyOrigin],
    c: TileTensor[dtype, LC, MutAnyOrigin],
    lo: Int32, count: Int32,
    h: Float32, bias_rate: Float32, mass_scale: Float32, impulse_scale: Float32,
    use_bias: Int32,
):
    """`contact6.solve_contact`, line for line, one thread per contact."""
    var k = global_idx.x
    if k >= Int(count):
        return
    var o = (Int(lo) + k) * _CS
    var ia = Int(_ld(c, o + _A))
    var ib = Int(_ld(c, o + _B))
    if _flag(b, ia, _INERT) and _flag(b, ib, _INERT):
        return
    var A = _body(b, ia)
    var B = _body(b, ib)
    var dyn_a = _flag(b, ia, _DYN)
    var dyn_b = _flag(b, ib, _DYN)
    var mov_a = _flag(b, ia, _MOV)
    var mov_b = _flag(b, ib, _MOV)
    var n = _v3(c, o + _N)
    var pair_mu = _ld(c, o + _MU)
    for p in range(Int(_ld(c, o + _CNT))):
        var pwa = A.act(_v3(c, o + _RA + 3 * p))
        var pwb = B.act(_v3(c, o + _RB + 3 * p))
        var d = _ld(c, o + _DEP + p) - dot(pwb - pwa, n)
        var va = Vec3(0, 0, 0, 0)
        var ka = Real(0)
        if mov_a:
            va = A.velocity_at(pwa)
        if dyn_a:
            ka = A.inv_mass() + A.angular_factor(pwa - A.position(), n)
        var vb = Vec3(0, 0, 0, 0)
        var kb = Real(0)
        if mov_b:
            vb = B.velocity_at(pwb)
        if dyn_b:
            kb = B.inv_mass() + B.angular_factor(pwb - B.position(), n)
        var denom = ka + kb
        if denom <= 0:
            continue
        var vn = dot(vb - va, n)
        var bias = Real(0)
        var ms = Real(1)
        var isc = Real(0)
        if d < 0:
            bias = -d / h
        elif use_bias != 0:
            bias = max(-bias_rate * d, Real(-4))
            ms = mass_scale
            isc = impulse_scale
        var acc = _ld(c, o + _ACC + p)
        var raw = -ms * (vn + bias) / denom - isc * acc
        var new_acc = max(acc + raw, 0)
        var dl = new_acc - acc
        _st(c, o + _ACC + p, new_acc)
        if dl != 0:
            var j = n * dl
            if dyn_a:
                A.apply_impulse(-j, pwa)
            if dyn_b:
                B.apply_impulse(j, pwb)
        var tb = tangent_basis(n)
        var cap = pair_mu * new_acc
        for ti in range(2):
            var t = tb[0] if ti == 0 else tb[1]
            var vat = Vec3(0, 0, 0, 0)
            var kat = Real(0)
            if mov_a:
                vat = A.velocity_at(pwa)
            if dyn_a:
                kat = A.inv_mass() + A.angular_factor(pwa - A.position(), t)
            var vbt = Vec3(0, 0, 0, 0)
            var kbt = Real(0)
            if mov_b:
                vbt = B.velocity_at(pwb)
            if dyn_b:
                kbt = B.inv_mass() + B.angular_factor(pwb - B.position(), t)
            var dent = kat + kbt
            if dent <= 0:
                continue
            var vt = dot(vbt - vat, t)
            var slot = o + (_AT1 if ti == 0 else _AT2) + p
            var acc_t = _ld(c, slot)
            var new_t = acc_t - vt / dent
            if new_t > cap:
                new_t = cap
            elif new_t < -cap:
                new_t = -cap
            var dtl = new_t - acc_t
            _st(c, slot, new_t)
            if dtl != 0:
                var jt = t * dtl
                if dyn_a:
                    A.apply_impulse(-jt, pwa)
                if dyn_b:
                    B.apply_impulse(jt, pwb)
    if dyn_a:
        _save(b, ia, A)
    if dyn_b:
        _save(b, ib, B)


# --------------------------------------------------------------------- host


struct GpuContactSolver(Movable):
    """Device buffers for one scene, grown on demand and reused across
    frames. Holds no `DeviceContext` -- every call takes the owner's."""

    var bbuf: DeviceBuffer[dtype]
    var cbuf: DeviceBuffer[dtype]
    var bcap: Int
    var ccap: Int
    var upload_ns: Int
    var compute_ns: Int
    var download_ns: Int

    def __init__(out self, mut ctx: DeviceContext) raises:
        self.bcap = 64
        self.ccap = 256
        self.bbuf = ctx.enqueue_create_buffer[dtype](self.bcap * _BS)
        self.cbuf = ctx.enqueue_create_buffer[dtype](self.ccap * _CS)
        self.upload_ns = 0
        self.compute_ns = 0
        self.download_ns = 0

    def _reserve(mut self, mut ctx: DeviceContext, nb: Int, nc: Int) raises:
        if nb > self.bcap:
            while self.bcap < nb:
                self.bcap *= 2
            self.bbuf = ctx.enqueue_create_buffer[dtype](self.bcap * _BS)
        if nc > self.ccap:
            while self.ccap < nc:
                self.ccap *= 2
            self.cbuf = ctx.enqueue_create_buffer[dtype](self.ccap * _CS)

    def step(
        mut self,
        mut ctx: DeviceContext,
        mut sc: ContactScene6[QuatBody6],
        dt: Real,
        gravity: Vec3,
        cfg: SolverConfig,
    ) raises:
        """One frame of `sc` with the contact solve on the device;
        equivalent to `sc.step(dt, gravity, cfg)` with `cfg.colored=True`."""
        if len(sc.joints) > 0 or len(sc.drives) > 0 or len(sc.softs) > 0 or cfg.ccd or sc.bset.any_grav:
            raise Error("GpuContactSolver: joints, drives, soft bodies, CCD and gravity zones are not supported")
        var h = dt / Real(cfg.substeps)
        var omega = Real(6.283185307179586) * cfg.hertz
        var cc = h * omega * (2 * cfg.zeta + h * omega)
        var bias_rate = omega / (2 * cfg.zeta + h * omega)
        var mass_scale = cc / (1 + cc)
        var impulse_scale = 1 / (1 + cc)

        var clo = List[Int]()
        var chi = List[Int]()
        var pairs = sc.begin_external_solve(dt, cfg, clo, chi)
        var nb = len(sc.bset.bodies)
        var nc = len(pairs)
        for k in range(nc):
            if pairs[k].vsurf[0] != 0 or pairs[k].vsurf[1] != 0 or pairs[k].vsurf[2] != 0:
                raise Error("GpuContactSolver: conveyor contacts are not supported")
        if nc > 0 and len(clo) == 0:
            raise Error("GpuContactSolver: colouring overflowed (> 64 colours); use the CPU step")
        self._reserve(ctx, nb, max(nc, 1))

        var t0 = Int(perf_counter_ns())
        with self.bbuf.map_to_host() as m:
            var t = TileTensor(m, row_major(self.bcap * _BS))
            for i in range(nb):
                var o = i * _BS
                ref body = sc.bset.bodies[i]
                _put3(t, o + _POS, body.pos)
                _put3(t, o + _VEL, body.vel)
                _put3(t, o + _OMG, body.omega)
                _st(t, o + _Q, body.q.x)
                _st(t, o + _Q + 1, body.q.y)
                _st(t, o + _Q + 2, body.q.z)
                _st(t, o + _Q + 3, body.q.w)
                _st(t, o + _MASS, body.inertia.mass)
                _st(t, o + _INR, body.inertia.ix)
                _st(t, o + _INR + 1, body.inertia.iy)
                _st(t, o + _INR + 2, body.inertia.iz)
                var dyn = sc.bset.is_dynamic(i)
                _st(t, o + _DYN, _b(dyn))
                _st(t, o + _MOV, _b(sc.bset.moves(i)))
                _st(t, o + _INACT, _b(sc.bset.inactive(i)))
                _st(t, o + _GRAV, _b(dyn and not sc.bset.sleeping[i]))
                _st(t, o + _INERT, _b(sc.bset.impulse_inert(i)))
        with self.cbuf.map_to_host() as m:
            var t = TileTensor(m, row_major(self.ccap * _CS))
            for k in range(nc):
                var o = k * _CS
                ref pr = pairs[k]
                _st(t, o + _A, Float32(pr.a))
                _st(t, o + _B, Float32(pr.b))
                _st(t, o + _CNT, Float32(pr.m.count))
                _st(
                    t, o + _MU,
                    pr.mu_override if pr.mu_override >= 0 else combine(
                        sc.bset.eff_friction(pr.a, cfg.default_friction),
                        sc.bset.eff_friction(pr.b, cfg.default_friction),
                        sc.bset.friction_combine[pr.a],
                        sc.bset.friction_combine[pr.b],
                    ),
                )
                _put3(t, o + _N, pr.m.normal)
                for p in range(4):
                    _st(t, o + _DEP + p, pr.m.depths[p] if p < pr.m.count else Float32(0))
                    _put3(t, o + _RA + 3 * p, pr.ra[p])
                    _put3(t, o + _RB + 3 * p, pr.rb[p])
                    _st(t, o + _ACC + p, pr.acc[p])
                    _st(t, o + _AT1 + p, pr.acc_t1[p])
                    _st(t, o + _AT2 + p, pr.acc_t2[p])
        var t1 = Int(perf_counter_ns())
        self.upload_ns += t1 - t0

        var bt = TileTensor(self.bbuf, row_major(self.bcap * _BS))
        var ct = TileTensor(self.cbuf, row_major(self.ccap * _CS))
        comptime LB = type_of(bt).LayoutType
        comptime LCt = type_of(ct).LayoutType
        comptime kg = gravity_kernel[LB]
        comptime ki = integrate_kernel[LB]
        comptime kw = warm_kernel[LB, LCt]
        comptime ks = solve_kernel[LB, LCt]
        var bgrid = ceildiv(nb, _BLOCK)
        for _ in range(cfg.substeps):
            ctx.enqueue_function[kg](
                bt, Int32(nb), h, gravity[0], gravity[1], gravity[2],
                grid_dim=bgrid, block_dim=_BLOCK,
            )
            for col in range(len(clo)):
                var cnt = chi[col] - clo[col]
                ctx.enqueue_function[kw](
                    bt, ct, Int32(clo[col]), Int32(cnt),
                    grid_dim=ceildiv(cnt, _BLOCK), block_dim=_BLOCK,
                )
            for _ in range(cfg.iters):
                for col in range(len(clo)):
                    var cnt = chi[col] - clo[col]
                    ctx.enqueue_function[ks](
                        bt, ct, Int32(clo[col]), Int32(cnt),
                        h, bias_rate, mass_scale, impulse_scale, Int32(1),
                        grid_dim=ceildiv(cnt, _BLOCK), block_dim=_BLOCK,
                    )
            ctx.enqueue_function[ki](bt, Int32(nb), h, grid_dim=bgrid, block_dim=_BLOCK)
            for _ in range(2):
                for col in range(len(clo)):
                    var cnt = chi[col] - clo[col]
                    ctx.enqueue_function[ks](
                        bt, ct, Int32(clo[col]), Int32(cnt),
                        h, bias_rate, Float32(1), Float32(0), Int32(0),
                        grid_dim=ceildiv(cnt, _BLOCK), block_dim=_BLOCK,
                    )
        ctx.synchronize()
        var t2 = Int(perf_counter_ns())
        self.compute_ns += t2 - t1

        with self.bbuf.map_to_host() as m:
            var t = TileTensor(m, row_major(self.bcap * _BS))
            for i in range(nb):
                if not sc.bset.moves(i):
                    continue
                var o = i * _BS
                ref body = sc.bset.bodies[i]
                body.pos = _v3(t, o + _POS)
                body.vel = _v3(t, o + _VEL)
                body.omega = _v3(t, o + _OMG)
                body.q = Quat(_ld(t, o + _Q), _ld(t, o + _Q + 1), _ld(t, o + _Q + 2), _ld(t, o + _Q + 3))
        with self.cbuf.map_to_host() as m:
            var t = TileTensor(m, row_major(self.ccap * _CS))
            for k in range(nc):
                var o = k * _CS
                for p in range(4):
                    pairs[k].acc[p] = _ld(t, o + _ACC + p)
                    pairs[k].acc_t1[p] = _ld(t, o + _AT1 + p)
                    pairs[k].acc_t2[p] = _ld(t, o + _AT2 + p)
        self.download_ns += Int(perf_counter_ns()) - t2
        sc.end_external_solve(pairs^, dt, cfg)
