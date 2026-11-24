#!/usr/bin/env python3
"""Compare two builds of the native frame runner (app/frame_budget.mojo) run alternately (#123).

    pixi run -e wasm python3 scripts/frame_ab.py BASELINE_EXE CANDIDATE_EXE [--runs 10] [--size 1280x720] [--frames 600]

Both executables take `<width> <height> <frames>` and print `seg <name> ...` lines in either layout (the old one with
`p50 .. p95 .. max .. count`, the new one with `avg .. p50 .. p95 .. p99 .. max .. count`). The runs alternate (A, B, A, B, ...)
so a change in the machine's load hits both. Prints, per segment, the median over runs of p50 and p95 in ms and the
min .. max of the p95: a difference smaller than that range is noise."""
import argparse
import os
import re
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import native_libs  # noqa: E402

ROW = re.compile(r"^seg (\w+) (?:avg \d+ )?p50 (\d+) p95 (\d+) (?:p99 \d+ )?max (\d+) count (\d+)$", re.M)


def run(exe: Path, w: int, h: int, frames: int) -> dict[str, tuple[int, int]]:
    env = {**native_libs.native_env(), **{k: v for k, v in os.environ.items() if k in ("VK_ICD_FILENAMES", "LIBGL_ALWAYS_SOFTWARE", "WGPU_BACKEND")}}
    out = subprocess.run([str(exe), str(w), str(h), str(frames)], env=env, capture_output=True, text=True, check=True).stdout
    return {n: (int(p50), int(p95)) for n, p50, p95, _mx, c in ROW.findall(out) if int(c) > 0}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("baseline", type=Path)
    ap.add_argument("candidate", type=Path)
    ap.add_argument("--runs", type=int, default=10)
    ap.add_argument("--size", default="1280x720")
    ap.add_argument("--frames", type=int, default=600)
    a = ap.parse_args()
    w, h = (int(x) for x in a.size.split("x"))
    res: dict[str, list[dict[str, tuple[int, int]]]] = {"A": [], "B": []}
    for _ in range(a.runs):
        res["A"].append(run(a.baseline, w, h, a.frames))
        res["B"].append(run(a.candidate, w, h, a.frames))
    print(f"{a.runs} alternating runs, {w}x{h}, {a.frames} frames; ms, median over runs (p95 also min..max)\n")
    print("| segment | baseline p50 | candidate p50 | baseline p95 (min..max) | candidate p95 (min..max) |\n|---|---:|---:|---|---|")
    for seg in ("step", "scene", "push", "hud", "draw", "frame"):
        cells = []
        for k in ("A", "B"):
            p50 = statistics.median(r[seg][0] for r in res[k]) / 1e6
            p95s = [r[seg][1] / 1e6 for r in res[k]]
            cells.append((p50, statistics.median(p95s), min(p95s), max(p95s)))
        print(f"| {seg} | {cells[0][0]:.3f} | {cells[1][0]:.3f} | {cells[0][1]:.3f} ({cells[0][2]:.3f}..{cells[0][3]:.3f}) | {cells[1][1]:.3f} ({cells[1][2]:.3f}..{cells[1][3]:.3f}) |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
