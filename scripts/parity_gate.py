#!/usr/bin/env python3
"""B4 gate: native vs web in three comparisons, each printing PASS/FAIL; non-zero exit if any fails.

    pixi run -e wasm parity-gate

1. world hash   native == wasm64 (equality)           scripts/parity_hashes.py
2. PCM hash     native == wasm64 (equality)           scripts/parity_hashes.py
3. pixels       native wgpu vs browser, per-browser tolerance row   scripts/parity_pixels_native.py + test-web
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def step(name: str, cmd: list[str]) -> bool:
    print(f"\n=== {name}", flush=True)
    ok = subprocess.run(cmd, cwd=ROOT).returncode == 0
    print(f"=== {name}: {'PASS' if ok else 'FAIL'}", flush=True)
    return ok


def main() -> int:
    py = sys.executable
    results = {
        "world hash + PCM hash (native == wasm64)": step("hashes", [py, "scripts/parity_hashes.py"]),
        "native pixel reference": step("native pixels", [py, "scripts/parity_pixels_native.py"]),
    }
    results["web build"] = step("web build", ["pixi", "run", "-e", "wasm", "build-web"])
    results["pixels (browser vs native, tolerance)"] = step("browsers", ["bash", "scripts/test_web.sh"])
    print("\nparity gate")
    for k, v in results.items():
        print(f"  {'PASS' if v else 'FAIL'}  {k}")
    return 0 if all(results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
