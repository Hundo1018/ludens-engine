#!/usr/bin/env python3
"""Event sheet: the same sheet on the same world gives the same hash on native and on wasm64.

Run: pixi run -e wasm sheet-parity"""
import re
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent
D = ROOT / "build/deps"
sys.path.insert(0, str(ROOT / "scripts"))
from bench import serial_engine  # noqa: E402


def build(eng: Path, *extra: str) -> None:
    cmd = [sys.executable, "-m", "ludens_wasm_rt.build_wasm", "--lib", str(eng), "--lib", ".", "-I", str(eng), "-I", ".",
           "app/sheet_parity.mojo", *extra]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)


def main() -> int:
    subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True)
    import native_libs
    native_libs.build_all()
    (ROOT / "build").mkdir(exist_ok=True)
    build(serial_engine(), "--target", "native", "-o", "build/sheet_parity")
    build(D / "ludens-engine", "--target", "wasm64", "-o", "build/sheet_parity.wasm", "--export", "sheet_parity_*")
    out = subprocess.run([str(ROOT / "build/sheet_parity")], capture_output=True, text=True, check=True).stdout
    nat = re.search(r"hash (\d+) kicks (\d+) fell (\d+) cut (\d+)", out).groups()
    js = f"""import('{ludens_wasm_rt.HOST_MJS}').then(async m => {{
      const rt = await m.instantiate(require('fs').readFileSync('{ROOT / 'build/sheet_parity.wasm'}'));
      const p = rt.alloc(32);
      if (rt.call('sheet_parity_run', p) !== 0) throw new Error('sheet_parity_run failed');
      const v = new BigUint64Array(rt.mem(), Number(p), 4);
      console.log([...v].join(' '));
    }})"""
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stdout + r.stderr[-1500:])
    wasm = r.stdout.split()
    ok = True
    for name, a, b in zip(("world hash", "kicks", "fell", "cut"), nat, wasm):
        ok &= a == b
        print(f"{name:11} native {a}  wasm64 {b}  {'equal' if a == b else 'DIFFERENT'}")
    print("sheet parity:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
