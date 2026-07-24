#!/usr/bin/env bash
# One command that builds every wasm artifact and runs the whole runnable
# proof suite. Used by the `test` pixi task and by CI. Everything here runs on
# LLVM 18 + Node with no Mojo toolchain (the Mojo front-end step is gated --
# see STATUS.md); it proves the retarget back-half, both interop layers, and
# the differential methodology end to end.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==================== BUILD ===================="
bash scripts/build-all.sh

echo; echo "============ corpus/00 pure-int ==============="
node tests/corpus/00_pure_int.test.mjs build/wasm/00_pure_int.wasm

echo; echo "===== differential: SparseSet wasm vs oracle ====="
node tests/differential/sparse_set.test.mjs build/wasm/sparse_set.wasm 42 20000
node tests/differential/sparse_set.test.mjs build/wasm/sparse_set.wasm 1337 20000
node tests/differential/sparse_set.test.mjs build/wasm/sparse_set.wasm 305419896 20000

echo; echo "======= layer A: C zero-copy static link ======="
node tests/layer_a.test.mjs build/wasm/layer_a.wasm

echo; echo "===== layer B host inversion (headless demo) ====="
node bindings/js/run-node.mjs build/wasm/engine.wasm 5

echo; echo "============= golden IR snapshots ============="
# Non-fatal: IR drift is a review signal for front-end/LLVM lowering changes,
# not a hard gate (clang patch versions can differ trivially). Refresh with
# `make golden` after reviewing.
bash scripts/ir-snapshot.sh || echo "note: IR differs from golden (review; not fatal)"

echo; echo "########## ALL RUNNABLE PROOFS PASSED ##########"
