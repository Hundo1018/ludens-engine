#!/usr/bin/env python3
"""os_* imports (ludens-engine #8): build app/os_probe.mojo to wasm64 and drive it from node (tests/test_os.mjs).

    pixi run -e wasm test-os"""
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    (ROOT / "build").mkdir(exist_ok=True)
    cmd = [sys.executable, "-m", "ludens_wasm_rt.build_wasm", "--lib", ".", "-I", "app", "app/os_probe.mojo",
           "--target", "wasm64", "-o", "build/os_probe.wasm", "--export", "p_*"]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)
    return subprocess.run(["node", str(ROOT / "tests/test_os.mjs"), str(ROOT / "build/os_probe.wasm"), str(ludens_wasm_rt.HOST_MJS)]).returncode


if __name__ == "__main__":
    sys.exit(main())
