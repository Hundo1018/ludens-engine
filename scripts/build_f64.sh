#!/usr/bin/env bash
# Precompile every package with an f64 world scalar into build64/ (ROADMAP 17.8).
#
# `WorldType` is a plain comptime alias in geometry/vec.mojo (a conditional
# alias loses the static float evidence `cos` / `sin` need, and `mojo
# precompile` takes no -D), so the f64 variant is built from a copy of the
# package sources with that one line switched. Packages come from the
# `pc <pkg>` lines of build_engine.sh, so the two stay in step.
#
#   pixi run build-f64
#   pixi run mojo run -I build64 tests/test_coord_precision.mojo   # an f64 run
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
OUT="$ROOT/build64"
mkdir -p "$OUT/.stage"
SRC=$(mktemp -d)
trap 'rm -rf -- "$SRC"' EXIT
PKGS=$(grep -E '^pc [a-z_]+$' scripts/build_engine.sh | awk '{print $2}')
for p in $PKGS; do
    cp -r "$p" "$SRC/$p"
done
# no `sed -i`: BSD sed (macOS) takes the next argument as a backup suffix
sed 's/^comptime WorldType = DType.float32$/comptime WorldType = DType.float64/' "$SRC/geometry/vec.mojo" > "$SRC/vec.tmp"
mv "$SRC/vec.tmp" "$SRC/geometry/vec.mojo"
grep -q '^comptime WorldType = DType.float64$' "$SRC/geometry/vec.mojo" || { echo "build_f64: WorldType line not found"; exit 1; }
cd "$SRC"
for p in $PKGS; do
    rm -f "$OUT/$p.mojoc"
    mojo precompile "$p" -I "$OUT" -o "$OUT/.stage/$p.mojoc"
    mv "$OUT/.stage/$p.mojoc" "$OUT/$p.mojoc"
done
echo "build-f64: all packages precompiled into build64/ (WorldType = float64)"
