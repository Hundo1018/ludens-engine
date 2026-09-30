#!/usr/bin/env python3
"""R2c: does "-O0 builds a shared library slower than -O3" reproduce outside
this engine, and on the nightly compiler? Also: does a warm compilation
cache with never-built code beat an empty cache?

Predictions (predictions_r2.py, R2c) are committed before this script runs.

For each compiler (--mojo, repeatable) and each source (the standalone
probes/probe_o0_cost.mojo; engine.mojo if --engine and it compiles):
  O3 / O0 shared-lib builds, uncached, interleaved, --reps each;
  `define` count of --emit llvm at -O3 and -O0.
Cache (first --mojo only, empty module): empty MODULAR_CACHE_DIR vs a warm
one (the same directory, one earlier build) with a comment line never seen
before (--reps each, interleaved).

    python3 experiments/hot_reload/native/o0_repro.py --mojo .venv/bin/mojo --mojo .venv-nightly/bin/mojo
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = ROOT / "build" / "hot_native" / "r2c"
PROBE = HERE / "probes" / "probe_o0_cost.mojo"


def build(mojo: str, src: Path, opt: list[str], out: Path, cache: str | None, emit: str = "shared-lib",
          extra_i: bool = False) -> float:
    env = dict(os.environ)
    tmp = None
    if cache is None:
        tmp = tempfile.TemporaryDirectory()
        cache = tmp.name
    env["MODULAR_CACHE_DIR"] = cache
    inc = ["-I", str(ROOT / "build"), "-I", str(HERE)] if extra_i else []
    cmd = [mojo, "build", "--emit", emit, *opt, *inc, str(src), "-o", str(out)]
    t0 = time.perf_counter()
    p = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True)
    dt = time.perf_counter() - t0
    if tmp:
        tmp.cleanup()
    if p.returncode != 0:
        raise RuntimeError(p.stderr[-1500:])
    return dt


def version(mojo: str) -> str:
    return subprocess.run([mojo, "--version"], capture_output=True, text=True).stdout.strip()


def o0_vs_o3(mojo: str, src: Path, reps: int, extra_i: bool) -> dict:
    t = {"O3": [], "O0": []}
    for r in range(reps):
        for lvl in (("O3", "O0") if r % 2 == 0 else ("O0", "O3")):
            t[lvl].append(build(mojo, src, [f"-{lvl}"], OUT / "p.so", None, extra_i=extra_i))
    defines = {}
    for lvl in ("O3", "O0"):
        ll = OUT / f"p_{lvl}.ll"
        build(mojo, src, [f"-{lvl}"], ll, None, emit="llvm", extra_i=extra_i)
        defines[lvl] = sum(1 for line in ll.read_text().splitlines() if line.startswith("define"))
    m = {k: statistics.median(v) for k, v in t.items()}
    return {"runs": t, "median": m, "ratio": m["O0"] / m["O3"], "defines": defines,
            "define_ratio": defines["O0"] / defines["O3"]}


def cache_effect(mojo: str, reps: int) -> dict:
    warm = tempfile.mkdtemp(prefix="warm_")
    src = OUT / "empty.mojo"
    body = '@export\ndef probe_value() abi("C") -> Int:\n    return 1\n'
    src.write_text(body)
    build(mojo, src, [], OUT / "e.so", warm)  # warm the cache once
    t = {"empty_cache": [], "warm_cache_new_code": []}
    for r in range(reps):
        order = ("empty_cache", "warm_cache_new_code") if r % 2 == 0 else ("warm_cache_new_code", "empty_cache")
        for k in order:
            src.write_text(f"# unique {time.time_ns()}\n" + body.replace("return 1", f"return {r + 2}"))
            t[k].append(build(mojo, src, [], OUT / "e.so", None if k == "empty_cache" else warm))
    return {"runs": t, "median": {k: statistics.median(v) for k, v in t.items()}}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mojo", action="append", required=True)
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--engine", action="store_true", help="also time engine.mojo (needs build/*.mojoc)")
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    res: dict = {"compilers": {}}
    for mojo in a.mojo:
        v = version(mojo)
        row = {"probe": o0_vs_o3(mojo, PROBE, a.reps, False)}
        if a.engine:
            try:
                row["engine"] = o0_vs_o3(mojo, HERE / "engine.mojo", a.reps, True)
            except RuntimeError as e:
                row["engine"] = {"error": str(e)[-400:]}
        res["compilers"][v] = row
        for src, r in row.items():
            if "error" in r:
                print(f"{v:<32} {src:<7} does not build: {r['error'][-160:]!r}")
                continue
            print(f"{v:<32} {src:<7} O3 {r['median']['O3']:.2f} s  O0 {r['median']['O0']:.2f} s  "
                  f"ratio {r['ratio']:.2f}   defines O3 {r['defines']['O3']} O0 {r['defines']['O0']} "
                  f"({r['define_ratio']:.1f}x)")
    res["cache"] = cache_effect(a.mojo[0], a.reps)
    c = res["cache"]["median"]
    print(f"cache ({version(a.mojo[0])}, empty module): empty cache {c['empty_cache']:.2f} s, "
          f"warm cache + new code {c['warm_cache_new_code']:.2f} s")
    (OUT / "o0_repro.json").write_text(json.dumps(res, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
