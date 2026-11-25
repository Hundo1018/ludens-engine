#!/usr/bin/env python3
"""The accessibility settings end to end (ludens-engine #118, docs/accessibility.md): build/app.wasm under node, the settings and their ranges,
the one profile file shared with the input bindings and restored by a second module instance, captions, camera shake, and the
player's volume per bus and mono output in the mixed audio (tests/test_access.mjs).

    pixi run -e wasm test-access-app          # builds build/app.wasm first"""
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent
DEPS = ROOT / "build/deps"


def main() -> int:
    wasm = ROOT / "build/app.wasm"
    if not wasm.exists():
        sys.exit(f"test_access: {wasm} is missing; run `pixi run -e wasm build-wasm`")
    sys.path.insert(0, str(ROOT / "scripts"))
    import check_audio_asset  # the shipped music, converted into build/ with its index (as test-audio-app does)
    site = ROOT / "build/audio_app_site"
    check_audio_asset.copy_to_build(site)
    cmd = ["node", "--experimental-strip-types", "--no-warnings", str(ROOT / "tests/test_access.mjs"), str(wasm),
           str(ludens_wasm_rt.HOST_MJS), str(DEPS / "wgpu-mojo"), str(DEPS / "miniaudio-mojo"), str(site / "audio")]
    return subprocess.run(cmd, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
