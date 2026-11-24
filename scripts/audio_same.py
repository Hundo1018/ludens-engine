#!/usr/bin/env python3
"""Audio mixer (#120) native against wasm64: the hashes of every output sample's bits from app/audio_scene.py's scripted
renders (events with seeded pitch and clip, positioned voices that move, the sidechain, a bar-quantized track change).
Equality, not tolerance.

    pixi run -e wasm audio-same"""
import subprocess
import sys
from pathlib import Path

from ludens_wasm_rt import parity

ROOT = Path(__file__).resolve().parent.parent
D = ROOT / "build/deps"
NAMES = ["all (events, 3D, ducking, music)", "3D voices at rest", "music + ducking, 100-frame blocks", "voices at end", "plays dropped", "momentary LUFS x 100"]


def build(*args: str) -> None:
    ma = D / "miniaudio-mojo"
    cmd = [sys.executable, "-m", "ludens_wasm_rt.build_wasm", "--lib", str(ma), "--lib", ".", "-I", str(ma), "-I", "app", *args]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=False)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)


def main() -> int:
    sys.path.insert(0, str(ROOT / "scripts"))
    subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    import native_libs
    native_libs.build_all()
    build("app/audio_parity.mojo", "--target", "native", "-o", "build/audio_parity")
    build("app/audio_parity.mojo", "--target", "wasm64", "-o", "build/audio_parity.wasm", "--export", "audio_parity_*")
    out = subprocess.run([str(ROOT / "build/audio_parity")], capture_output=True, text=True, check=True).stdout
    nat = [int(v) for v in out.split()[1:]]
    wasm = parity.wasm_u64s(ROOT / "build/audio_parity.wasm", "audio_parity_run", len(NAMES))
    return 0 if parity.compare(NAMES, nat, wasm, "audio parity") else 1


if __name__ == "__main__":
    sys.exit(main())
