#!/usr/bin/env python3
"""The input action map end to end (ludens-engine #117, docs/input.md): build/app.wasm under node with `window.game`, analog axes,
gamepad and on-screen pad events, rebinding with conflicts, the profile written through os_file_write and restored by a second
module instance on the same storage (tests/test_input.mjs).

    pixi run -e wasm test-input          # builds build/app.wasm first"""
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent
DEPS = ROOT / "build/deps"


def main() -> int:
    wasm = ROOT / "build/app.wasm"
    if not wasm.exists():
        sys.exit(f"test_input: {wasm} is missing; run `pixi run -e wasm build-wasm`")
    cmd = ["node", "--experimental-strip-types", "--no-warnings", str(ROOT / "tests/test_input.mjs"), str(wasm),
           str(ludens_wasm_rt.HOST_MJS), str(DEPS / "wgpu-mojo"), str(DEPS / "miniaudio-mojo")]
    return subprocess.run(cmd, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
