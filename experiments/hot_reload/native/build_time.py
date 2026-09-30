#!/usr/bin/env python3
"""Time `mojo build --emit shared-lib` for one or more Mojo sources, interleaved.

    python3 experiments/hot_reload/native/build_time.py A.mojo B.mojo [--reps 5] [-I dir ...]

Runs the sources round-robin (A, B, A, B, ...) so machine drift hits every
source alike, and prints median / min / max seconds per source. Each build
writes to a fresh path under build/hot_native/build_time/. With --unique,
each build compiles a copy of the source with a distinct trailing
`comptime _BUILD_UNIQUE = <ns>` line, so no two builds see the same code. (A
distinct trailing comment is not enough: --probe-cache shows the cache
ignores comments.)
"""
from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_native import HERE, OUT, ROOT, mojo  # noqa: E402


def time_build(src: Path, dest: Path, includes: list[str], emit: str) -> float:
    dest.parent.mkdir(parents=True, exist_ok=True)
    cmd = [mojo(), "build", *(["--emit", emit] if emit else []), *sum((["-I", i] for i in includes), []),
           str(src), "-o", str(dest)]
    t0 = time.perf_counter()
    subprocess.run(cmd, cwd=ROOT, check=True, capture_output=True)
    return time.perf_counter() - t0


def measure(sources: list[Path], reps: int, includes: list[str], emit: str = "shared-lib",
            unique: bool = False) -> dict:
    times: dict[str, list[float]] = {str(s): [] for s in sources}
    n = 0
    for _ in range(reps):
        for s in sources:
            n += 1
            d = OUT / "build_time" / str(n)
            src = s
            if unique:
                d.mkdir(parents=True, exist_ok=True)
                src = d / s.name
                src.write_text(s.read_text() + f"\ncomptime _BUILD_UNIQUE = {time.time_ns()}\n")
            times[str(s)].append(time_build(src, d / "lib.so", includes, emit))
    return {k: {"median": statistics.median(v), "min": min(v), "max": max(v), "n": len(v)} for k, v in times.items()}


def probe_cache(src: Path, reps: int, includes: list[str]) -> dict:
    """What the compile cache is keyed on. Every condition is timed after a
    warm-up build of its own starting point, `reps` times:
      warm         same path, same content (control: expected cache hit)
      new_path     same content copied to a new path
      new_content  same path, content changed (a new trailing comment)
      revert       same path, content changed and then changed back to one
                   that was built before at this path (A -> B -> A)
      touch        same path, same content, mtime bumped
      code_edit    same path, `SPEED` set to a value not built before
    """
    base = src.read_text()
    root = OUT / "build_time" / "probe"
    res: dict[str, list[float]] = {k: [] for k in ("warm", "new_path", "new_content", "revert", "touch",
                                                         "code_edit")}
    for r in range(reps):
        d = root / f"r{r}"
        d.mkdir(parents=True, exist_ok=True)
        f = d / "engine.mojo"
        f.write_text(base)
        time_build(f, d / "w.so", includes, "shared-lib")  # warm-up
        res["warm"].append(time_build(f, d / "a.so", includes, "shared-lib"))
        g = d / "copy" / "engine.mojo"
        g.parent.mkdir(exist_ok=True)
        g.write_text(base)
        res["new_path"].append(time_build(g, d / "b.so", includes, "shared-lib"))
        a_text = base + f"\n# A {time.time_ns()}\n"
        f.write_text(a_text)
        res["new_content"].append(time_build(f, d / "c.so", includes, "shared-lib"))
        f.write_text(base + f"\n# B {time.time_ns()}\n")
        time_build(f, d / "d.so", includes, "shared-lib")
        f.write_text(a_text)
        res["revert"].append(time_build(f, d / "e.so", includes, "shared-lib"))
        time.sleep(0.01)
        f.touch()
        res["touch"].append(time_build(f, d / "f.so", includes, "shared-lib"))
        speed = f"comptime SPEED: Float32 = {1000 + (time.time_ns() % 100000)}.0"
        f.write_text(a_text.replace("comptime SPEED: Float32 = 60.0", speed, 1))
        res["code_edit"].append(time_build(f, d / "g.so", includes, "shared-lib"))
    return {k: {"median": statistics.median(v), "min": min(v), "max": max(v), "n": len(v)} for k, v in res.items()}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sources", nargs="+")
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("-I", dest="includes", action="append", default=None)
    ap.add_argument("--emit", default="shared-lib", help="'' for an executable")
    ap.add_argument("--unique", action="store_true", help="distinct content per build")
    ap.add_argument("--probe-cache", action="store_true", help="what the compile cache is keyed on (1st source)")
    a = ap.parse_args()
    includes = a.includes or ["build", str(HERE)]
    if a.probe_cache:
        res = probe_cache(Path(a.sources[0]).resolve(), a.reps, includes)
        for k, r in res.items():
            print(f"{r['median']:6.2f} s median  min {r['min']:5.2f}  max {r['max']:5.2f}  n={r['n']}  {k}")
        print(json.dumps(res))
        return 0
    res = measure([Path(s).resolve() for s in a.sources], a.reps, includes, a.emit, a.unique)
    for k, r in res.items():
        print(f"{r['median']:6.2f} s median  min {r['min']:5.2f}  max {r['max']:5.2f}  n={r['n']}  {k}")
    print(json.dumps(res))
    return 0


if __name__ == "__main__":
    sys.exit(main())
