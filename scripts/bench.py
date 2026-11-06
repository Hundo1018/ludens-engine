#!/usr/bin/env python3
"""B3: median per-frame CPU cost (physics tick + pose gather) for 1e3 / 1e4 bodies, wasm64 under node vs native.

    pixi run -e wasm bench
Both are built from app/bench.mojo through the one driver; native is pinned to serial dispatch like wasm."""
import re
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent
D = ROOT / "build/deps"
SIZES = {1000: 30, 10000: 10}


def _engine_variant(name: str, serial: bool) -> Path:
    """A copy of the pinned engine whose [native] section says LUDENS_SERIAL=<serial>. Older engine revs built native
    parallel (LUDENS_SERIAL=False in [native]); newer ones build the serial no-FMA reference. Either way this gives
    the variant asked for, so the comparison does not depend on which one the pin has."""
    dst = ROOT / "build/deps" / name
    subprocess.run(["rm", "-rf", str(dst)], check=True)
    dst.mkdir(parents=True)
    src = D / "ludens-engine"
    for f in src.iterdir():
        if f.name != "wasm.toml":
            (dst / f.name).symlink_to(f)
    head, sep, native = (src / "wasm.toml").read_text().partition("[native]")
    assert sep, "wasm.toml has no [native] section"
    want, other = ("True", "False") if serial else ("False", "True")
    native = native.replace(f"LUDENS_SERIAL={other}", f"LUDENS_SERIAL={want}")
    if f"LUDENS_SERIAL={want}" not in native:  # the section had no LUDENS_SERIAL define at all
        native = native.replace("mojo_defines = [", f'mojo_defines = ["LUDENS_SERIAL={want}", ', 1) if "mojo_defines = [" in native else native + f'\nmojo_defines = ["LUDENS_SERIAL={want}"]\n'
    (dst / "wasm.toml").write_text(head + sep + native)
    return dst


def serial_engine() -> Path:
    """The pinned engine with native built single-threaded, the same code path as wasm."""
    return _engine_variant("ludens-engine-serial", True)


def parallel_engine() -> Path:
    """The pinned engine with native built with parallel dispatch (what an engine's own native build used to be)."""
    return _engine_variant("ludens-engine-parallel", False)


def build(*extra: str, engine: Path = D / "ludens-engine") -> None:
    cmd = [sys.executable, "-m", "ludens_wasm_rt.build_wasm", "--lib", str(engine), "--lib", ".",
           "-I", str(engine), "app/bench.mojo", *extra]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)


def main() -> int:
    subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True)
    (ROOT / "build").mkdir(exist_ok=True)
    import native_libs
    native_libs.build_all()
    build("--target", "native", "-o", "build/bench", engine=parallel_engine())  # parallel dispatch
    build("--target", "native", "-o", "build/bench_serial", engine=serial_engine())
    build("--target", "wasm64", "-o", "build/bench.wasm", "--export", "bench_*")
    native = subprocess.run([str(ROOT / "build/bench_serial")], capture_output=True, text=True, check=True).stdout
    parallel = subprocess.run([str(ROOT / "build/bench")], capture_output=True, text=True, check=True).stdout
    print("native serial:\n" + native.strip() + "\nnative parallel:\n" + parallel.strip())
    par = {int(m[0]): m[1:] for m in re.findall(r"n (\d+) frames \d+ physics_ms ([\d.]+) gather_ms ([\d.]+) hash (\d+)", parallel)}
    nat = {int(m[0]): m[1:] for m in re.findall(r"n (\d+) frames \d+ physics_ms ([\d.]+) gather_ms ([\d.]+) hash (\d+)", native)}
    js = f"""import('{ludens_wasm_rt.HOST_MJS}').then(async m => {{
      const rt = await m.instantiate(require('fs').readFileSync('{ROOT / 'build/bench.wasm'}'));
      const p = rt.alloc(24);
      const out = {{}};
      for (const [n, frames] of {__import__("json").dumps(list(SIZES.items()))}) {{
        if (rt.call('bench_run', n, frames, p) !== 0) throw new Error('bench_run failed');
        const v = new BigUint64Array(rt.mem(), Number(p), 3);
        out[n] = [Number(v[0]) / 1e6, Number(v[1]) / 1e6, v[2].toString()];
      }}
      console.log(JSON.stringify(out));
    }})"""
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stdout + r.stderr[-1500:])
    wasm = __import__("json").loads(r.stdout)
    print("\n| bodies | native serial ms/frame | wasm64 ms/frame | wasm / native serial | native parallel ms/frame | wasm / native parallel | pose hash wasm = native serial |")
    print("|---:|---:|---:|---:|---:|---:|:---:|")
    ok = True
    for n in SIZES:
        np_, ng, nh = float(nat[n][0]), float(nat[n][1]), nat[n][2]
        wp, wg, wh = wasm[str(n)]
        same = nh == wh
        ok &= same
        pp, pg = float(par[n][0]), float(par[n][1])
        print(f"| {n} | {np_ + ng:.2f} ({np_:.2f} + {ng:.2f}) | {wp + wg:.2f} ({wp:.2f} + {wg:.2f}) | {(wp + wg) / (np_ + ng):.2f}x "
              f"| {pp + pg:.2f} ({pp:.2f} + {pg:.2f}) | {(wp + wg) / (pp + pg):.2f}x | {'yes' if same else 'NO'} |")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
