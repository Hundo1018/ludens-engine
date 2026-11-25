#!/usr/bin/env python3
"""The device seams over the real os_dev_* imports (ludens-engine #135): build app/device_probe.mojo to wasm64 and drive
the web backends from node (tests/test_device.mjs) against fake browser objects. Boots through scripts/node_app.mjs, the one
place the node harnesses instantiate a module, so every os_* import is present.

    pixi run -e wasm test-device"""
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent
DEPS = ROOT / "build/deps"


def build() -> int:
    """Compile app/device_probe.mojo to build/device_probe.wasm (also used by scripts/device_web_check.py)."""
    (ROOT / "build").mkdir(exist_ok=True)
    cmd = [sys.executable, "-m", "ludens_wasm_rt.build_wasm", "--lib", ".", "-I", "app", "-I", ".", "app/device_probe.mojo",
           "--target", "wasm64", "-o", "build/device_probe.wasm", "--export", "p_*"]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=False)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)
    return 0


def main() -> int:
    build()
    run = ["node", "--no-warnings", str(ROOT / "tests/test_device.mjs"), str(ROOT / "build/device_probe.wasm"),
           str(ludens_wasm_rt.HOST_MJS), str(DEPS / "wgpu-mojo"), str(DEPS / "miniaudio-mojo")]
    return subprocess.run(run, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
