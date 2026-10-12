"""Batched articulations on flat arrays (ROADMAP 17.17): the per-thread body
of the GPU articulation kernel, also run on the host.

Many instances of one articulated model (same links and parent table,
own q / qd / tau): one instance = one GPU thread. `aba_instance` is
Featherstone's articulated-body algorithm (RBDA 7.3) in the three sweeps of
`Chain.dynamics_aba`, reusing that file's spatial helpers, with two
differences:

- the motion subspace is general, S = (s_w, s_v): (axis, 0) for a revolute
  joint, (0, axis) for a prismatic one (`dynamics_aba` assumes revolute);
  a prismatic joint's origin `pivot + axis q` enters the transforms;
- no allocation: every per-link intermediate lives in a caller-provided
  workspace of `WS` floats per link, so the body runs unchanged on a GPU
  thread (`physics/gpu_artic.mojo`) and on the host (`ArticBatch`).

Flat layouts (world scalar `Real`: f32, or f64 under build-f64):
- model: `MODEL_STRIDE` floats per link: axis, pivot, com, principal
  inertia about the COM, mass, kind (0 revolute, 1 prismatic);
- parent: one int32 per link, -1 for a root, parents before children;
- state: per instance `3 n` floats: q[n], qd[n], tau[n];
- qdd: per instance `n` floats (output);
- workspace: per instance `n * WS` floats.
"""

from geometry.vec import Real, Vec3, cross, dot
from geometry.quat import Quat
from physics.chain import (
    Chain,
    SpInertia,
    _ABI,
    _Rows3,
    _matvec,
    _rot_rows,
    _rot_mat,
    _skew,
    _outer_scaled,
    _matmul,
    _madd,
    _msub,
    _transpose,
    JOINT_PRISMATIC,
)

comptime FPtr = Pointer[Real, MutAnyOrigin]  # world scalar (f32, or f64 under build-f64)
comptime IPtr = Pointer[Int32, MutAnyOrigin]

comptime MODEL_STRIDE = 16
comptime M_AXIS = 0
comptime M_PIVOT = 3
comptime M_COM = 6
comptime M_IDIAG = 9
comptime M_MASS = 12
comptime M_KIND = 13

comptime WS = 64
comptime W_W = 0
comptime W_V = 3
comptime W_CW = 6
comptime W_CV = 9
comptime W_PW = 12
comptime W_PV = 15
comptime W_IA = 18  # a (9) b (9) d (9)
comptime W_UW = 45
comptime W_UV = 48
comptime W_D = 51
comptime W_U = 52
comptime W_AW = 53
comptime W_AV = 56
comptime W_Q = 59  # joint rotation quaternion x, y, z, w


@always_inline
def _ld3(p: FPtr, o: Int) -> Vec3:
    return Vec3(p[unsafe_offset=o], p[unsafe_offset=o + 1], p[unsafe_offset=o + 2], 0)


@always_inline
def _st3(p: FPtr, o: Int, v: Vec3):
    p[unsafe_offset=o] = v[0]
    p[unsafe_offset=o + 1] = v[1]
    p[unsafe_offset=o + 2] = v[2]


def _ldm(p: FPtr, o: Int) -> _Rows3:
    var m = _Rows3(fill=Vec3(0, 0, 0, 0))
    for r in range(3):
        m[r] = _ld3(p, o + 3 * r)
    return m^


def _stm(p: FPtr, o: Int, m: _Rows3):
    for r in range(3):
        _st3(p, o + 3 * r, m[r])


def _ld_abi(p: FPtr, o: Int) -> _ABI:
    return _ABI(_ldm(p, o), _ldm(p, o + 9), _ldm(p, o + 18))


def _st_abi(p: FPtr, o: Int, ia: _ABI):
    _stm(p, o, ia.a)
    _stm(p, o + 9, ia.b)
    _stm(p, o + 18, ia.d)


@always_inline
def _ldq(p: FPtr, o: Int) -> Quat:
    return Quat(p[unsafe_offset=o], p[unsafe_offset=o + 1], p[unsafe_offset=o + 2], p[unsafe_offset=o + 3])


