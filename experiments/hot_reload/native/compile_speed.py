#!/usr/bin/env python3
"""R2: hot compile against the ordinary compile (predictions_r2.py, committed
before this script).

Conditions (predictions_r2.py): so_O3, so_O0, exe_O3, exe_O0, run_O3,
empty_so. Every build gets an empty MODULAR_CACHE_DIR; the order of the
conditions is shuffled in each repetition (seeded, recorded). After each
exe_O3 build the executable is run once to time start + replay (the cold
path's cost after the build).

One extra build per condition with --mlir-timing (not part of the timing
statistics) gives the phase split.

    python3 experiments/hot_reload/native/compile_speed.py [--reps 10] [--seed 1]

Needs `run_native.py build` first (precompiled packages in build/).
Writes build/hot_native/compile_speed.json.
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
import predictions_r2 as P  # noqa: E402
from run_native import HERE, OUT, ROOT, mojo  # noqa: E402

EMPTY = '''
@export
def probe_value() abi("C") -> Int:
    return 1
'''


def conditions(work: Path) -> dict[str, list[str]]:
    empty = work / "empty.mojo"
    empty.write_text(EMPTY)
    eng, mono = str(HERE / "engine.mojo"), str(HERE / "mono.mojo")
    return {
        "so_O3": ["build", "--emit", "shared-lib", eng, "-o", str(work / "so_O3.so")],
        "so_O0": ["build", "--emit", "shared-lib", "-O0", eng, "-o", str(work / "so_O0.so")],
        "exe_O3": ["build", mono, "-o", str(work / "exe_O3")],
        "exe_O0": ["build", "-O0", mono, "-o", str(work / "exe_O0")],
        "run_O3": ["run", mono],
        "empty_so": ["build", "--emit", "shared-lib", str(empty), "-o", str(work / "empty.so")],
    }


def timed(args: list[str], extra: list[str] | None = None) -> tuple[float, str, str]:
    """One uncached invocation; returns (seconds, stdout, stderr)."""
    cmd, rest = args[0], args[1:]
    with tempfile.TemporaryDirectory() as cache:
        env = {**os.environ, "MODULAR_CACHE_DIR": cache}
        full = [mojo(), cmd, *(extra or []), "-I", "build", "-I", str(HERE), *rest]
        t0 = time.perf_counter()
        p = subprocess.run(full, cwd=ROOT, env=env, capture_output=True, text=True)
        dt = time.perf_counter() - t0
    if p.returncode != 0:
        raise SystemExit(f"failed: {' '.join(full)}\n{p.stderr[-2000:]}")
    return dt, p.stdout, p.stderr


def stats(xs: list[float]) -> dict:
    q = statistics.quantiles(xs, n=4)
    return {"median": statistics.median(xs), "q1": q[0], "q3": q[2], "iqr": q[2] - q[0],
            "min": min(xs), "max": max(xs), "n": len(xs), "runs": xs}


def phases(stderr: str, top: int = 8) -> list[tuple[str, float]]:
    j = json.loads(stderr[stderr.find("{"):])
    rows = [(r["name"], r["wall"]["duration"]) for r in j["mlir"] if r["name"] not in ("root", "Total")]
    return sorted(rows, key=lambda r: -r[1])[:top]


def machine() -> dict:
    model = next((l.split(":", 1)[1].strip() for l in Path("/proc/cpuinfo").read_text().splitlines()
                  if l.startswith("model name")), "?")
    ver = subprocess.run([mojo(), "--version"], capture_output=True, text=True).stdout.strip()
    return {"cpu": model, "nproc": os.cpu_count(), "mojo": ver, "python": platform.python_version(),
            "kernel": platform.release()}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reps", type=int, default=P.N_REPS)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    work = Path(tempfile.mkdtemp(prefix="r2_"))
    conds = conditions(work)
    rng = random.Random(a.seed)
    times: dict[str, list[float]] = {c: [] for c in conds}
    replay: list[float] = []
    orders = []
    for rep in range(a.reps):
        order = list(conds)
        rng.shuffle(order)
        orders.append(order)
        for c in order:
            dt, out, _ = timed(conds[c])
            times[c].append(dt)
            if c == "run_O3" and "frame=70 count=6" not in out:
                raise SystemExit(f"run_O3 output unexpected: {out!r}")
            if c == "exe_O3":
                t0 = time.perf_counter()
                p = subprocess.run([str(work / "exe_O3")], capture_output=True, text=True)
                replay.append(time.perf_counter() - t0)
                if "frame=70 count=6" not in p.stdout:
                    raise SystemExit(f"exe_O3 output unexpected: {p.stdout!r}")
        print(f"rep {rep + 1}/{a.reps}: " + "  ".join(f"{c} {times[c][-1]:.2f}" for c in conds), flush=True)

    split = {}
    for c in ("so_O3", "exe_O3", "empty_so"):
        _, _, err = timed(conds[c], ["--mlir-timing", "--mlir-timing-display=list", "--timing-json"])
        split[c] = phases(err)

    s = {c: stats(v) for c, v in times.items()}
    bench = OUT / "bench_summary.json"
    swap_s = (json.loads(bench.read_text())["swap"]["close"]["median_us"] / 1e6) if bench.exists() else 1e-4
    hot = s["so_O3"]["median"] + swap_s
    cold = s["exe_O3"]["median"] + statistics.median(replay)
    m = {c: s[c]["median"] for c in s}
    checks = {
        "P1 exe_O3 - so_O3 (s)": (m["exe_O3"] - m["so_O3"], P.P1_EXE_MINUS_SO_S),
        "P2 cold - hot (s)": (cold - hot, (float("-inf"), P.P2_COLD_MINUS_HOT_MAX_S)),
        "P3 exe_O3 - run_O3 (s)": (m["exe_O3"] - m["run_O3"], P.P3_EXE_MINUS_RUN_S),
        "P4 so_O0 / so_O3": (m["so_O0"] / m["so_O3"], P.P4_O0_OVER_O3),
        "P5 empty_so / so_O3": (m["empty_so"] / m["so_O3"], (P.P5_EMPTY_OVER_ENGINE_MIN, float("inf"))),
    }
    print(f"\nmachine: {machine()}")
    print(f"{'condition':<10}{'median':>8}{'q1':>8}{'q3':>8}{'min':>8}{'max':>8}   (s, n={a.reps}, uncached)")
    for c, v in s.items():
        print(f"{c:<10}{v['median']:8.2f}{v['q1']:8.2f}{v['q3']:8.2f}{v['min']:8.2f}{v['max']:8.2f}")
    print(f"exe start + replay: median {statistics.median(replay) * 1000:.1f} ms;  swap {swap_s * 1000:.3f} ms")
    print(f"hot = {hot:.2f} s, cold = {cold:.2f} s")
    fails = 0
    for name, (val, (lo, hi)) in checks.items():
        ok = lo <= val <= hi
        fails += not ok
        print(f"{'PASS' if ok else 'FAIL'}  {name:<26} {val:8.3f}  predicted [{lo}, {hi}]")
    for c, rows in split.items():
        print(f"phases {c}: " + ", ".join(f"{n} {t:.2f}" for n, t in rows))
    (OUT / "compile_speed.json").write_text(json.dumps({
        "machine": machine(), "seed": a.seed, "orders": orders, "stats": s, "replay_s": replay,
        "swap_s": swap_s, "hot_s": hot, "cold_s": cold, "phases": split,
        "checks": {k: {"value": v, "predicted": list(r), "pass": r[0] <= v <= r[1]} for k, (v, r) in checks.items()},
    }, indent=2))
    print("wrote build/hot_native/compile_speed.json")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
