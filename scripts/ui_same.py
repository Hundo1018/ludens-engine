#!/usr/bin/env python3
"""ui/ native against wasm64: layout hash and widget draw-list hash from app/ui_parity.mojo. Equality, not tolerance."""
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
    build("app/ui_parity.mojo", "--target", "native", "-o", "build/ui_parity")
    build("app/ui_parity.mojo", "--target", "wasm64", "-o", "build/ui_parity.wasm", "--export", "ui_parity_*")
    out = subprocess.run([str(ROOT / "build/ui_parity")], capture_output=True, text=True, check=True).stdout
    nat = re.search(r"layout (\d+) widgets (\d+)", out)
    wasm = parity.wasm_u64s(ROOT / "build/ui_parity.wasm", "ui_parity_run", 2)
    ok = parity.compare(["layout", "widgets"], [int(v) for v in nat.groups()], wasm, "ui parity")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
