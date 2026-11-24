#!/usr/bin/env python3
"""Particle simulation native against wasm64 (#121): the hash of every particle's state and the hash of the records the
particle pass uploads (sorted and packed), plus the live count and the drop count, from app/particles_parity.mojo.
Equality, not tolerance.

    pixi run -e wasm particles-same"""
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
    build("app/particles_parity.mojo", "--target", "native", "-o", "build/particles_parity")
    build("app/particles_parity.mojo", "--target", "wasm64", "-o", "build/particles_parity.wasm", "--export", "particles_parity_*")
    out = subprocess.run([str(ROOT / "build/particles_parity")], capture_output=True, text=True, check=True).stdout
    print(out.strip())
    nat = re.search(r"state (\d+) records (\d+) live (\d+) drops (\d+)", out)
    wasm = parity.wasm_u64s(ROOT / "build/particles_parity.wasm", "particles_parity_run", 4)
    ok = parity.compare(["state hash", "record hash", "live", "drops"], [int(v) for v in nat.groups()], wasm, "particles parity")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
