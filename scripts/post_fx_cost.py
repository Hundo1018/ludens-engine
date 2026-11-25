#!/usr/bin/env python3
"""Frame cost of FXAA, bloom, the colour grade and MSAA 4x at 1920 x 1080 on lavapipe (#139).

    pixi run -e wasm post-fx-cost

Builds tests/post_fx_native.mojo and runs it with --cost. Each pipeline draws the same scene; one round draws every
pipeline once, in turn, so a slow moment of the machine hits all of them; the table has the median of 11 rounds after 2
warm-up rounds. lavapipe is a CPU rasteriser: the numbers rank the work the effects add, they are not GPU times."""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import build_core  # noqa: E402


def main() -> int:
    out = build_core.build_native("tests/post_fx_native.mojo", ROOT / "build/post_fx_native", asserts=False)
    env = dict(os.environ)
    env.setdefault("WGPU_BACKEND", "vulkan")
    return subprocess.run([str(out), "--cost"], cwd=ROOT, env=env, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
