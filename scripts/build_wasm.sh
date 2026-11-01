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

python3 -m ludens_wasm_rt.build_wasm \
  --lib "$ENGINE" --lib "$WGPU" --lib "$MA" --lib . \
  -I "$ENGINE" -I "$WGPU" -I "$MA" -I "$MA/examples/web" \
  app/main.mojo -o "$OUT" --export 'app_*'
