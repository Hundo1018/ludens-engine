"""The engine's assertion convention (Phase 17.33) -- documentation plus one
family of hot-path helpers, NOT a reimplementation of `debug_assert`.

`docs/ARCHITECTURE.md` §2 assigns "programmer error / broken invariant" (index
out of range inside a solver, a padded lane non-zero, a handle used after its
owner died) to std `debug_assert`, detected by the layer that owns the
invariant, recovered by nobody ("it is a bug"), and NOT propagated: the process
terminates. That is exactly what std `debug_assert` already does on this
toolchain, verified end to end on Mojo 1.1.0 / modular 26.6.0
(probed 2026-09-27 while building this package):

  * default build (no `-D ASSERT=all`): `debug_assert(cond, msg)` compiles to
    nothing -- the condition is never even evaluated, so a hot loop pays zero
    cost for invariants it carries.
  * `-D ASSERT=all`: a failing `debug_assert` prints
    `At: file:line:col: Assert Error: <msg>` to stderr and the process crashes
    (non-zero exit) -- no exception, no unwinding, matching "terminate".

So: **use std `debug_assert` directly for invariants.** Don't wrap it in a
custom `assert_that(...)` -- that would just add a call frame and hide the
real file:line from the failure message. `scripts/run_tests.sh` passes
`-D ASSERT=all` to every test file, so the whole suite runs with invariants
live and any real bug fails loudly during `pixi run test`; a release build
omits the flag and pays nothing.

What this module DOES add: `invariant_finite`, a hot-path helper for the
"numerical failure" error class's PRECONDITION -- checking a value is neither
NaN nor +-Inf before a solver trusts it. It is a thin `debug_assert` wrapper
(same zero-cost-when-off / terminate-when-on behavior), generic over any SIMD
dtype and width so it takes a bare scalar (`Scalar[dtype]` is `SIMD[dtype,1]`)
or a padded vector (`Vec3 = SIMD[WorldType,4]`, see `geometry/vec.mojo`)
without diag importing geometry (layer 0 has zero engine deps -- the caller's
Vec3 unifies with `SIMD[dtype,4]` by construction, not by import). Widths in
this engine are always powers of two (`PadW`), so `.reduce_and()` over the
per-lane `isfinite` mask is safe here -- unlike a hand-rolled `comptime for`
over an INFERRED width, which `geometry/vec.mojo`'s `dot()` docstring records
as a real comptime-interpreter heap exhaustion hazard on a symbolic bound.

This is the DETECT half of "numerical failure" in the error-policy table; the
RECOVER half (quarantine the body, keep stepping) and the RECORD half (bump a
`diag.counters` id, emit a `diag.log` warning) are the solver's job when it
wires this in -- `invariant_finite` only decides whether the value was OK.

A toolchain gotcha hit while writing `tests/test_diag_invariant.mojo`, worth
knowing before the solver-wiring step reaches for it (the module was first
called `assert.mojo`; `assert` is reserved by `comptime assert`, so every
importer had to write `` from diag.`assert` import ... `` -- hence the name):

  * `Float32.MAX` (and presumably `Float64.MAX`) is `inf` on this toolchain,
    NOT the largest finite representable value like most languages' `MAX` --
    confirmed with a bare `print(Float32.MAX)`. Don't use it as a "largest
    finite value" test fixture; use an explicit large-but-finite literal
    (e.g. `Float32(3.0e38)`) instead.
"""

from std.math import isfinite


def invariant_finite[dtype: DType, w: SIMDLength, //](x: SIMD[dtype, w], msg: String):
    """Assert every lane of `x` is finite (not NaN, not +-Inf). No-op unless
    `-D ASSERT=all`; terminates with `msg` (plus the call site's file:line) if
    it fires. `x` may be a bare scalar or any SIMD width -- both are the same
    type family (`Scalar[dtype] = SIMD[dtype, 1]`)."""
    debug_assert(Bool(isfinite(x).reduce_and()), msg)
