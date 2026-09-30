#!/usr/bin/env python3
"""R2b follow-ups F1 and F2 (predictions_r2.py, R2b section, committed before
this script ran).

F1  exe_all_O3 (mono_all.mojo: every engine export called) vs so_O3,
    interleaved, N_REPS each, uncached.
F2  so_O0 vs so_O3 with --mlir-timing, F2_REPS each, interleaved, uncached:
    MLIR root wall and the rest (wall - MLIR root).

    python3 experiments/hot_reload/native/compile_speed_followup.py
Writes build/hot_native/compile_speed_followup.json.
"""
from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import predictions_r2 as P  # noqa: E402
from compile_speed import stats, timed  # noqa: E402
from run_native import HERE, OUT  # noqa: E402

TIMING = ["--mlir-timing", "--mlir-timing-display=list", "--timing-json"]


def main() -> int:
    work = OUT / "r2b"
    work.mkdir(parents=True, exist_ok=True)
    eng = str(HERE / "engine.mojo")
    so = lambda opt: ["build", "--emit", "shared-lib", *opt, eng, "-o", str(work / "e.so")]  # noqa: E731
    exe_all = ["build", str(HERE / "mono_all.mojo"), "-o", str(work / "mono_all")]

    f1 = {"so_O3": [], "exe_all_O3": []}
    for rep in range(P.N_REPS):
        for name, args in (("so_O3", so([])), ("exe_all_O3", exe_all))[:: 1 if rep % 2 == 0 else -1]:
            f1[name].append(timed(args)[0])
    f1s = {k: stats(v) for k, v in f1.items()}
    d1 = f1s["exe_all_O3"]["median"] - f1s["so_O3"]["median"]
    ok1 = P.F1_EXE_ALL_MINUS_SO_S[0] <= d1 <= P.F1_EXE_ALL_MINUS_SO_S[1]

    f2 = {"so_O3": {"wall": [], "mlir": []}, "so_O0": {"wall": [], "mlir": []}}
    for rep in range(P.F2_REPS):
        for name, opt in (("so_O3", []), ("so_O0", ["-O0"]))[:: 1 if rep % 2 == 0 else -1]:
            wall, _, err = timed(so(opt), TIMING)
            j = json.loads(err[err.find("{"):])
            root = next(r["wall"]["duration"] for r in j["mlir"] if r["name"] == "root")
            f2[name]["wall"].append(wall)
            f2[name]["mlir"].append(root)
    med = {n: {k: statistics.median(v) for k, v in d.items()} for n, d in f2.items()}
    mlir_diff = med["so_O0"]["mlir"] - med["so_O3"]["mlir"]
    rest_diff = (med["so_O0"]["wall"] - med["so_O0"]["mlir"]) - (med["so_O3"]["wall"] - med["so_O3"]["mlir"])
    ok2a = mlir_diff >= P.F2_MLIR_DIFF_MIN_S
    ok2b = P.F2_REST_DIFF_S[0] <= rest_diff <= P.F2_REST_DIFF_S[1]

    print(f"F1  so_O3 median {f1s['so_O3']['median']:.2f} s (IQR {f1s['so_O3']['iqr']:.2f}), "
          f"exe_all_O3 median {f1s['exe_all_O3']['median']:.2f} s (IQR {f1s['exe_all_O3']['iqr']:.2f})")
    print(f"{'PASS' if ok1 else 'FAIL'}  F1 exe_all_O3 - so_O3 = {d1:+.3f} s, predicted {P.F1_EXE_ALL_MINUS_SO_S}")
    for n in ("so_O3", "so_O0"):
        print(f"F2  {n}: wall {med[n]['wall']:.2f} s, MLIR root {med[n]['mlir']:.2f} s, "
              f"rest {med[n]['wall'] - med[n]['mlir']:.2f} s")
    print(f"{'PASS' if ok2a else 'FAIL'}  F2 MLIR O0 - O3 = {mlir_diff:+.3f} s, predicted >= {P.F2_MLIR_DIFF_MIN_S}")
    print(f"{'PASS' if ok2b else 'FAIL'}  F2 rest O0 - O3 = {rest_diff:+.3f} s, predicted {P.F2_REST_DIFF_S}")
    (OUT / "compile_speed_followup.json").write_text(json.dumps(
        {"f1": f1s, "f1_diff_s": d1, "f2": f2, "f2_median": med, "f2_mlir_diff_s": mlir_diff,
         "f2_rest_diff_s": rest_diff, "pass": {"F1": ok1, "F2_mlir": ok2a, "F2_rest": ok2b}}, indent=2))
    return 0 if ok1 and ok2a and ok2b else 1


if __name__ == "__main__":
    sys.exit(main())
