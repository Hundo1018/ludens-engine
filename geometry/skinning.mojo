"""Motor skinning: dual-quaternion-style vertex blending on PGA motors.

`blend2` is DLB (dual linear blending) on the motor manifold: hemisphere-align
the bones (M and −M are the same motion), take the weighted sum of the 8
coefficients, renormalize by the rotor norm. Unlike matrix LBS, the blend stays
on (a first-order approximation of) the motor manifold, so a joint twisted
toward 180° keeps its volume instead of collapsing to the bone axis — the
"candy-wrapper" artifact, demonstrated in `tests/test_skinning.mojo` and
`examples/07_motor_skinning.mojo`.

`skin_motor` / `skin_lbs` are the two batch paths over SoA arrays: per vertex,
blend two bones and move the rest-pose position. The data layout (flat motor
coefficient columns) is exactly what a GPU kernel would consume; on this
machine they run as CPU code. Cost shape (bench_ga, N=4096, P-core): DLB ≈ 40
vs LBS ≈ 9.5 ns/vertex — the 4× buys artifact-free joints; the normalize +
sandwich dominate, so a GPU port or a specialized sandwich is the next win.
"""

from .vec import Real, Vec3
from .mat import Mat4, transform_point4
from .motor import Motor3


# `SkinVert` used to live here: a struct wrapping one `Vec3`, because a bare
# `List[SIMD[_, 3]]` corrupted on realloc AND several such lists captured by
# separate closures in one program crashed the runtime at teardown (libAsyncRT;
# root-caused by bisecting bench_ga on 2026-07-13 — the apply+skin combination
# reproduced 12/12, wrapping 0/15).
#
# Both symptoms had ONE cause: width 3 is not a power of two, and the toolchain
# never fully supported it. `Vec3` is four lanes now, so the wrapper is dead
# weight and the batch APIs take vertices directly. The removal is gated on the
# two things the wrapper was introduced for, not on the reasoning above: a bare
# non-pre-sized `List[Vec3]` round-trips across function boundaries with zero
# wrong elements, and `bench_ga` -- the exact program the original bisection
# used -- runs clean.


def blend2(a: Motor3, b: Motor3, wa: Real, wb: Real) -> Motor3:
    """DLB of two bones: hemisphere-align `b` to `a`, weighted-sum, normalize."""
    # rotor-part dot decides the hemisphere (double cover)
    var d = a.s * b.s + a.b12 * b.b12 + a.b13 * b.b13 + a.b23 * b.b23
    var sb = wb * (Real(-1) if d < 0 else Real(1))
    var m = Motor3(
        wa * a.s + sb * b.s,
        wa * a.b12 + sb * b.b12,
        wa * a.b13 + sb * b.b13,
        wa * a.b23 + sb * b.b23,
        wa * a.b10 + sb * b.b10,
        wa * a.b20 + sb * b.b20,
        wa * a.b30 + sb * b.b30,
        wa * a.pss + sb * b.pss,
    )
    return m.normalized()


def skin_motor(
    bones: List[Motor3],
    rest: List[Vec3],
    idx_a: List[Int],
    idx_b: List[Int],
    w_a: List[Real],
    mut out: List[Vec3],
):
    """Per-vertex DLB + one sandwich (w_b = 1 − w_a)."""
    for i in range(len(rest)):
        out[i] = _skin2(bones[idx_a[i]], bones[idx_b[i]], w_a[i], 1 - w_a[i], rest[i])


@no_inline
def _skin2(a: Motor3, b: Motor3, wa: Real, wb: Real, p: Vec3) -> Vec3:
    """One vertex of 2-bone DLB. Not inlined on purpose: `skin_motor` and
    `skin_motor_k` (K = 2) both call it, so they share one compiled body
    and round identically. Inlined into each caller, the same expression
    rounded differently in 41 of 500 vertices (up to 3e-7, `test_skin_k`)."""
    return blend2(a, b, wa, wb).apply_point(p)


def skin_lbs(
    mats: List[Mat4],
    rest: List[Vec3],
    idx_a: List[Int],
    idx_b: List[Int],
    w_a: List[Real],
    mut out: List[Vec3],
):
    """Classic linear blend skinning: per-vertex weighted matrix, then transform
    (the baseline the motor path is compared against)."""
    for i in range(len(rest)):
        var ma = mats[idx_a[i]]
        var mb = mats[idx_b[i]]
        var wa = w_a[i]
        var wb = 1 - wa
        var m = Mat4.identity()
        comptime for k in range(16):
            m.m[k] = wa * ma.m[k] + wb * mb.m[k]
        out[i] = transform_point4(m, rest[i])


# ---------------------------------------------------------------- K influences
# ROADMAP 17.65. Per vertex K (index, weight) pairs, SoA: `idx[v * K + j]`,
# `w[v * K + j]`. Indices and lengths are validated once, at the call
# boundary (`raise`); the vertex loop does not raise.


