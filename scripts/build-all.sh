#!/usr/bin/env bash
# Build every wasm artifact used by the tests and the browser demo.
# All go through the SAME retarget back-half (scripts/emit-and-link.sh):
# sources -> LLVM IR -> llc -> wasm-ld. Swap a .c stand-in for Mojo's emitted
# .ll and nothing here changes (see STATUS.md).
set -euo pipefail
cd "$(dirname "$0")/.."

E="bash scripts/emit-and-link.sh"
CORE="toolchain/standin/sparse_set.c toolchain/standin/wasm_rt.c"

echo "# 00 corpus: pure-int hand-written IR (source-language independent)"
$E --out build/wasm/00_pure_int.wasm --export add --export sum_to \
  tests/corpus/00_pure_int.ll

echo "# core: SparseSet only (no imports) -> differential + corpus"
# shellcheck disable=SC2086
$E --out build/wasm/sparse_set.wasm \
  --export ss_create --export ss_add --export ss_contains --export ss_remove \
  --export ss_len --export ss_dense_at --export ss_dense_ptr \
  $CORE

echo "# layer A: core + C physics in ONE module, shared memory (no imports)"
# shellcheck disable=SC2086
$E --out build/wasm/layer_a.wasm \
  --export ss_create --export ss_add --export ss_contains --export ss_remove \
  --export ss_len --export ss_dense_at --export ss_dense_ptr \
  --export physics_sum_keys --export physics_sum_dense \
  $CORE bindings/c/physics.c

echo "# engine: core + physics + engine loop; IMPORTS host.* (browser demo)"
# shellcheck disable=SC2086
$E --out build/wasm/engine.wasm \
  --export engine_init --export engine_update --export engine_entity_count \
  --export ss_len --export ss_dense_at --export ss_dense_ptr \
  $CORE bindings/c/physics.c toolchain/standin/engine_core.c

echo "OK: $(ls build/wasm/*.wasm | wc -l) artifacts in build/wasm/"
