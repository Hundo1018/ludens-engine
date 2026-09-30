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

## Method: retarget the host IR (`retarget_ir.py`)

The system's LLVM 18 (`llc`, `wasm-ld`) has the wasm backend. The tool
rewrites Mojo's host IR so that LLVM 18 accepts it:

1. The `target triple` and `target datalayout` become wasm32's.
2. The x86 `target-cpu` / `target-features` attributes are removed. A group
   left empty gets a string attribute with no meaning to LLVM, because llc
   rejects empty groups.
3. `llvm.lifetime.start/end` calls are deleted. The newer LLVM form takes one
   argument and LLVM 18's takes two; these calls are optimisation hints only.
4. Syntax newer than LLVM 18 is removed, driven by llc's parse errors.
   So far: `nuw` on constant expressions, `captures(none)` and
   `nocreateundeforpoison`. Each only removes information (a poison flag or
   an attribute). The resulting IR is weaker, never different in behaviour.
   Each removal is written to `<out>.retarget.json`.

The result then goes through the unchanged back half:
`scripts/emit-and-link.sh` (llc → wasm-ld).

The runtime symbols the IR needs (`build.py` lists every `declare`) are
provided by `mojo_rt.c`:
- `KGEN_CompilerRT_AlignedAlloc` / `AlignedFree`: power-of-two size classes
  with free lists, grown with `memory.grow`. A bump pointer alone would leak
  every buffer a growing `List` gives up.
- `KGEN_CompilerRT_fprintf`, `write`, `dup`, `fdopen`, `fflush`, `fclose`:
  stubs, only reached on the error path before `llvm.trap`.

The Mojo `SparseSet` core becomes a 36 KB module with no imports.

## Results

**Pure integer code** (`probe_int.mojo` against `tests/corpus/00_pure_int.test.mjs`):
5/5 pass.

**SparseSet core** (`core.mojo` wraps dev's `ecs.SparseSet` behind the
C stand-in's `ss_*` ABI):
- the differential test passes on 3 seeds × 20 000 steps (len, `contains` for
  every key, zero-copy dense array);
- keys are Mojo `Int`, which stays 64-bit, so the module exports
  `ss_key_bytes() = 8` and the test reads them as `BigInt64`.

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

## Limits (measured)

- **Compile-time layout vs wasm32 layout.** Mojo computes `size_of` and
  `reflect` field offsets for the host (64-bit pointers); after the retarget,
  LLVM lays structs out for wasm32. `probe_layout.mojo`:

  | Struct | baked offset of `c` | run-time offset in wasm |
  |---|---|---|
  | `{Int, Float32, Int}` | 16 | 16 |
  | `{ptr, ptr, Int}` | 16 | **8** |

  (`size_of[{ptr, ptr, Int}]` is baked as 24; LLVM makes it 16.)

  Field access goes through LLVM and stays self-consistent. Anything that
  uses the baked numbers is wrong for such a struct: `reflect` offsets, and
  therefore `ecs.schema`; byte-offset arithmetic; allocation sizes (too
  large, so harmless). The cores here have no such struct: `List` is
  `{ptr, i64, i64}`, laid out the same on both targets. A real fix is a Mojo
  wasm backend, or at least emitting IR for a 32-bit-pointer target.
- `Int` stays i64. Exports that JS calls take and return `Int32`; an `Int`
  parameter would need a `BigInt` from JS.
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
| `probe_int.mojo`, `probe_layout.mojo` | probes |
