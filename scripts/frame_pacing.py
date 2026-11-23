#!/usr/bin/env python3
"""Frame pacing at display rates above the simulation rate, and what physics costs against a 144 Hz frame.

    pixi run -e wasm frame-pacing

Builds app/frame_pacing.mojo natively (serial dispatch, the wasm code path) and app/bench.mojo as wasm64, then prints:
1. the step pattern per (display Hz, simulation Hz): frames with 0 / 1 / 2 ticks, frames in which nothing moves, the
   on-screen step range today (no interpolation) and the worst step error with interpolation;
2. the per-tick physics cost for 10 .. 1000 resting boxes, native and wasm64 under node, against the 6.94 ms frame
   of a 144 Hz display for a 60 Hz and a 144 Hz simulation."""
import json
import re
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from bench import serial_engine  # noqa: E402

SIZES = [10, 50, 100, 200, 500, 1000]
FRAMES = 30
BUDGET_MS = 1000.0 / 144.0


def build(entry: str, *extra: str, engine: Path) -> None:
    cmd = [sys.executable, "-m", "ludens_wasm_rt.build_wasm", "--lib", str(engine), "--lib", ".", "-I", str(engine),
           "-I", ".", entry, *extra]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=False)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)


def wasm_costs() -> dict[int, float]:
    js = f"""import('{ludens_wasm_rt.HOST_MJS}').then(async m => {{
      const rt = await m.instantiate(require('fs').readFileSync('{ROOT / 'build/bench.wasm'}'));
      const p = rt.alloc(24); const out = {{}};
      for (const n of {json.dumps(SIZES)}) {{
        if (rt.call('bench_run', n, {FRAMES}, p) !== 0) throw new Error('bench_run failed');
        const v = new BigUint64Array(rt.mem(), Number(p), 3);
        out[n] = (Number(v[0]) + Number(v[1])) / 1e6;
      }}
      console.log(JSON.stringify(out));
    }})"""
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True, check=False)
    if r.returncode:
        sys.exit(r.stdout + r.stderr[-1500:])
    return {int(k): v for k, v in json.loads(r.stdout).items()}


def main() -> int:
    subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True)
    (ROOT / "build").mkdir(exist_ok=True)
    import native_libs
    native_libs.build_all()
    eng = serial_engine()
    build("app/frame_pacing.mojo", "--target", "native", "-o", "build/frame_pacing", engine=eng)
    build("app/bench.mojo", "--target", "wasm64", "-o", "build/bench.wasm", "--export", "bench_*", engine=ROOT / "build/deps/ludens-core")
    out = subprocess.run([str(ROOT / "build/frame_pacing")], capture_output=True, text=True, check=True).stdout

    print("## Step pattern (2 s per row, the second second counted; exact frame times)\n")
    print("| display Hz | sim Hz | frames with 0 / 1 / 2 ticks | frames that do not move | on-screen step today (x ideal) | worst step error, interpolated |")
    print("|---:|---:|---|---:|---|---:|")
    pat = r"pace display (\d+) sim (\d+) ticks0 (\d+) ticks1 (\d+) ticks2 (\d+) ticks3\+ (\d+) still_frames (\d+) of (\d+) raw_step_min ([\d.e+-]+) raw_step_max ([\d.e+-]+) lerp_err_max ([\d.e+-]+)"
    for m in re.findall(pat, out):
        d, s, t0, t1, t2, t3, still, of, lo, hi, err = m
        print(f"| {d} | {s} | {t0} / {t1} / {int(t2) + int(t3)} | {still} of {of} | {float(lo):.2f} to {float(hi):.2f} | {float(err) * 100:.2f} % |")

    native = {int(n): float(p) + float(g) for n, p, g in re.findall(r"cost n (\d+) physics_ms ([\d.e+-]+) gather_ms ([\d.e+-]+)", out)}
    wasm = wasm_costs()
    print(f"\n## Physics against a 144 Hz frame ({BUDGET_MS:.2f} ms), one tick = physics + pose gather, median of {FRAMES}\n")
    print("| boxes | native ms/tick | wasm64 ms/tick | 60 Hz sim: worst frame (1 tick), wasm | 144 Hz sim: every frame (1 tick), wasm | 144 Hz sim, CPU per second, wasm |")
    print("|---:|---:|---:|---:|---:|---:|")
    for n in SIZES:
        w = wasm[n]
        print(f"| {n} | {native[n]:.3f} | {w:.3f} | {w / BUDGET_MS * 100:.0f} % of the frame | {w / BUDGET_MS * 100:.0f} % of the frame | {w * 144 / 10:.1f} % |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
