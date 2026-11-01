#!/usr/bin/env python3
"""Parity gate: build the shell entry for native and wasm64 from the one wasm.toml, run both, compare.

    pixi run -e wasm parity
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
TICKS = 10000


def build(*args: str) -> None:
    proc = subprocess.run([sys.executable, "-m", "ludens_wasm_rt.build_wasm", "--lib", ".", "app/shell.mojo", *args],
                          cwd=ROOT, capture_output=True, text=True)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)
    print(proc.stdout.strip())


def main() -> int:
    BUILD.mkdir(exist_ok=True)
    from ludens_wasm_rt import native_math
    native_math.build(BUILD / "libwasmrt_math.a")  # the native side of the shared sinf / cosf
    build("--target", "native", "-o", str(BUILD / "shell"))
    build("--target", "wasm64", "-o", str(BUILD / "shell.wasm"), "--export", "shell_*")
    native = subprocess.run([str(BUILD / "shell")], capture_output=True, text=True, check=True).stdout.strip()
    import ludens_wasm_rt
    js = (f"import('{ludens_wasm_rt.HOST_MJS}').then(async m => {{"
          f"const rt = await m.instantiate(require('fs').readFileSync('{BUILD / 'shell.wasm'}'));"
          f"console.log(rt.call('shell_step', {TICKS}).toString()); }})")
    wasm = subprocess.run(["node", "-e", js], capture_output=True, text=True, check=True).stdout.strip()
    ok = native == wasm
    print(f"native {native}\nwasm64 {wasm}\nparity: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
