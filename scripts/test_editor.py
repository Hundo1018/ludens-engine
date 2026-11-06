#!/usr/bin/env python3
"""Build and run the editor command-layer test natively (no GPU).

    pixi run -e wasm test-editor

The pixi env's conda cc does not link on every system, so the build runs with that env's bin dir off PATH
(native_libs.native_env); mojo itself is called by absolute path so it still finds its standard library."""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import native_libs  # noqa: E402


def main() -> int:
    subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True)
    (ROOT / "build").mkdir(exist_ok=True)
    out = ROOT / "build/editor_command"
    mojo = Path(os.environ["CONDA_PREFIX"]) / "bin/mojo"
    cmd = [str(mojo), "build", "-D", "ASSERT=all", "-I", "build/deps/ludens-engine", "-I", ".",
           "tests/editor_command.mojo", "-o", str(out)]
    proc = subprocess.run(cmd, cwd=ROOT, env=native_libs.native_env(), capture_output=True, text=True)
    if proc.returncode:
        sys.stderr.write(proc.stdout + proc.stderr)
        return proc.returncode
    return subprocess.run([str(out)], cwd=ROOT).returncode


if __name__ == "__main__":
    sys.exit(main())
