#!/usr/bin/env python3
"""ludens-engine 17.91 / ludens-shell #14: hand a world between two separately built modules, native and wasm64.

Four numbers must be equal: native uninterrupted, native after the swap, wasm64 uninterrupted, wasm64 after a swap
from module A into module B (B has extra code). Run: pixi run -e wasm xfer-parity"""
import re
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent
D = ROOT / "build/deps"
BEFORE, AFTER = 60, 120
sys.path.insert(0, str(ROOT / "scripts"))
from bench import serial_engine  # noqa: E402


def build(entry: str, eng: Path, *extra: str) -> None:
    cmd = [sys.executable, "-m", "ludens_wasm_rt.build_wasm", "--lib", str(eng), "--lib", ".", "-I", str(eng), "-I", "app",
           entry, *extra]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)


def main() -> int:
    subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True)
    import native_libs
    native_libs.build_all()  # libwasmrt_math.a etc., which wasm.toml's [native] section names
    (ROOT / "build").mkdir(exist_ok=True)
    eng = serial_engine()
    build("app/xfer.mojo", eng, "--target", "native", "-o", "build/xfer")
    for m in ("a", "b"):
        build(f"app/xfer_{m}.mojo", D / "ludens-engine", "--target", "wasm64", "-o", f"build/xfer_{m}.wasm", "--export", "xfer_*")
    out = subprocess.run([str(ROOT / "build/xfer")], capture_output=True, text=True, check=True).stdout
    nat = re.search(r"blob (\d+) uninterrupted (\d+) after swap (\d+)", out)
    js = f"""import('{ludens_wasm_rt.HOST_MJS}').then(async m => {{
      const fs = require('fs');
      const a = await m.instantiate(fs.readFileSync('{ROOT / 'build/xfer_a.wasm'}'));
      const b = await m.instantiate(fs.readFileSync('{ROOT / 'build/xfer_b.wasm'}'));
      const outA = a.alloc(16), bufA = a.alloc(1 << 20);
      if (a.call('xfer_save', {BEFORE}, {AFTER}, bufA, BigInt(1 << 20), outA) !== 0) throw new Error('xfer_save failed');
      const va = new BigUint64Array(a.mem(), Number(outA), 2);
      const len = Number(va[1]);
      const blob = new Uint8Array(a.mem(), Number(bufA), len).slice();
      const bufB = b.alloc(len), outB = b.alloc(8);
      new Uint8Array(b.mem(), Number(bufB), len).set(blob);
      if (b.call('xfer_load', bufB, BigInt(len), {AFTER}, outB) !== 0) throw new Error('xfer_load failed');
      const vb = new BigUint64Array(b.mem(), Number(outB), 1);
      console.log(len + ' ' + va[0] + ' ' + vb[0]);
    }})"""
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stdout + r.stderr[-1500:])
    wlen, wref, wswap = r.stdout.split()
    nlen, nref, nswap = nat.groups()
    rows = [("native uninterrupted", nref), ("native after swap", nswap), ("wasm64 uninterrupted (module A)", wref),
            ("wasm64 after swap A -> B", wswap)]
    ok = len({v for _, v in rows}) == 1 and nlen == wlen
    for name, v in rows:
        print(f"{name:34} {v}")
    print(f"blob bytes: native {nlen}, wasm64 {wlen}")
    print("transfer parity (native == wasm64, across modules):", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
