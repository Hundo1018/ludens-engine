# LudensEngine entrypoint (Mojo nightly).
#
# COMPILE-GATED: `mojo` is not installed in this build environment (the Modular
# package channel is unreachable), so this was migrated per the mojo-nightly
# rules but not compile-checked. Verify with:  mojo run main.mojo
#
# The portable engine core lives in src/core/. Rendering/input are the HOST's
# job (browser JS + WebGPU) -- see bindings/js and legacy/ for the retired
# desktop (pygfx) prototype.


def main():
    print("LudensEngine — Mojo ECS core")
    print("wasm build:  bash scripts/build-all.sh   (see STATUS.md)")
