"""Uncached `mojo build --mlir-timing` on one source, n times.

Reports wall time per run and wall time summed by top-level pass name
(averaged over runs). Usage: python3 experiments/upstream_probes/pass_cost.py <mojo> <source.mojo> [n]
"""
import collections
import re
import subprocess
import sys
import tempfile
import time

LINE = re.compile(r"^\s+[\d.]+ \(\s*[\d.]+%\)\s+([\d.]+) \(\s*[\d.]+%\)  (\S.*)$")

def one(mojo, src):
    with tempfile.TemporaryDirectory() as cache, tempfile.TemporaryDirectory() as out:
        t0 = time.perf_counter()
        r = subprocess.run([mojo, "build", "--mlir-timing", src, "-o", out + "/a"],
                           capture_output=True, text=True, env={"MODULAR_CACHE_DIR": cache, "PATH": "/usr/bin:/bin"})
        wall = time.perf_counter() - t0
    if r.returncode != 0:
        sys.exit(r.stderr[-2000:])
    per = collections.Counter()
    total = 0.0
    for line in r.stderr.splitlines():
        m = LINE.match(line)
        if m and m.group(2).strip() == "Total":
            total = float(m.group(1))
        elif m and not line.startswith("    " * 2 + " "):  # keep top-level rows
            name = m.group(2).strip()
            if not name.startswith("(A)"):
                per[name] += float(m.group(1))
    return wall, total, per

def main():
    mojo, src = sys.argv[1], sys.argv[2]
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    walls, totals, agg = [], [], collections.Counter()
    for _ in range(n):
        w, t, per = one(mojo, src)
        walls.append(w); totals.append(t); agg.update(per)
    print(f"source={src} n={n}")
    print("wall_s=", [round(w, 2) for w in walls], "mlir_total_s=", [round(t, 2) for t in totals])
    for name, s in agg.most_common(12):
        print(f"  {s / n:7.3f} s  {name}")

if __name__ == "__main__":
    main()
