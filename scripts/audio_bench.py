#!/usr/bin/env python3
"""Mixing cost per 128-frame block for N voices (#120): median ns of Mixer.render, native and wasm64 under node.

    pixi run -e wasm audio-bench

One block is 2.667 ms of audio at 48 kHz, the time a worklet callback has. The table prints the cost as a share of that."""
import subprocess
import sys
from pathlib import Path

from ludens_wasm_rt import parity

ROOT = Path(__file__).resolve().parent.parent
D = ROOT / "build/deps"
VOICES = [0, 1, 4, 8, 16, 24]
BLOCKS = 2000
BUDGET_NS = 128 / 48000 * 1e9


def build(*args: str) -> None:
    ma = D / "miniaudio-mojo"
    cmd = [sys.executable, "-m", "ludens_wasm_rt.build_wasm", "--lib", str(ma), "--lib", ".", "-I", str(ma), "-I", "app", *args]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=False)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)


def native_ns(voices: int, spatial: bool) -> int:
    out = subprocess.run([str(ROOT / "build/audio_bench"), str(voices), str(int(spatial)), str(BLOCKS)], capture_output=True, text=True, check=True)
    return int(out.stdout.split()[-1])


def wasm_ns(voices: int, spatial: bool) -> int:
    return parity.wasm_u64s(ROOT / "build/audio_bench.wasm", "audio_bench_run", 1, [voices, int(spatial), BLOCKS])[0]


def main() -> int:
    sys.path.insert(0, str(ROOT / "scripts"))
    subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    import native_libs
    native_libs.build_all()
    build("app/audio_bench.mojo", "--target", "native", "-o", "build/audio_bench")
    build("app/audio_bench.mojo", "--target", "wasm64", "-o", "build/audio_bench.wasm", "--export", "audio_bench_*")
    print(f"median over {BLOCKS} blocks of 128 frames; budget per block {BUDGET_NS / 1e6:.3f} ms")
    print(f"{'voices':>6}  {'kind':<10} {'native ms':>10} {'native %':>9} {'wasm64 ms':>10} {'wasm64 %':>9}")
    for spatial in (False, True):
        for n in VOICES:
            if n == 0 and spatial:
                continue
            a, b = native_ns(n, spatial), wasm_ns(n, spatial)
            print(f"{n:>6}  {'positioned' if spatial else 'plain':<10} {a / 1e6:>10.4f} {100 * a / BUDGET_NS:>8.1f}% {b / 1e6:>10.4f} {100 * b / BUDGET_NS:>8.1f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
