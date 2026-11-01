#!/usr/bin/env bash
# Build the shell as one wasm64 module: app/main.mojo + ludens-engine + wgpu-mojo + miniaudio-mojo.
#   pixi run -e wasm build-wasm [out.wasm]       (default build/app.wasm)
# Sibling checkouts by default; override with LUDENS_ENGINE / WGPU_MOJO / MINIAUDIO_MOJO.
set -euo pipefail
cd "$(dirname "$0")/.."
ENGINE="${LUDENS_ENGINE:-../ludens-engine}"
WGPU="${WGPU_MOJO:-../wgpu-mojo}"
MA="${MINIAUDIO_MOJO:-../miniaudio-mojo/miniaudio-mojo}"
OUT="${1:-build/app.wasm}"
mkdir -p build

# wgpu-mojo's manifest may still list its own runtime shim (ffi/wasm/wasm_rt.c), which duplicates
# ludens-wasm-rt's runtime and breaks the combined link. Link against a copy of the manifest without it.
# Remove this block once wgpu-mojo drops the line.
WGPU_LIB="$WGPU"
if grep -q 'wasm_rt\.c' "$WGPU/wasm.toml"; then
  WGPU_LIB="build/wgpu-lib"
  rm -rf "$WGPU_LIB"; mkdir -p "$WGPU_LIB"
  for f in "$WGPU"/* "$WGPU"/.[!.]*; do
    b=$(basename "$f"); [ "$b" = wasm.toml ] || [ "$b" = .git ] || ln -s "$(cd "$WGPU" && pwd)/$b" "$WGPU_LIB/$b"
  done
  grep -v '^c_sources' "$WGPU/wasm.toml" > "$WGPU_LIB/wasm.toml"
fi

python3 -m ludens_wasm_rt.build_wasm \
  --lib "$ENGINE" --lib "$WGPU_LIB" --lib "$MA" --lib . \
  -I "$ENGINE" -I "$WGPU" -I "$MA" -I "$MA/examples/web" \
  app/main.mojo -o "$OUT" --export 'app_*'
