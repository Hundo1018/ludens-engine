#!/usr/bin/env python3
"""Rendering tier 2 (#140) CPU side, native against wasm64: the hash of every stitched terrain chunk vertex, of the
clipped decal triangles and of the packed trail records, from app/tier2_parity.mojo. Equality, not tolerance.

    pixi run -e wasm tier2-same"""
import re
import subprocess
import sys
from pathlib import Path

from ludens_wasm_rt import parity

ROOT = Path(__file__).resolve().parent.parent


def build(*args: str) -> None:
    proc = subprocess.run([sys.executable, "-m", "ludens_wasm_rt.build_wasm", "-I", ".", *args],
                          cwd=ROOT, capture_output=True, text=True, check=False)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)


def main() -> int:
    sys.path.insert(0, str(ROOT / "scripts"))
    import native_libs
    native_libs.build_all()  # libwasmrt_math.a etc., which wasm.toml's [native] section names
    build("app/tier2_parity.mojo", "--target", "native", "-o", "build/tier2_parity")
    build("app/tier2_parity.mojo", "--target", "wasm64", "-o", "build/tier2_parity.wasm", "--export", "tier2_parity_*")
    out = subprocess.run([str(ROOT / "build/tier2_parity")], capture_output=True, text=True, check=True).stdout
    print(out.strip())
    nat = re.search(r"terrain (\d+) decals (\d+) trails (\d+)", out)
    wasm = parity.wasm_u64s(ROOT / "build/tier2_parity.wasm", "tier2_parity_run", 3)
    ok = parity.compare(["terrain vertex hash", "decal hash", "trail hash"], [int(v) for v in nat.groups()], wasm, "tier 2 parity")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
