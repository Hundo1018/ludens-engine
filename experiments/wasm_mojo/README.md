# W1: Mojo source → wasm, without a Mojo wasm backend

```bash
python3 experiments/wasm_mojo/build.py core              # Mojo SparseSet core -> build/wasm_mojo/core.wasm
node tests/differential/sparse_set.test.mjs build/wasm_mojo/core.wasm 42 20000
python3 experiments/wasm_mojo/native_vs_wasm.py          # native Mojo vs Mojo-wasm vs C-wasm
python3 experiments/hot_reload/wasm/run.py test --core mojo   # hot reload matrix on the Mojo core
make wasm-mojo                                           # all of the above
```

## Problem

STATUS.md gated the Mojo → wasm path on "Mojo emitting LLVM IR for a whole
module". With Mojo 1.1.0 installed from PyPI:

- `mojo build --target-triple wasm32-unknown-unknown` fails: "No available
  targets are compatible with triple". The compiler has no wasm backend.
- `mojo build --emit llvm` works and writes unoptimised IR for the whole
  module, for the host.

## Method: emit IR for riscv32, retarget it to wasm32 (`retarget_ir.py`)

The system's LLVM 18 (`llc`, `wasm-ld`) has the wasm backend. `build.py`
emits the IR with `--target-triple riscv32-unknown-linux-gnu`, not for the
host. Mojo bakes `size_of`, `reflect` offsets and `String`'s inline layout
for the target it compiles for, and riscv32's datalayout (32-bit pointers,
i64 aligned to 8) is wasm32's. The first version emitted x86-64 IR; W2 showed
why that is not enough (Limits, below).

The tool then rewrites the IR so that LLVM 18 accepts it:

1. The `target triple` and `target datalayout` become wasm32's.
2. The x86 `target-cpu` / `target-features` attributes are removed. A group
   left empty gets a string attribute with no meaning to LLVM, because llc
   rejects empty groups.
3. `llvm.lifetime.start/end` calls are deleted. The newer LLVM form takes one
   argument and LLVM 18's takes two; these calls are optimisation hints only.
4. A fixed-width `llvm.stepvector` call becomes its constant `<0, 1, …>`.
   LLVM 18 does not have the intrinsic under that name, and wasm-ld would
   turn the call into an import.
5. Syntax newer than LLVM 18 is removed, driven by llc's parse errors.
   From x86-64 IR: `nuw` on constant expressions, `captures(none)` and
   `nocreateundeforpoison`; from riscv32 IR, none so far. Each only removes
   information (a poison flag or an attribute). The resulting IR is weaker,
   never different in behaviour. Each removal is written to
   `<out>.retarget.json`.

The result then goes through the unchanged back half:
`scripts/emit-and-link.sh` (llc → wasm-ld).

The runtime symbols the IR needs (`build.py` lists every `declare`) are
provided by `mojo_rt.c`:
- `KGEN_CompilerRT_AlignedAlloc` / `AlignedFree`: power-of-two size classes
  with free lists, grown with `memory.grow`. A bump pointer alone would leak
  every buffer a growing `List` gives up.
- `KGEN_CompilerRT_fprintf`, `write`, `dup`, `fdopen`, `fflush`, `fclose`,
  `KGEN_CompilerRT_GetStackTrace`: stubs, reached only on error paths
  (raising an `Error`, printing before `llvm.trap`).

The Mojo `SparseSet` core becomes a module with no imports (36 KB from
x86-64 IR).

## Results

**Pure integer code** (`probe_int.mojo` against `tests/corpus/00_pure_int.test.mjs`):
5/5 pass.

