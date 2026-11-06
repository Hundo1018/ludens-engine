#!/usr/bin/env python3
"""ui/ native against wasm64: layout hash and widget draw-list hash from app/ui_parity.mojo. Equality, not tolerance."""
import re
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent


def build(*args: str) -> None:
    proc = subprocess.run([sys.executable, "-m", "ludens_wasm_rt.build_wasm", "-I", ".", *args],
                          cwd=ROOT, capture_output=True, text=True)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)


def main() -> int:
    sys.path.insert(0, str(ROOT / "scripts"))
    import native_libs  # noqa: F401  (native_env keeps the system linker visible)
    build("app/ui_parity.mojo", "--target", "native", "-o", "build/ui_parity")
    build("app/ui_parity.mojo", "--target", "wasm64", "-o", "build/ui_parity.wasm", "--export", "ui_parity_*")
    out = subprocess.run([str(ROOT / "build/ui_parity")], capture_output=True, text=True, check=True).stdout
    nat = re.search(r"layout (\d+) widgets (\d+)", out)
    js = f"""import('{ludens_wasm_rt.HOST_MJS}').then(async m => {{
      const rt = await m.instantiate(require('fs').readFileSync('{ROOT / 'build/ui_parity.wasm'}'));
      const p = rt.alloc(16);
      if (rt.call('ui_parity_run', p) !== 0) throw new Error('ui_parity_run failed');
      const v = new BigUint64Array(rt.mem(), Number(p), 2);
      console.log(v[0] + ' ' + v[1]);
    }})"""
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stdout + r.stderr[-1500:])
    ok = True
    for name, a, b in zip(("layout", "widgets"), nat.groups(), r.stdout.split()):
        ok &= a == b
        print(f"{name:8} native {a}  wasm64 {b}  {'equal' if a == b else 'DIFFERENT'}")
    print("ui parity:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
