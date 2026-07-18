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


@fieldwise_init
struct SkinVert(Copyable, ImplicitlyCopyable, Movable):
    """Struct-wrapped vertex position. Bare `List[SIMD[_, 3]]` is hazardous in
    this nightly: beyond the documented realloc corruption (gjk.mojo), several
    width-3 lists captured by separate closures in one program crash the
    runtime at teardown (libAsyncRT; root-caused via bench_ga bisection
    2026-07-13 — the apply+skin combination reproduced 12/12, wrapping 0/15).
    The batch skinning APIs therefore take wrapped verts."""

    var v: Vec3


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
    rest: List[SkinVert],
    idx_a: List[Int],
    idx_b: List[Int],
    w_a: List[Real],
    mut out: List[SkinVert],
):
    """Per-vertex DLB + one sandwich (w_b = 1 − w_a)."""
    for i in range(len(rest)):
        var m = blend2(bones[idx_a[i]], bones[idx_b[i]], w_a[i], 1 - w_a[i])
        out[i] = SkinVert(m.apply_point(rest[i].v))


def skin_lbs(
    mats: List[Mat4],
    rest: List[SkinVert],
    idx_a: List[Int],
    idx_b: List[Int],
    w_a: List[Real],
    mut out: List[SkinVert],
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
        out[i] = SkinVert(transform_point4(m, rest[i].v))
