#!/usr/bin/env python3
"""Build the shell as wasm64 and print only the compiler errors, not the last 4000 characters of everything.

ludens_wasm_rt.build_wasm shows the tail of the compiler output, which with many warnings hides the errors.
Run: pixi run -e wasm python3 scripts/wasm_errors.py [entry.mojo]   (default app/main.mojo)"""
import re
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt.build_wasm as bw

ROOT = Path(__file__).resolve().parent.parent
D = ROOT / "build/deps"


def run_full(cmd, what, cwd, env=None):
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        text = proc.stdout + proc.stderr
        blocks = re.split(r"\n(?=/[^\n]*: (?:error|warning):)", text)
        errs = [b for b in blocks if re.match(r"/[^\n]*: error:", b)]
        print(f"wasm_errors: {what} failed, {len(errs)} error(s)")
        for b in errs:
            print(b.strip()[:1200], "\n")
        if not errs:
            print(text[-4000:])
        sys.exit(1)


def main(argv: list[str]) -> int:
    subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    bw.run = run_full
    entry = argv[0] if argv else "app/main.mojo"
    eng, wgpu, ma = D / "ludens-engine", D / "wgpu-mojo", D / "miniaudio-mojo"
    return bw.main(["--lib", str(eng), "--lib", str(wgpu), "--lib", str(ma), "--lib", ".",
                    "-I", str(eng), "-I", str(wgpu), "-I", str(ma), "-I", str(ma / "examples/web"), "-I", ".",
                    entry, "-o", str(ROOT / "build/app_check.wasm"), "--export", "app_*"]) or 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