def aba_instance(model: FPtr, parent: IPtr, n: Int, state: FPtr, qdd: FPtr, ws: FPtr, gravity: Vec3):
    """qdd = forward dynamics of one instance (fixed base at rest, gravity via
    the base-acceleration trick)."""
    var zero = Vec3(0, 0, 0, 0)
    # --- pass 1 (outward): joint transforms, velocities, bias terms -------
    for i in range(n):
        var mo = i * MODEL_STRIDE
        var wo = i * WS
        var axis = _ld3(model, mo + M_AXIS)
        var pivot = _ld3(model, mo + M_PIVOT)
        var prism = Int(model[unsafe_offset=mo + M_KIND]) == JOINT_PRISMATIC
        var q = state[unsafe_offset=i]
        var qd = state[unsafe_offset=n + i]
        var rot = Quat.identity() if prism else Quat.from_axis_angle(axis, q)
        var off = pivot + axis * q if prism else pivot
        ws[unsafe_offset=wo + W_Q] = rot.x
        ws[unsafe_offset=wo + W_Q + 1] = rot.y
        ws[unsafe_offset=wo + W_Q + 2] = rot.z
        ws[unsafe_offset=wo + W_Q + 3] = rot.w
        var s_w = zero if prism else axis
        var s_v = axis if prism else zero
        var pi = Int(parent[unsafe_offset=i])
        var w_p = _ld3(ws, pi * WS + W_W) if pi >= 0 else zero
        var v_p = _ld3(ws, pi * WS + W_V) if pi >= 0 else zero
        var rt = _rot_rows(rot)
        var w_here = _matvec(rt, w_p) + s_w * qd
        var v_here = _matvec(rt, v_p + cross(w_p, off)) + s_v * qd
        # c = v ×ₘ S q̇ = (w × s_w q̇, w × s_v q̇ + v × s_w q̇)
        _st3(ws, wo + W_CW, cross(w_here, s_w * qd))
        _st3(ws, wo + W_CV, cross(w_here, s_v * qd) + cross(v_here, s_w * qd))
        var ii = SpInertia.of_link(model[unsafe_offset=mo + M_MASS], _ld3(model, mo + M_COM), _ld3(model, mo + M_IDIAG))
        var mom = ii.apply(w_here, v_here)
        _st3(ws, wo + W_PW, cross(w_here, mom[0]) + cross(v_here, mom[1]))
        _st3(ws, wo + W_PV, cross(w_here, mom[1]))
        _st3(ws, wo + W_W, w_here)
        _st3(ws, wo + W_V, v_here)
        _st_abi(ws, wo + W_IA, _ABI.of(ii))
    # --- pass 2 (inward): articulated inertias and bias forces ------------
    var i2 = n - 1
    while i2 >= 0:
        var mo = i2 * MODEL_STRIDE
        var wo = i2 * WS
        var axis = _ld3(model, mo + M_AXIS)
        var prism = Int(model[unsafe_offset=mo + M_KIND]) == JOINT_PRISMATIC
        var s_w = zero if prism else axis
        var s_v = axis if prism else zero
        var ia = _ld_abi(ws, wo + W_IA)
        var u_ = ia.apply(s_w, s_v)
        _st3(ws, wo + W_UW, u_[0])
        _st3(ws, wo + W_UV, u_[1])
        var d = dot(s_w, u_[0]) + dot(s_v, u_[1])
        var pw = _ld3(ws, wo + W_PW)
        var pv = _ld3(ws, wo + W_PV)
        var u = state[unsafe_offset=2 * n + i2] - dot(s_w, pw) - dot(s_v, pv)
        ws[unsafe_offset=wo + W_D] = d
        ws[unsafe_offset=wo + W_U] = u
        var par = Int(parent[unsafe_offset=i2])
        if par >= 0:
            var inv_d = 1 / d
            var a2 = _msub(ia.a, _outer_scaled(u_[0], u_[0], inv_d))
            var b2 = _msub(ia.b, _outer_scaled(u_[0], u_[1], inv_d))
            var d2 = _msub(ia.d, _outer_scaled(u_[1], u_[1], inv_d))
            var iac = _ABI(a2.copy(), b2.copy(), d2.copy()).apply(_ld3(ws, wo + W_CW), _ld3(ws, wo + W_CV))
            var paw = pw + iac[0] + u_[0] * (u * inv_d)
            var pav = pv + iac[1] + u_[1] * (u * inv_d)
            var rot = _ldq(ws, wo + W_Q)
            var p = _ld3(model, mo + M_PIVOT)
            if prism:
                p = p + axis * state[unsafe_offset=i2]
            var a1 = _rot_mat(rot, a2)
            var b1 = _rot_mat(rot, b2)
            var d1 = _rot_mat(rot, d2)
            var px = _skew(p)
            var ap = _msub(_msub(_madd(a1, _matmul(px, _transpose(b1))), _matmul(b1, px)), _matmul(_matmul(px, d1), px))
            var bp = _madd(b1, _matmul(px, d1))
            var po = par * WS
            var ipar = _ld_abi(ws, po + W_IA)
            _st_abi(ws, po + W_IA, _ABI(_madd(ipar.a, ap), _madd(ipar.b, bp), _madd(ipar.d, d1)))
            var fw_p = rot.rotate(paw)
            var fv_p = rot.rotate(pav)
            _st3(ws, po + W_PW, _ld3(ws, po + W_PW) + fw_p + cross(p, fv_p))
            _st3(ws, po + W_PV, _ld3(ws, po + W_PV) + fv_p)
        i2 -= 1
    # --- pass 3 (outward): accelerations ----------------------------------
    for i in range(n):
        var mo = i * MODEL_STRIDE
        var wo = i * WS
        var axis = _ld3(model, mo + M_AXIS)
        var prism = Int(model[unsafe_offset=mo + M_KIND]) == JOINT_PRISMATIC
        var s_w = zero if prism else axis
        var s_v = axis if prism else zero
        var off = _ld3(model, mo + M_PIVOT)
        if prism:
            off = off + axis * state[unsafe_offset=i]
        var pi = Int(parent[unsafe_offset=i])
        var wa_p = _ld3(ws, pi * WS + W_AW) if pi >= 0 else zero
        var va_p = _ld3(ws, pi * WS + W_AV) if pi >= 0 else -gravity
        var rt = _rot_rows(_ldq(ws, wo + W_Q))
        var w_a = _matvec(rt, wa_p) + _ld3(ws, wo + W_CW)
        var v_a = _matvec(rt, va_p + cross(wa_p, off)) + _ld3(ws, wo + W_CV)
        var a = (ws[unsafe_offset=wo + W_U] - dot(_ld3(ws, wo + W_UW), w_a) - dot(_ld3(ws, wo + W_UV), v_a)) / ws[unsafe_offset=wo + W_D]
        qdd[unsafe_offset=i] = a
        _st3(ws, wo + W_AW, w_a + s_w * a)
        _st3(ws, wo + W_AV, v_a + s_v * a)


