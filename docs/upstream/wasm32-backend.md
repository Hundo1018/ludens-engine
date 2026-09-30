# Draft: `--target-triple wasm32-unknown-unknown`: the LLVM WebAssembly backend is not built

Kind: feature request (issue). Status: draft for review, not submitted.

## Problem

`mojo build --target-triple wasm32-unknown-unknown` fails:

```
error: could not construct host target info: No available targets are compatible with triple "wasm32-unknown-unknown"
```

Reproduced on Mojo 1.1.0 (8189361e) and on nightly 1.2.0.dev2026093005
(b3556108). `mojo build --print-supported-targets` on the nightly lists only
`aarch64 aarch64_32 aarch64_be arm64 arm64_32 riscv32 riscv32be riscv64
riscv64be x86 x86-64`.

Cause in the source (modular/modular `e700d92`),
`bazel/public-patches/llvm_project.bzl`:

```python
BACKENDS = [
    "AArch64",
    "RISCV",
    "X86",
]
```

The same file has an `extra_targets` tag for adding backends.

## Evidence that the rest of the pipeline already works

From this repository's experiments. Mojo 1.1.0 emits LLVM IR for
`riscv32-unknown-linux-gnu`, whose datalayout matches wasm32's. A script
rewrites the triple and datalayout and removes x86/LLVM-version-specific
attributes; the system's LLVM 18 (`llc`, `wasm-ld`) finishes the build
(`experiments/wasm_mojo/retarget_ir.py`, `build.py`). Results:
- A module built on `ecs.SparseSet` (stdlib `List`) passes a differential
  test against a JS oracle: 3 seeds × 20 000 operations.
- The same op sequence gives the same digest natively, as Mojo → wasm, and as C → wasm.
- A hot-reload matrix on a Mojo engine compiled this way matches every
  prediction: 40 cells plus the rollback test (W2).
- The runtime symbols a freestanding module needs are
  `KGEN_CompilerRT_AlignedAlloc`/`AlignedFree` plus error-path stubs
  (`experiments/wasm_mojo/mojo_rt.c`).

What the workaround cannot fix, and a real target would:
- Compile-time `size_of` / `reflect` offsets are those of the IR's target.
  With x86-64 IR, `{ptr, ptr, Int}` gets offset 16 at compile time but 8 at
  wasm run time, and `String`'s inline layout breaks. Borrowing riscv32
  avoids this only because its datalayout happens to match.
- The IR must be rewritten for an older LLVM. There is an in-tree
  alternative (`forcedBitcodeVersion` in `TargetTraits`, writers for
  bitcode 17/19/21), but no wasm target uses it.

## Proposed change (for discussion in the issue, before any PR)

1. Add `"WebAssembly"` to `BACKENDS`, or pass it through `extra_targets`.
2. A wasm32 `TargetTraits` (next to `Mojo/lib/Target/Host`): pointer width
   32, and the width of `Int` (to be decided in the issue: the wasm32 index
   type is i32).
3. A statement of which runtime the target expects: freestanding with
   user-provided `KGEN_CompilerRT_*`, or WASI.

Not done yet (roadmap P0, C1):
- building the compiler from source here;
- a patch on the owner's fork;
- the test that W1/W2 give the same results without `retarget_ir.py`.

The issue can be filed without these; a PR cannot.

## Open questions for the reviewer

- File as an issue now, or wait for the C1 prototype so the issue can link a working branch?
- Search the tracker for an existing wasm request first.
