#!/usr/bin/env bash
# ===========================================================================
# Retarget back-half:  sources (.c | .ll)  ->  LLVM IR  ->  wasm object  ->  .wasm
#
# This is the EXACT path Mojo-emitted LLVM IR will follow. The Mojo front-end
# step is gated (see STATUS.md) because `mojo` cannot be installed in this
# environment; today we feed a faithful C / `.ll` stand-in through the same
# `llc` + `wasm-ld` stages. Swap a `.c` input for Mojo's `--emit-llvm` `.ll`
# output and nothing else changes.
#
# Usage:
#   scripts/emit-and-link.sh --out build/foo.wasm --export sym1 --export sym2 \
#       toolchain/standin/foo.c toolchain/standin/wasm_rt.c
#
# Intermediate .ll / .o land next to --out so every pipeline stage is
# inspectable (golden-IR snapshots, DWARF debugging, etc.).
# Extra clang flags for .c inputs (e.g. -DSPEED=120.0f) come from $CFLAGS,
# extra wasm-ld flags (e.g. --Map=build/x.map) from $LDFLAGS.
# ===========================================================================
set -euo pipefail

OUT=""
EXPORTS=()
SRCS=()
OPT="${OPT:-2}"
read -r -a EXTRA_CFLAGS <<<"${CFLAGS:-}"
read -r -a EXTRA_LDFLAGS <<<"${LDFLAGS:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)    OUT="$2"; shift 2;;
    --export) EXPORTS+=("$2"); shift 2;;
    --opt)    OPT="$2"; shift 2;;
    -*)       echo "unknown flag: $1" >&2; exit 2;;
    *)        SRCS+=("$1"); shift;;
  esac
done

[[ -n "$OUT" ]]            || { echo "error: --out required" >&2; exit 2; }
[[ ${#SRCS[@]} -gt 0 ]]    || { echo "error: no source inputs" >&2; exit 2; }

BUILD="$(dirname "$OUT")"
mkdir -p "$BUILD"

OBJS=()
for SRC in "${SRCS[@]}"; do
  base="$(basename "${SRC%.*}")"
  IR="$BUILD/$base.ll"
  OBJ="$BUILD/$base.o"
  case "$SRC" in
    *.c)
      # Front-end stand-in: C -> LLVM IR (the artifact Mojo will emit).
      clang --target=wasm32 -O"$OPT" -ffreestanding -fno-builtin \
            ${EXTRA_CFLAGS[@]+"${EXTRA_CFLAGS[@]}"} \
            -emit-llvm -S "$SRC" -o "$IR" ;;
    *.ll)
      cp "$SRC" "$IR" ;;
    *) echo "unsupported input: $SRC" >&2; exit 2;;
  esac
  # IR -> wasm object. -g keeps DWARF so wasm can be source-debugged.
  llc -march=wasm32 -O"$OPT" -filetype=obj "$IR" -o "$OBJ"
  OBJS+=("$OBJ")
done

# Objects -> one linked core module (layer-A: everything shares linear memory).
ldflags=(--no-entry --allow-undefined --export-memory --export-table)
for e in "${EXPORTS[@]}"; do ldflags+=(--export="$e"); done
ldflags+=(${EXTRA_LDFLAGS[@]+"${EXTRA_LDFLAGS[@]}"})
wasm-ld "${ldflags[@]}" "${OBJS[@]}" -o "$OUT"

echo "built $OUT ($(wc -c <"$OUT") bytes) <- ${SRCS[*]}"