def artic_step_instance(model: FPtr, parent: IPtr, n: Int, state: FPtr, qdd: FPtr, ws: FPtr, gravity: Vec3, dt: Real):
    """One semi-implicit Euler step of one instance (same update as `Chain.step_aba`)."""
    aba_instance(model, parent, n, state, qdd, ws, gravity)
    for i in range(n):
        state[unsafe_offset=n + i] = state[unsafe_offset=n + i] + qdd[unsafe_offset=i] * dt
        state[unsafe_offset=i] = state[unsafe_offset=i] + state[unsafe_offset=n + i] * dt


def _fp(mut l: List[Real]) -> FPtr:
    return l.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()


def _ip(mut l: List[Int32]) -> IPtr:
    return l.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()


struct ArticBatch(Movable):
    """`count` instances of one articulated model, in the flat layout the GPU
    kernel reads; `dynamics_host` / `step_host` run the kernel body per
    instance on the CPU (the reference the device path is compared with)."""

    var n: Int
    var count: Int
    var model: List[Real]
    var parent: List[Int32]
    var state: List[Real]
    var qdd: List[Real]
    var ws: List[Real]

    def __init__(out self, chain: Chain, count: Int) raises:
        if count < 1:
            raise Error("ArticBatch: count must be >= 1")
        var n = len(chain.links)
        if n < 1:
            raise Error("ArticBatch: chain has no links")
        self.n = n
        self.count = count
        self.model = List[Real](length=n * MODEL_STRIDE, fill=0)
        self.parent = List[Int32](capacity=n)
        for i in range(n):
            ref l = chain.links[i]
            var o = i * MODEL_STRIDE
            for k in range(3):
                self.model[o + M_AXIS + k] = l.axis[k]
                self.model[o + M_PIVOT + k] = l.pivot[k]
                self.model[o + M_COM + k] = l.com[k]
                self.model[o + M_IDIAG + k] = l.i_diag[k]
            self.model[o + M_MASS] = l.mass
            self.model[o + M_KIND] = Real(l.kind)
            if chain.parent[i] >= i:
                raise Error("ArticBatch: parents must come before children")
            self.parent.append(Int32(chain.parent[i]))
        self.state = List[Real](length=count * 3 * n, fill=0)
        for k in range(count):
            for i in range(n):
                self.state[k * 3 * n + i] = chain.q[i]
                self.state[k * 3 * n + n + i] = chain.qd[i]
        self.qdd = List[Real](length=count * n, fill=0)
        self.ws = List[Real](length=count * n * WS, fill=0)

    def q(self, k: Int, i: Int) -> Real:
        return self.state[k * 3 * self.n + i]

    def qd(self, k: Int, i: Int) -> Real:
        return self.state[k * 3 * self.n + self.n + i]

    def set_q(mut self, k: Int, i: Int, v: Real):
        self.state[k * 3 * self.n + i] = v

    def set_qd(mut self, k: Int, i: Int, v: Real):
        self.state[k * 3 * self.n + self.n + i] = v

    def set_tau(mut self, k: Int, i: Int, v: Real):
        self.state[k * 3 * self.n + 2 * self.n + i] = v

    def dynamics_host(mut self, gravity: Vec3):
        var m = _fp(self.model)
        var p = _ip(self.parent)
        var st = _fp(self.state)
        var qa = _fp(self.qdd)
        var w = _fp(self.ws)
        for k in range(self.count):
            aba_instance(m, p, self.n, st + k * 3 * self.n, qa + k * self.n, w + k * self.n * WS, gravity)

    def step_host(mut self, dt: Real, gravity: Vec3):
        var m = _fp(self.model)
        var p = _ip(self.parent)
        var st = _fp(self.state)
        var qa = _fp(self.qdd)
        var w = _fp(self.ws)
        for k in range(self.count):
            artic_step_instance(m, p, self.n, st + k * 3 * self.n, qa + k * self.n, w + k * self.n * WS, gravity, dt)
