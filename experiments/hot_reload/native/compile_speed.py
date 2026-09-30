#!/usr/bin/env python3
"""R2: how long does the hot build take next to an ordinary build?

Conditions, each built with an empty MODULAR_CACHE_DIR, in a shuffled order
per repetition:

  so_O3       engine.mojo -> shared lib (what the hot path rebuilds)
  so_O0       same, -O0
  exe_O3      mono.mojo: engine + main loop as one program (the ordinary build)
  exe_O0      same, -O0
  exe_all_O3  mono_all.mojo: like mono.mojo but calls every engine export
  run_O3      `mojo run mono.mojo` (JIT, no external link)
  empty_so    a module with one export

Also: start + replay time of the exe_O3 program, the MLIR pass split of
so_O3 and so_O0, and the number of functions in their LLVM IR.

    python3 experiments/hot_reload/native/compile_speed.py [--reps 10] [--seed 1]

Needs `run_native.py build` first. Writes build/hot_native/compile_speed.json.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import random
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_native import HERE, OUT, ROOT, mojo  # noqa: E402

# Written before the first run. Hypothesis: the Mojo front end dominates at
# this code size, so the kind of output and the -O level change little.
PREDICTIONS = {
    "exe_O3 - so_O3 (s)": (-0.3, 0.5),
    "cold - hot (s)": (float("-inf"), 0.5),
    "exe_O3 - run_O3 (s)": (0.05, 0.4),
    "so_O0 / so_O3": (0.8, 1.2),
    "empty_so / so_O3": (0.5, float("inf")),
    # added after the first run refuted the first line: the gap is exports
    # the program never calls
    "exe_all_O3 - so_O3 (s)": (-0.3, 0.3),
}
EMPTY = '@export\ndef probe_value() abi("C") -> Int:\n    return 1\n'
TIMING = ["--mlir-timing", "--mlir-timing-display=list", "--timing-json"]


def conditions(work: Path) -> dict[str, list[str]]:
    (work / "empty.mojo").write_text(EMPTY)
    eng, mono = str(HERE / "engine.mojo"), str(HERE / "mono.mojo")
    return {
        "so_O3": ["build", "--emit", "shared-lib", eng, "-o", str(work / "a.so")],
        "so_O0": ["build", "--emit", "shared-lib", "-O0", eng, "-o", str(work / "b.so")],
        "exe_O3": ["build", mono, "-o", str(work / "exe_O3")],
        "exe_O0": ["build", "-O0", mono, "-o", str(work / "exe_O0")],
        "exe_all_O3": ["build", str(HERE / "mono_all.mojo"), "-o", str(work / "exe_all")],
        "run_O3": ["run", mono],
        "empty_so": ["build", "--emit", "shared-lib", str(work / "empty.mojo"), "-o", str(work / "e.so")],
    }


def timed(args: list[str], extra: list[str] | None = None) -> tuple[float, str, str]:
    """One invocation with an empty cache: (seconds, stdout, stderr)."""
    with tempfile.TemporaryDirectory() as cache:
        cmd = [mojo(), args[0], *(extra or []), "-I", "build", "-I", str(HERE), *args[1:]]
        t0 = time.perf_counter()
        p = subprocess.run(cmd, cwd=ROOT, env={**os.environ, "MODULAR_CACHE_DIR": cache},
                           capture_output=True, text=True)
        dt = time.perf_counter() - t0
    if p.returncode != 0:
        raise SystemExit(f"failed: {' '.join(cmd)}\n{p.stderr[-2000:]}")
    return dt, p.stdout, p.stderr


def stats(xs: list[float]) -> dict:
    q = statistics.quantiles(xs, n=4)
    return {"median": statistics.median(xs), "q1": q[0], "q3": q[2], "min": min(xs), "max": max(xs), "runs": xs}


def passes(args: list[str]) -> dict[str, float]:
    _, _, err = timed(args, TIMING)
    return {r["name"]: r["wall"]["duration"] for r in json.loads(err[err.find("{"):])["mlir"]}


def functions(opt: list[str], out: Path) -> int:
    timed(["build", "--emit", "llvm", *opt, str(HERE / "engine.mojo"), "-o", str(out)])
    return sum(1 for line in out.read_text().splitlines() if line.startswith("define"))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reps", type=int, default=10)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    work = Path(tempfile.mkdtemp(prefix="r2_"))
    conds = conditions(work)
    rng = random.Random(a.seed)
    times: dict[str, list[float]] = {c: [] for c in conds}
    replay: list[float] = []
    for rep in range(a.reps):
        order = list(conds)
        rng.shuffle(order)
        for c in order:
            dt, out, _ = timed(conds[c])
            times[c].append(dt)
            if c == "exe_O3":
                t0 = time.perf_counter()
                out = subprocess.run([str(work / "exe_O3")], capture_output=True, text=True).stdout
                replay.append(time.perf_counter() - t0)
            if c in ("exe_O3", "run_O3") and "frame=70 count=6" not in out:
                raise SystemExit(f"{c}: unexpected output {out!r}")
        print(f"rep {rep + 1}/{a.reps}: " + "  ".join(f"{c} {times[c][-1]:.2f}" for c in conds), flush=True)

    s = {c: stats(v) for c, v in times.items()}
    m = {c: v["median"] for c, v in s.items()}
    bench = OUT / "bench_summary.json"
    swap = json.loads(bench.read_text())["swap"]["close"]["median_us"] / 1e6 if bench.exists() else 1e-4
    hot, cold = m["so_O3"] + swap, m["exe_O3"] + statistics.median(replay)
    values = {
        "exe_O3 - so_O3 (s)": m["exe_O3"] - m["so_O3"],
        "cold - hot (s)": cold - hot,
        "exe_O3 - run_O3 (s)": m["exe_O3"] - m["run_O3"],
        "so_O0 / so_O3": m["so_O0"] / m["so_O3"],
        "empty_so / so_O3": m["empty_so"] / m["so_O3"],
        "exe_all_O3 - so_O3 (s)": m["exe_all_O3"] - m["so_O3"],
    }
    p3, p0 = passes(conds["so_O3"]), passes(conds["so_O0"])
    diff = sorted(((n, p0.get(n, 0.0), p3.get(n, 0.0)) for n in set(p3) | set(p0) if n not in ("root", "Total")),
                  key=lambda r: -abs(r[1] - r[2]))[:10]
    fn = {"O3": functions([], work / "o3.ll"), "O0": functions(["-O0"], work / "o0.ll")}

    cpu = next((l.split(":", 1)[1].strip() for l in Path("/proc/cpuinfo").read_text().splitlines()
                if l.startswith("model name")), "?")
    ver = subprocess.run([mojo(), "--version"], capture_output=True, text=True).stdout.strip()
    print(f"\n{ver}, {cpu}, {os.cpu_count()} CPUs, n={a.reps}, seed {a.seed}, uncached")
    print(f"{'condition':<12}{'median':>8}{'q1':>7}{'q3':>7}{'min':>7}{'max':>7}  (s)")
    for c, v in s.items():
        print(f"{c:<12}{v['median']:8.2f}{v['q1']:7.2f}{v['q3']:7.2f}{v['min']:7.2f}{v['max']:7.2f}")
    print(f"program start + replay {statistics.median(replay) * 1000:.1f} ms, swap {swap * 1000:.3f} ms")
    for name, v in values.items():
        lo, hi = PREDICTIONS[name]
        print(f"{'held   ' if lo <= v <= hi else 'REFUTED'}  {name:<24}{v:8.3f}   predicted [{lo}, {hi}]")
    print(f"LLVM IR functions: O3 {fn['O3']}, O0 {fn['O0']}")
    print("MLIR passes, largest O0 - O3 differences (s):")
    for n, t0, t3 in diff:
        print(f"  {n[:44]:<44}{t0:7.3f}{t3:7.3f}{t0 - t3:+8.3f}")
    (OUT / "compile_speed.json").write_text(json.dumps({
        "mojo": ver, "cpu": cpu, "seed": a.seed, "stats": s, "replay_s": replay, "swap_s": swap,
        "values": values, "predictions": {k: list(v) for k, v in PREDICTIONS.items()},
        "functions": fn, "passes": {"O3": p3, "O0": p0}}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
