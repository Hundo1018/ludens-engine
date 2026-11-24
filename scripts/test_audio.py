#!/usr/bin/env python3
"""Build and run a native Mojo test that links miniaudio (the audio mixer, #120).

    pixi run -e wasm test-audio                # tests/audio_mixer.mojo
    pixi run -e wasm python3 scripts/test_audio.py audio_probe   # any tests/<name>.mojo

`scripts/test_native.py` builds with ludens-core on the include path but without miniaudio-mojo or its C shim; a test that
imports `miniaudio` is built the way scripts/parity_hashes.py builds the shell's audio probe: through
ludens_wasm_rt.build_wasm with miniaudio-mojo as a library, which links its C shim."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))


def build_native(entry: str, out: str) -> Path:
    import native_libs
    subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    native_libs.build_all()
    ma = ROOT / "build/deps/miniaudio-mojo"
    cmd = [sys.executable, "-m", "ludens_wasm_rt.build_wasm", "--lib", str(ma), "--lib", ".", "-I", str(ma), "-I", str(ROOT / "app"),
           entry, "--target", "native", "-o", out]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=False)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)
    return ROOT / out


def main(argv: list[str]) -> int:
    names = argv or ["audio_mixer"]
    rc = 0
    for name in names:
        exe = build_native(f"tests/{name}.mojo", f"build/{name}")
        rc |= subprocess.run([str(exe)], cwd=ROOT, check=False).returncode
    return 1 if rc else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
