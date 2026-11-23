#!/usr/bin/env python3
"""Physics tick cost of n awake resting boxes against one ludens-core checkout, native (serial) and wasm64 under node.

    pixi run -e wasm phys-profile [--core DIR] [--sizes 200,1000] [--cfg 4x4,1x4] [--reps 7] [--no-wasm]

`--core` defaults to the pinned core (build/deps/ludens-core); pass another checkout (a branch under test) to compare.
Each cell is the minimum over `--reps` runs of the mean per-tick time of 30 (or 8 for n >= 1000) ticks after 3 warm-up
ticks, and the world hash after them (the hash must not depend on the target). The same entry,
`app/phys_profile.mojo`, also runs by hand under valgrind for a per-function breakdown."""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent


def variant(src: Path, tag: str) -> Path:
    """`src` with its [native] section built single-threaded (LUDENS_SERIAL=True), the wasm code path."""
    dst = ROOT / "build/deps" / f"core-profile-{tag}"
    subprocess.run(["rm", "-rf", str(dst)], check=True)
    dst.mkdir(parents=True)
    for f in src.iterdir():
        if f.name not in ("wasm.toml", ".git", "build", "build64", ".pixi"):
            (dst / f.name).symlink_to(f)
    head, sep, native = (src / "wasm.toml").read_text().partition("[native]")
    native = native.replace("LUDENS_SERIAL=False", "LUDENS_SERIAL=True")
    if "LUDENS_SERIAL=True" not in native:
        native = (native.replace("mojo_defines = [", 'mojo_defines = ["LUDENS_SERIAL=True", ', 1)
                  if "mojo_defines = [" in native else native + '\nmojo_defines = ["LUDENS_SERIAL=True"]\n')
    (dst / "wasm.toml").write_text(head + sep + native)
    return dst


def build(core: Path, *extra: str) -> None:
    cmd = [sys.executable, "-m", "ludens_wasm_rt.build_wasm", "--lib", str(core), "--lib", ".", "-I", str(core), "-I", ".",
           "app/phys_profile.mojo", *extra]
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=False)
    if p.returncode:
        sys.exit(p.stdout + p.stderr[-3000:])


def ticks_for(n: int) -> int:
    return 8 if n >= 1000 else 30


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--core", type=Path, default=ROOT / "build/deps/ludens-core")
    ap.add_argument("--sizes", default="200,1000")
    ap.add_argument("--cfg", default="4x4,1x4", help="iters x substeps, comma-separated")
    ap.add_argument("--reps", type=int, default=7)
    ap.add_argument("--no-wasm", action="store_true")
    a = ap.parse_args()
    subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    (ROOT / "build").mkdir(exist_ok=True)
    import native_libs
    native_libs.build_all()
    core = a.core.resolve()
    tag = core.name
    build(variant(core, tag), "--target", "native", "-o", f"build/phys_profile_{tag}")
    if not a.no_wasm:
        build(core, "--target", "wasm64", "-o", f"build/phys_profile_{tag}.wasm", "--export", "phys_profile_*")
    sizes = [int(x) for x in a.sizes.split(",")]
    cfgs = [tuple(int(v) for v in c.split("x")) for c in a.cfg.split(",")]
    rows = {}
    for n in sizes:
        for it, sub in cfgs:
            best, h = None, None
            for _ in range(a.reps):
                out = subprocess.run([str(ROOT / f"build/phys_profile_{tag}"), str(n), str(ticks_for(n)), str(it), str(sub)],
                                     capture_output=True, text=True, check=True).stdout
                ms = float(re.search(r"ms_per_tick ([\d.e+-]+)", out).group(1))
                h = re.search(r"hash (\d+)", out).group(1)
                best = ms if best is None else min(best, ms)
            rows[(n, it, sub)] = {"native": best, "hash": h}
    if not a.no_wasm:
        cells = [[n, it, sub, ticks_for(n)] for (n, it, sub) in rows]
        js = f"""import('{ludens_wasm_rt.HOST_MJS}').then(async m => {{
          const rt = await m.instantiate(require('fs').readFileSync('{ROOT / f"build/phys_profile_{tag}.wasm"}'));
          const p = rt.alloc(16); const out = [];
          for (const [n, it, sub, t] of {json.dumps(cells)}) {{
            let best = Infinity, h = '';
            for (let r = 0; r < {a.reps}; r++) {{
              if (rt.call('phys_profile_run', n, t, it, sub, 3, p) !== 0) throw new Error('phys_profile_run failed');
              const v = new BigUint64Array(rt.mem(), Number(p), 2);
              best = Math.min(best, Number(v[0]) / 1e6); h = v[1].toString();
            }}
            out.push([n, it, sub, best, h]);
          }}
          console.log(JSON.stringify(out));
        }})"""
        r = subprocess.run(["node", "-e", js], capture_output=True, text=True, check=False)
        if r.returncode:
            sys.exit(r.stdout + r.stderr[-2000:])
        for n, it, sub, ms, h in json.loads(r.stdout):
            rows[(n, it, sub)]["wasm"] = ms
            rows[(n, it, sub)]["wasm_hash"] = h
    print(f"core: {core}")
    print("| boxes | iters x substeps | native ms/tick | wasm64 ms/tick | hash | wasm hash = native |")
    print("|---:|---|---:|---:|---|:---:|")
    ok = True
    for (n, it, sub), v in rows.items():
        w = v.get("wasm")
        same = "-" if w is None else ("yes" if v["wasm_hash"] == v["hash"] else "NO")
        ok &= same != "NO"
        print(f"| {n} | {it} x {sub} | {v['native']:.3f} | {'-' if w is None else f'{w:.3f}'} | {v['hash']} | {same} |")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
