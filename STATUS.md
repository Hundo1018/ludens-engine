# Status: what runs today, what is gated

This branch scaffolds the **Mojo → WebAssembly** retarget path for LudensEngine
and proves every stage that does not require the Mojo compiler. One stage — the
Mojo front-end emitting LLVM IR — is **gated** in this environment and clearly
isolated so it can be dropped in unchanged later.

## The pipeline

```
 Mojo source ──emit LLVM IR──▶  *.ll  ──llc──▶  *.o  ──wasm-ld──▶  core .wasm
   (GATED here)                  ▲                                     │
                                 │                        ┌────────────┴───────────┐
   C stand-in ──clang -emit-llvm─┘                    layer A               layer B
   (runs today)                                    wasm-ld links        jco: component
                                                   C/C++/Rust into        + typed JS
                                                   one linear memory      (WIT bindings)
```

Only the top-left box is gated. Everything downstream is built and tested here
with LLVM 18 + Node, driven by a **faithful C stand-in** whose semantics and
wasm ABI match the Mojo core (`toolchain/standin/sparse_set.c` ↔
`src/core/sparse_set.mojo`).

## ✅ Proven today (`make test` / `pixi run test`)

| Stage | Proof | Runs in |
|---|---|---|
| Retarget back-half is source-independent | hand-written `tests/corpus/00_pure_int.ll` → `.wasm` | `corpus/00` |
| Retarget back-half with allocation | SparseSet stand-in → IR → `.wasm` | build + differential |
| Dual-target **differential** methodology | wasm vs JS oracle, 60k+ ops, zero-copy dense | `tests/differential` |
| **Layer A** (C/C++ zero-copy) | C `physics.c` linked into the core module, shared memory | `tests/layer_a` |
| **Layer B** host inversion | engine core imports `host.*`, exports `engine.*`, JS drives it | `bindings/js/run-node.mjs` |
| **Layer B** Component Model | WIT → `jco embed/new/transpile` → typed JS bindings | `scripts/componentize.sh` |
| Golden IR drift guard | `toolchain/ir/golden/*.ll` baseline (bootstrapped per toolchain) diffed on rebuild | `scripts/ir-snapshot.sh` |

## ⛔ Gated: the Mojo front-end (emit LLVM IR)

**Why gated here:** `conda.modular.com` and `pixi.sh` are blocked by this
environment's network policy (HTTP 403), so `mojo`/`magic`/`pixi` cannot be
installed. `mojo` is required to (a) compile-check the migrated nightly sources
and (b) emit the LLVM IR that replaces the C stand-in. Nothing about the
technique is blocked — only this sandbox's access to Modular's channel.

**To close the gate on a Mojo-equipped machine (nightly):**

1. Install the toolchain and verify the migrated core compiles:
   ```bash
   pixi install                 # or: magic install
   pixi run run                 # mojo run main.mojo
   pixi run test-native         # mojo test
   ```
2. Emit LLVM IR for the core and feed it to the SAME back-half. Probe the
   nightly flags first (they move around):
   ```bash
   mojo build --help | grep -iE 'emit|target|llvm|freestanding'
   ```
   Then, whichever of these the nightly exposes:
   - whole-module: `mojo build --emit=llvm src/core/sparse_set.mojo -o sparse_set.ll`
   - per-function: assemble from `compile_info[...]().asm` (LLVM IR) fragments.
3. Retarget the emitted IR (identical to what runs today):
   ```bash
   scripts/emit-and-link.sh --out build/wasm/sparse_set.wasm \
     --export ss_create --export ss_add --export ss_contains --export ss_remove \
     --export ss_len --export ss_dense_at --export ss_dense_ptr \
     sparse_set.ll                     # <- Mojo IR in place of the .c stand-in
   ```
4. Re-run `make test`. The differential suite now compares **native Mojo**
   (the true oracle, debuggable under `.vscode/launch.json` mojo-lldb) against
   the Mojo-derived wasm. The JS oracle stays as an independent cross-check.
5. For the typed component, generate the guest bindings with `wit-bindgen` from
   `wit/ludens.wit` instead of jco's `--dummy` guest, then run
   `scripts/componentize.sh`.

## Known nightly items to re-check on first compile

The migrated `.mojo` follows the mojo-nightly rules but was not compile-checked
(no `mojo` here). Most likely to need a touch-up:
- `InlineArray` vs `List` for the sparse array (kept as `List` to avoid API drift).
- `Movable` conformance / `__moveinit__` if the iterator copy path needs it.
- `VariadicList(keys)` access form for the variadic `*keys` parameter.

## Toolchain versions used here

LLVM/clang/llc/wasm-ld **18.1.3**, Node **22**, jco **1.25.2**. Target
`wasm32` (freestanding, in-module bump allocator; WASI sysroot not required for
the POC). The strategy targets `wasm32-wasi` for the fuller stdlib story — see
the plan and README.
