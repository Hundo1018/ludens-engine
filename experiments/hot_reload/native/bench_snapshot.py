#!/usr/bin/env python3
"""H3 snapshot cost: the hand-written word format (engine.mojo as of H2,
commit d1db36a) against the ecs/schema.mojo format (current engine.mojo), for
10 / 1k / 100k entities.

    python3 experiments/hot_reload/native/bench_snapshot.py [--reps 7] [--sizes 10,1000,100000]

Writes build/hot_native/bench_snapshot.json and prints median save / load
times. Gate (ROADMAP_EXPERIMENT H3): schema snapshot < 16.7 ms at 100k.
"""
from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_native import HERE, OUT, ROOT, mojo, sh  # noqa: E402

HAND_COMMIT = "d1db36a"  # H2: last engine.mojo with the hand-written snapshot


def build() -> dict[str, Path]:
    d = OUT / "bench_snapshot"
    d.mkdir(parents=True, exist_ok=True)
    hand_src = d / "engine_hand.mojo"
    hand_src.write_text(subprocess.run(["git", "show", f"{HAND_COMMIT}:experiments/hot_reload/native/engine.mojo"],
                                       cwd=ROOT, check=True, capture_output=True, text=True).stdout)
    libs = {"hand": d / "libhand.so", "schema": d / "libschema.so"}
    for mode, src in (("hand", hand_src), ("schema", HERE / "engine.mojo")):
        sh([mojo(), "build", "--emit", "shared-lib", "-I", "build", "-I", str(HERE), str(src), "-o", str(libs[mode])],
           stdout=subprocess.DEVNULL)
    sh([mojo(), "build", "-I", "build", "-I", str(HERE), str(HERE / "bench_snapshot.mojo"), "-o",
        str(d / "bench_snapshot")], stdout=subprocess.DEVNULL)
    return libs


def run(lib: Path, mode: str, n: int, reps: int) -> list[dict]:
    p = subprocess.run([str(OUT / "bench_snapshot" / "bench_snapshot"), str(lib), mode, str(n), str(reps)],
                       cwd=ROOT, check=True, capture_output=True, text=True, timeout=600)
    rows = []
    for line in p.stdout.splitlines():
        kv = dict(t.split("=", 1) for t in line.split())
        rows.append({"bytes": int(kv["bytes"]), "save_us": float(kv["save_us"]), "load_us": float(kv["load_us"]),
                     "equal": kv["equal"] == "1"})
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reps", type=int, default=7)
    ap.add_argument("--sizes", default="10,1000,100000")
    a = ap.parse_args()
    libs = build()
    out, ok = [], True
    print(f"{'format':<8}{'entities':>9}{'bytes':>11}{'save ms':>10}{'load ms':>10}{'total ms':>10}  equal")
    for n in (int(x) for x in a.sizes.split(",")):
        for mode in ("hand", "schema"):
            rows = run(libs[mode], mode, n, a.reps)
            save = statistics.median(r["save_us"] for r in rows) / 1000
            load = statistics.median(r["load_us"] for r in rows) / 1000
            eq = all(r["equal"] for r in rows)
            ok &= eq
            out.append({"format": mode, "entities": n - 1, "bytes": rows[0]["bytes"], "save_ms": save,
                        "load_ms": load, "total_ms": save + load, "equal": eq, "reps": a.reps})
            print(f"{mode:<8}{n - 1:>9}{rows[0]['bytes']:>11}{save:>10.3f}{load:>10.3f}{save + load:>10.3f}  {eq}")
    (OUT / "bench_snapshot.json").write_text(json.dumps(out, indent=2))
    big = [r for r in out if r["format"] == "schema" and r["entities"] >= 99_999]
    if big:
        verdict = "PASS" if big[0]["total_ms"] < 16.7 else "FAIL"
        print(f"{verdict}  gate: schema save + load at {big[0]['entities']} entities = "
              f"{big[0]['total_ms']:.2f} ms (limit 16.7)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