def _check_k(bones: Int, verts: Int, idx: List[Int], w: List[Real], k: Int, out_len: Int) raises:
    if k < 1:
        raise Error("skinning: K must be >= 1")
    if len(idx) != verts * k or len(w) != verts * k or out_len < verts:
        raise Error("skinning: idx / w must hold K entries per vertex and out one per vertex")
    for i in idx:
        if i < 0 or i >= bones:
            raise Error("skinning: bone index " + String(i) + " out of range")


@always_inline
def _hemi(a: Motor3, b: Motor3) -> Real:
    var d = a.s * b.s + a.b12 * b.b12 + a.b13 * b.b13 + a.b23 * b.b23
    return Real(-1) if d < 0 else Real(1)


def blend_k(bones: List[Motor3], idx: List[Int], w: List[Real], base: Int, k: Int) -> Motor3:
    """DLB of K bones (`idx[base:base+k]`, weights `w[base:base+k]`), each
    hemisphere-aligned to the first. Weights need not sum to 1 (the result is
    renormalised); all-zero weights give the identity (bind pose). K = 2 is
    `blend2`."""
    var a = bones[idx[base]]
    var wa = w[base]
    if k == 1:
        if wa == 0:
            return Motor3.identity()
        return a.normalized() if wa != 1 else a
    var b = bones[idx[base + 1]]
    if k == 2:
        if wa == 0 and w[base + 1] == 0:
            return Motor3.identity()
        return blend2(a, b, wa, w[base + 1])
    var sb = w[base + 1] * _hemi(a, b)
    var s = wa * a.s + sb * b.s
    var b12 = wa * a.b12 + sb * b.b12
    var b13 = wa * a.b13 + sb * b.b13
    var b23 = wa * a.b23 + sb * b.b23
    var b10 = wa * a.b10 + sb * b.b10
    var b20 = wa * a.b20 + sb * b.b20
    var b30 = wa * a.b30 + sb * b.b30
    var pss = wa * a.pss + sb * b.pss
    for j in range(2, k):
        var c = bones[idx[base + j]]
        var sc = w[base + j] * _hemi(a, c)
        s += sc * c.s
        b12 += sc * c.b12
        b13 += sc * c.b13
        b23 += sc * c.b23
        b10 += sc * c.b10
        b20 += sc * c.b20
        b30 += sc * c.b30
        pss += sc * c.pss
    var m = Motor3(s, b12, b13, b23, b10, b20, b30, pss)
    if m.norm_sq() == 0:
        return Motor3.identity()
    return m.normalized()


def skin_motor_k(bones: List[Motor3], rest: List[Vec3], idx: List[Int], w: List[Real], k: Int, mut out: List[Vec3]) raises:
    """Per-vertex K-bone DLB + one sandwich. With K = 2 and weights
    (w_a, 1 - w_a) it equals `skin_motor` bit for bit (`test_skin_k`)."""
    _check_k(len(bones), len(rest), idx, w, k, len(out))
    if k == 2:
        for v in range(len(rest)):
            if w[2 * v] == 0 and w[2 * v + 1] == 0:
                out[v] = rest[v]
            else:
                out[v] = _skin2(bones[idx[2 * v]], bones[idx[2 * v + 1]], w[2 * v], w[2 * v + 1], rest[v])
        return
    for v in range(len(rest)):
        out[v] = blend_k(bones, idx, w, v * k, k).apply_point(rest[v])


def skin_lbs_k(mats: List[Mat4], rest: List[Vec3], idx: List[Int], w: List[Real], k: Int, mut out: List[Vec3]) raises:
    """K-bone linear blend skinning; weights renormalised to sum 1 (all zero:
    the rest position)."""
    _check_k(len(mats), len(rest), idx, w, k, len(out))
    for v in range(len(rest)):
        var sw = Real(0)
        for j in range(k):
            sw += w[v * k + j]
        if sw == 0:
            out[v] = rest[v]
            continue
        var m = Mat4()  # zero-initialised
        for j in range(k):
            var wj = w[v * k + j] / sw
            var mj = mats[idx[v * k + j]]
            comptime for e in range(16):
                m.m[e] += wj * mj.m[e]
        out[v] = transform_point4(m, rest[v])


def bind_palette(world: List[Motor3], inverse_bind: List[Motor3]) raises -> List[Motor3]:
    """Skinning palette: world bone motor x inverse bind motor per bone, the
    buffer a host shader consumes. At the bind pose every entry is the
    identity motion."""
    if len(world) != len(inverse_bind):
        raise Error("bind_palette: one inverse bind motor per bone")
    var out = List[Motor3](capacity=len(world))
    for i in range(len(world)):
        out.append(world[i] * inverse_bind[i])
    return out^


def inverse_bind(bind_pose: List[Motor3]) -> List[Motor3]:
    """Inverse bind motors of a bind pose (the reverse of each unit motor)."""
    var out = List[Motor3](capacity=len(bind_pose))
    for m in bind_pose:
        out.append(m.reverse())
    return out^
