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
# LUDENS_CONFIG=release (what `ludens build` passes by default): built with -D LUDENS_RELEASE, which leaves the in-game
# console out (game/console.mojo). The define reaches the driver as a library of its own whose manifest only sets it.
CONFIG_LIB=()
if [ "${LUDENS_CONFIG:-debug}" = "release" ]; then
  mkdir -p build/config-release
  printf '[lib]\nname = "ludens-config-release"\nmojo_defines = ["LUDENS_RELEASE"]\n' > build/config-release/wasm.toml
  CONFIG_LIB=(--lib build/config-release)
fi

python3 -m ludens_wasm_rt.build_wasm \
  --lib "$ENGINE" --lib "$WGPU" --lib "$MA" --lib . "${CONFIG_LIB[@]}" \
  -I "$ENGINE" -I "$WGPU" -I "$MA" -I "$MA/examples/web" -I . \
  app/main.mojo -o "$OUT" --export 'app_*'
