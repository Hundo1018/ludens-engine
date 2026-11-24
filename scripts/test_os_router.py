#!/usr/bin/env python3
"""The shared os_poll reader (ludens-engine #117): build app/os_router_probe.mojo to wasm64 and drive it from node
(tests/test_os_router.mjs): a profile load, a save load and a clipboard read in flight together each get their own result.

    pixi run -e wasm test-os-router"""
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    (ROOT / "build").mkdir(exist_ok=True)
    cmd = [sys.executable, "-m", "ludens_wasm_rt.build_wasm", "--lib", ".", "-I", "app", "-I", ".", "app/os_router_probe.mojo",
           "--target", "wasm64", "-o", "build/os_router_probe.wasm", "--export", "p_*"]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=False)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)
    return subprocess.run(["node", str(ROOT / "tests/test_os_router.mjs"), str(ROOT / "build/os_router_probe.wasm"), str(ludens_wasm_rt.HOST_MJS)], check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
