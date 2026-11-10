#!/usr/bin/env bash
# Build the shell as one wasm64 module: app/main.mojo + ludens-core + wgpu-mojo + miniaudio-mojo.
#   pixi run -e wasm build-wasm [out.wasm]       (default build/app.wasm)
# Libraries come from the revs pinned in deps.lock (scripts/deps.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/deps.sh
ENGINE=build/deps/ludens-core
WGPU=build/deps/wgpu-mojo
MA=build/deps/miniaudio-mojo
OUT="${1:-build/app.wasm}"
mkdir -p build

python3 -m ludens_wasm_rt.build_wasm \
  --lib "$ENGINE" --lib "$WGPU" --lib "$MA" --lib . \
  -I "$ENGINE" -I "$WGPU" -I "$MA" -I "$MA/examples/web" -I . \
  app/main.mojo -o "$OUT" --export 'app_*'
