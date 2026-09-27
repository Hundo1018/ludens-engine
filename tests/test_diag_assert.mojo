# tier: unit
"""`invariant_finite` contract (Phase 17.33). Note what this file does NOT do:
it never calls `invariant_finite` with a value that should trip it. A firing
`debug_assert` terminates the process (`docs/ARCHITECTURE.md` §2: "recovered
by nobody -- it is a bug"), so there is no way to catch it and keep recording
`Suite` checks afterward -- the same reason nothing in the other 116 test
files in this suite exercises an actual `debug_assert` failure either
(verified end-to-end instead, by hand, in `/tmp/claude-1000/probe_diag2/
p13_invariant_bad.mojo`: NaN/Inf DOES terminate the process under
`-D ASSERT=all`). What IS safely testable here: `invariant_finite` never
fires on genuinely finite input (ordinary + extreme magnitudes), and the
`isfinite` primitive it is built on -- the whole detection logic -- correctly
flags every value `invariant_finite` is meant to catch."""

from std.math import isfinite
from harness.runner import Suite
from diag.`assert` import invariant_finite


def main() raises:
    var s = Suite("diag_assert")

    # --- ordinary: finite scalars and vectors of different dtypes/widths ---
    invariant_finite(Float32(1.5), "f32 scalar finite")
    invariant_finite(Float64(-42.0), "f64 scalar finite")
    invariant_finite(SIMD[DType.float32, 4](1, 2, 3, 4), "f32 vec4 finite")
    invariant_finite(SIMD[DType.float64, 4](0, 0, 0, 0), "f64 vec4 zero finite")
    s.check(True, "ordinary: invariant_finite did not fire on finite input")

    # --- extreme magnitudes that are still finite (must not fire either) ---
    # NOTE: `Float32.MAX` is actually `inf` on this toolchain (verified with
    # `print(Float32.MAX)` -> `inf`), not the largest finite representable
    # value as in most languages -- so the "largest finite" case below is
    # spelled as a large literal, not `Float32.MAX`.
    invariant_finite(Float32(0.0), "zero is finite")
    invariant_finite(Float32(-0.0), "negative zero is finite")
    invariant_finite(Float32(3.0e38), "large-magnitude finite f32 is finite")
    invariant_finite(Float32(-3.0e38), "large-magnitude negative finite f32 is finite")
    s.check(True, "extreme: invariant_finite did not fire on boundary-magnitude finite input")

    # --- extreme: the underlying isfinite() primitive correctly flags every
    #     value invariant_finite is meant to reject (proxy for "would fire",
    #     without actually crashing the test process) ---
    var nan = Float32(0.0) / Float32(0.0)
    var pos_inf = Float32(1.0) / Float32(0.0)
    var neg_inf = Float32(-1.0) / Float32(0.0)
    s.check(not isfinite(nan), "detection: NaN is flagged non-finite")
    s.check(not isfinite(pos_inf), "detection: +Inf is flagged non-finite")
    s.check(not isfinite(neg_inf), "detection: -Inf is flagged non-finite")

    # a SIMD vector with exactly one non-finite lane must reduce to "not all
    # finite" -- this is the exact `.reduce_and()` step `invariant_finite`
    # performs internally.
    var mixed = SIMD[DType.float32, 4](1.0, nan, 3.0, 4.0)
    s.check(
        not Bool(isfinite(mixed).reduce_and()),
        "detection: one non-finite lane fails the whole-vector check",
    )
    var all_ok = SIMD[DType.float32, 4](1.0, 2.0, 3.0, 4.0)
    s.check(
        Bool(isfinite(all_ok).reduce_and()),
        "detection: an all-finite vector passes the whole-vector check",
    )

    s.finish()
