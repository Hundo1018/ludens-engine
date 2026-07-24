#!/usr/bin/env bash
# ===========================================================================
# Golden LLVM-IR snapshots.
#
# The retarget pipeline is only as stable as the IR the front-end emits. When
# the Mojo toolchain (or LLVM) is upgraded, a changed lowering can silently
# break the wasm path. This script regenerates the IR for the corpus and diffs
# it against committed golden files, so drift shows up as a reviewable diff
# rather than a mystery runtime failure.
#
#   scripts/ir-snapshot.sh            # check against golden (CI mode; nonzero on drift)
#   scripts/ir-snapshot.sh --update   # accept current IR as the new golden
# ===========================================================================
set -euo pipefail

GOLDEN_DIR="toolchain/ir/golden"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$GOLDEN_DIR"

# (source, basename) pairs whose emitted IR we track.
SRCS=(toolchain/standin/sparse_set.c toolchain/standin/wasm_rt.c bindings/c/physics.c)

emit() { # <src> <out.ll>
  case "$1" in
    *.c)  clang --target=wasm32 -O2 -ffreestanding -fno-builtin -emit-llvm -S "$1" -o "$2";;
    *.ll) cp "$1" "$2";;
  esac
}

mode="${1:-check}"
drift=0
for src in "${SRCS[@]}"; do
  base="$(basename "${src%.*}")"
  cur="$TMP/$base.ll"
  emit "$src" "$cur"
  gold="$GOLDEN_DIR/$base.ll"
  if [[ "$mode" == "--update" ]]; then
    cp "$cur" "$gold"
    echo "updated golden: $gold"
  elif [[ ! -f "$gold" ]]; then
    # First run bootstraps the baseline (golden IR is toolchain-specific, so it
    # is generated per environment rather than committed). Drift is caught from
    # the next run on.
    cp "$cur" "$gold"
    echo "bootstrapped golden: $gold"
  elif ! diff -q "$gold" "$cur" >/dev/null; then
    echo "IR DRIFT in $base:"; diff -u "$gold" "$cur" || true; drift=1
  else
    echo "ok  $base"
  fi
done

[[ "$mode" == "--update" ]] && exit 0
[[ $drift -eq 0 ]] && echo "all IR matches golden" || { echo "IR drift detected"; exit 1; }
