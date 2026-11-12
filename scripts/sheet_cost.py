#!/usr/bin/env python3
"""Event sheet cost per tick against the same logic as Mojo code (ludens-engine #24). Native, optimised build.

Run: pixi run -e wasm sheet-cost     (prints a markdown table; exits non-zero if a result differs)"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import build_core  # noqa: E402


def main() -> int:
    exe = build_core.build_native("app/sheet_cost.mojo", ROOT / "build/sheet_cost", asserts=False)
    out = subprocess.run([str(exe)], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    print(out, end="")
    return 1 if "| NO |" in out else 0


if __name__ == "__main__":
    sys.exit(main())
