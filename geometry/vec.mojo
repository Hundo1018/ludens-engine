"""Dimension-generic vector math built on SIMD.

`WorldType` is the world's scalar dtype; `Vec2`/`Vec3` are SIMD vectors. We keep
the *actual* SIMD width equal to the dimension (2 or 3) and NEVER use SIMD
`reduce_*` for reductions — on width-3 it silently drops the third lane in this
nightly. Reductions are done with an explicit `comptime for` over the lanes.

Width-generic helpers infer the width with `[w: SIMDSize, //]` (SIMD's width
parameter is `SIMDSize`, not `Int`, so plain `Int` would not infer from a value).
"""

from std.math import sqrt

comptime WorldType = DType.float32
comptime Real = Scalar[WorldType]
comptime Vec2 = SIMD[WorldType, 2]
# FOUR lanes, not three. Mojo requires SIMD widths to be powers of two, so a
# 3-vector is stored padded and LANE 3 IS ALWAYS ZERO.
#
# That invariant is load-bearing, not decorative: `dot` reduces over every lane
# of whatever width it is given, so a non-zero pad lane would silently corrupt
# every dot product, length and normalisation in the engine. It is maintained by
# construction -- `Vec3(x, y, z, 0)` at every call site, and splats are only
# ever `Vec3(0)` -- and `test_vec` asserts it survives the arithmetic that
# matters. Addition, subtraction and scalar multiply preserve zero; the one
# operation that would not is dividing two vectors element-wise, which this
# engine never does (division is always by a scalar length).
#
# Padding is also why the old `List[Vec3]` corruption class is gone: it was
# caused by a width the toolchain never fully supported.
comptime Vec3 = SIMD[WorldType, 4]


comptime PadW[d: Int] = 4 if d == 3 else d
"""Lane count used to store a `d`-dimensional vector.

SIMD widths must be powers of two, so a 3-vector occupies 4 lanes. Every
dimension-generic container sizes its storage with `PadW[dim]` rather than with
`dim` directly; loops still run over `dim`, so the pad lane is never addressed.

It has to be a CONDITIONAL alias, not arithmetic and not a function. A `def`
called in type position is never folded, and an arithmetic expression stays
symbolic -- `SIMDLength(((Int(4) // Int(2)) * Int(2)))` will not unify with
`SIMDLength(4)`, so a padded container could not be passed to anything typed
with a literal width. The conditional form folds to a literal and unifies."""


def vlanes(d: Int) -> Int:
    """Runtime form of `PadW`, for code that needs the count as a value."""
    return 4 if d == 3 else d


def dot[w: SIMDSize, //](a: SIMD[WorldType, w], b: SIMD[WorldType, w]) -> Real:
    """Lane-wise multiply then sum. Manual reduction (width-3 `reduce_add` is broken)."""
    var prod = a * b
    var s = Real(0)
    comptime for i in range(Int(w)):
        s += prod[i]
    return s


def length_sq[w: SIMDSize, //](a: SIMD[WorldType, w]) -> Real:
    return dot(a, a)


def length[w: SIMDSize, //](a: SIMD[WorldType, w]) -> Real:
    return sqrt(length_sq(a))


def distance_sq[w: SIMDSize, //](a: SIMD[WorldType, w], b: SIMD[WorldType, w]) -> Real:
    return length_sq(a - b)


def normalize[w: SIMDSize, //](a: SIMD[WorldType, w]) -> SIMD[WorldType, w]:
    var n = length(a)
    if n == 0:
        return a
    return a / n


def lane_min[w: SIMDSize, //](
    a: SIMD[WorldType, w], b: SIMD[WorldType, w]
) -> SIMD[WorldType, w]:
    var r = a
    comptime for i in range(Int(w)):
        if b[i] < r[i]:
            r[i] = b[i]
    return r


def lane_max[w: SIMDSize, //](
    a: SIMD[WorldType, w], b: SIMD[WorldType, w]
) -> SIMD[WorldType, w]:
    var r = a
    comptime for i in range(Int(w)):
        if b[i] > r[i]:
            r[i] = b[i]
    return r


def splat[d: Int](v: Real) -> SIMD[WorldType, PadW[d]]:
    """A vector with every lane set to `v` (width passed explicitly)."""
    var r = SIMD[WorldType, PadW[d]](0)
    comptime for i in range(d):
        r[i] = v
    return r
