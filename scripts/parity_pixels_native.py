#!/usr/bin/env python3
"""B4 pixels, native side: build app/pixels.mojo and render the reference frame with wgpu-native, headless.
Writes build/pixels_native.rgba (960x540 RGBA8, tightly packed)."""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import native_libs  # noqa: E402
from parity_hashes import D, entry_build  # noqa: E402
from bench import serial_engine  # noqa: E402

FRAMES = 240


def main() -> int:
    subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True)
    native_libs.build_all()
    if not native_libs.wgpu_native_present():
        sys.exit("libwgpu_native.so / libwgpu_mojo_cb.so are missing from .pixi/envs/wasm/lib "
                 "(run build/deps/wgpu-mojo/scripts/setup-native.sh with CONDA_PREFIX pointing at that env)")
    ma, wg, eng = D / "miniaudio-mojo", D / "wgpu-mojo", serial_engine()
    entry_build("app/pixels.mojo", [eng, wg, ma, Path(".")], [eng, wg, ma, ma / "examples/web", ROOT / "app"],
                "--target", "native", "-o", "build/pixels")
    env = dict(os.environ, CONDA_PREFIX=str(ROOT / ".pixi/envs/wasm"))
    r = subprocess.run([str(ROOT / "build/pixels"), str(ROOT / "build/pixels_native.rgba"), str(FRAMES)],
                       capture_output=True, text=True, env=env)
    print((r.stdout + r.stderr).strip()[-600:])
    return r.returncode


if __name__ == "__main__":
    sys.exit(main())
