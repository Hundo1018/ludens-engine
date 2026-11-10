#!/usr/bin/env python3
"""Phase A of the arena sample game: engine gameplay / ai / nav compile and agree on native and wasm64.

Builds app/spike_probe.mojo natively (serial engine) and as wasm64, runs both and compares every number.

Run: pixi run -e wasm python3 scripts/spike_probe.py [--native-only]"""
import re
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent
D = ROOT / "build/deps"
sys.path.insert(0, str(ROOT / "scripts"))
from bench import serial_engine  # noqa: E402

NAMES = ("hash", "lost", "bt", "runs0", "polys", "path", "rng", "fired", "cam")


def build(eng: Path, *extra: str) -> None:
    cmd = [sys.executable, "-m", "ludens_wasm_rt.build_wasm", "--lib", str(eng), "--lib", ".", "-I", str(eng), "-I", ".",
           "app/spike_probe.mojo", *extra]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)


def main(argv: list[str]) -> int:
    subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True)
    import native_libs
    native_libs.build_all()
    (ROOT / "build").mkdir(exist_ok=True)
    build(serial_engine(), "--target", "native", "-o", "build/spike_probe")
    out = subprocess.run([str(ROOT / "build/spike_probe")], capture_output=True, text=True, check=True).stdout
    print("native :", out.strip())
    pat = " ".join(f"{n} (\\d+)" for n in NAMES)
    nat = re.search(pat, out).groups()
    if "--native-only" in argv:
        return 0
    build(D / "ludens-core", "--target", "wasm64", "-o", "build/spike_probe.wasm", "--export", "spike_probe_*")
    js = f"""import('{ludens_wasm_rt.HOST_MJS}').then(async m => {{
      const rt = await m.instantiate(require('fs').readFileSync('{ROOT / 'build/spike_probe.wasm'}'));
      const p = rt.alloc(8 * {len(NAMES)});
      if (rt.call('spike_probe_run', p) !== 0) throw new Error('spike_probe_run failed');
      const v = new BigUint64Array(rt.mem(), Number(p), {len(NAMES)});
      console.log([...v].join(' '));
    }})"""
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stdout + r.stderr[-1500:])
    wasm = r.stdout.split()
    ok = True
    for name, a, b in zip(NAMES, nat, wasm):
        ok &= a == b
        print(f"{name:6} native {a:>22}  wasm64 {b:>22}  {'equal' if a == b else 'DIFFERENT'}")
    print("spike probe:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
