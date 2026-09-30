# wasm32 target: the WebAssembly backend is not built

## Problem

```
$ mojo build --target-triple wasm32-unknown-unknown probe.mojo
error: could not construct host target info: No available targets are compatible with triple "wasm32-unknown-unknown"
```

Same on 1.1.0 and on nightly 1.2.0.dev2026093005.
`--print-supported-targets` lists only AArch64, RISC-V and x86. The cause is
`bazel/public-patches/llvm_project.bzl`:

```python
BACKENDS = ["AArch64", "RISCV", "X86"]
```

## Why it matters

The rest of the pipeline already works. This repo builds Mojo code for wasm
by emitting LLVM IR for riscv32 (its datalayout matches wasm32), rewriting
the triple, and finishing with the system's LLVM
(`experiments/wasm_mojo/`). A module built on stdlib `List` passes a
differential test against native Mojo (3 seeds × 20 000 operations). Its
freestanding runtime needs only `KGEN_CompilerRT_AlignedAlloc`/`AlignedFree`
and a few error-path stubs.

The workaround has limits a real target would remove:
- `size_of` and reflected field offsets are computed for the IR's target.
  With x86-64 IR, `{ptr, ptr, Int}` gets offset 16 at compile time and 8 at
  run time. riscv32 works only because its layout happens to match.
- The IR comes from a newer LLVM and has to be edited for LLVM 18.

## Proposal

1. Add `"WebAssembly"` to `BACKENDS` (or pass it via `extra_targets`).
2. Add a wasm32 `TargetTraits`, and decide the width of `Int` there.
3. Document which runtime symbols a freestanding wasm module must provide.

No patch yet. Building the compiler from source and trying this on a fork
is the next step (roadmap P0, C1).