**SparseSet core** (`core.mojo` wraps dev's `ecs.SparseSet` behind the
C stand-in's `ss_*` ABI):
- the differential test passes on 3 seeds × 20 000 steps (len, `contains` for
  every key, zero-copy dense array), with x86-64 IR and again with riscv32 IR;
- keys are Mojo `Int`. The module exports `ss_key_bytes()`: 8 with x86-64 IR
  (read as `BigInt64`), 4 with riscv32 IR.

**Cross-check against native Mojo** (`native_vs_wasm.py`, prediction written
before the run: all three equal). The same seeded op sequence runs:
- natively on `ecs.SparseSet` (`native_oracle.mojo`);
- in the Mojo-derived wasm;
- in the C stand-in wasm.

A digest over len and dense keys after every step:

| Seed | native | Mojo → wasm | C → wasm |
|---|---|---|---|
| 42 | 0x8a1cfc9a, len 37 | same | same |
| 1337 | 0x80441c1a, len 34 | same | same |
| 305419896 | 0xcb9e114d, len 41 | same | same |

**Hot reload matrix on a Mojo core.** `engine_hot.mojo` is `engine_hot.c` in
Mojo, with the same ABI and snapshot format; run with
`run.py --core mojo`. See `experiments/hot_reload/wasm/README.md`: 25/25
cells and 5/5 guard rows match predictions written before the run.

## Compile-time layout: why riscv32 IR

Mojo computes `size_of` and `reflect` field offsets for the target it
compiles for, and LLVM lays structs out for wasm32 after the retarget.
`probe_layout.mojo`:

| Struct | x86-64 IR: baked / wasm run time | riscv32 IR: baked / wasm run time |
|---|---|---|
| `{Int, Float32, Int}`, offset of `c` | 16 / 16 | 8 / 8 |
| `{ptr, ptr, Int}`, offset of `c` | **16 / 8** | 8 / 8 |
| `size_of[{ptr, ptr, Int}]` | 24 (LLVM: 16) | 12 |

With x86-64 IR, field access through LLVM stayed self-consistent, which is
why the SparseSet core and the W1 matrix passed. Anything that used the baked
numbers was wrong. W2 hit it: `ecs.schema` snapshot field names came out cut
to 4 bytes ("capa", "fram", "box_"), because `String` keeps short text
inline in the struct and reads it through what became a 4-byte pointer field;
`probe_string.mojo` measures `String("capacity").byte_length()` as 8 with
riscv32 IR. Every other target Mojo 1.1.0 accepts was checked:

- `wasm32`, `armv7`, `arm`: rejected ("No available targets");
- `i686`: accepted, but aligns i64 / f64 to 4, where wasm32 aligns them to 8;
- `riscv32`: accepted, and its datalayout matches wasm32's.

Two intermediate states, kept as the record: host-CPU x86-64 IR fails in llc
("Do not know how to split the result of this operator", in `String`'s
UTF-8 validation with `simd_size=64`); `--target-cpu x86-64` compiled but
still had the 64-bit layout.

## Limits (measured)

- The IR claims to be riscv32 until the retarget. Mojo's stdlib could pick a
  riscv-specific code path (inline asm, a riscv intrinsic); none has shown
  up: the retargeted modules parse, link with no imports beyond `host.*`,
  and pass the tests above.
- Mojo has no global variables. Engine state that must survive across calls
  needs a slot provided outside Mojo (`engine_hot_rt.c`).
- Tested with Mojo 1.1.0 and LLVM 18.1.3. Removal step 4 depends on the
  distance between the two LLVM versions; a newer Mojo may need more rules.

## Files

| File | Role |
|---|---|
| `retarget_ir.py` | host IR → wasm32 IR for LLVM 18 |
| `build.py` | Mojo source → wasm (emit llvm, retarget, emit-and-link, list imports) |
| `mojo_rt.c` | Mojo runtime symbols for freestanding wasm32 |
| `core.mojo` | `ss_*` ABI on dev's `ecs.SparseSet` |
| `native_oracle.mojo`, `native_vs_wasm.py` | native vs wasm cross-check |
| `probe_int.mojo`, `probe_layout.mojo`, `probe_string.mojo` | probes |
