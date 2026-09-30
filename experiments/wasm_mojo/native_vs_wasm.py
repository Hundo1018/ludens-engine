#!/usr/bin/env python3
"""W1 cross-check: the same seeded op sequence on
  native    dev's ecs.SparseSet, built by mojo for the host (native_oracle.mojo)
  mojo-wasm the Mojo core retargeted to wasm (build.py core)
  c-wasm    the C stand-in (build/wasm/sparse_set.wasm, `make build`)
must give the same per-step digest (len + dense keys after every step).

Prediction, written 2026-09-30 before the first run: all three digests are
equal for every seed.

    python3 experiments/wasm_mojo/native_vs_wasm.py [--steps 20000] [--seeds 42,1337,305419896]
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
OUT = ROOT / "build" / "wasm_mojo"
sys.path.insert(0, str(HERE))
from build import build, mojo  # noqa: E402


def run(cmd: list[str]) -> str:
    return subprocess.run(cmd, cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--steps", type=int, default=20000)
    ap.add_argument("--seeds", default="42,1337,305419896")
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run([mojo(), "build", "-I", str(ROOT / "build"), str(HERE / "native_oracle.mojo"), "-o",
                    str(OUT / "native_oracle")], cwd=ROOT, check=True)
    core = build("core", OUT / "core.wasm")
    cwasm = ROOT / "build" / "wasm" / "sparse_set.wasm"
    if not cwasm.exists():
        subprocess.run(["bash", "scripts/build-all.sh"], cwd=ROOT, check=True, capture_output=True)
    fails = 0
    for seed in a.seeds.split(","):
        native = run([str(OUT / "native_oracle"), seed, str(a.steps)])
        mw = run(["node", "tests/differential/digest.mjs", str(core), seed, str(a.steps)])
        cw = run(["node", "tests/differential/digest.mjs", str(cwasm), seed, str(a.steps)])
        same = native == mw == cw
        fails += not same
        print(f"{'PASS' if same else 'FAIL'}  seed {seed:>10}  native {native}  mojo-wasm {mw}  c-wasm {cw}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
