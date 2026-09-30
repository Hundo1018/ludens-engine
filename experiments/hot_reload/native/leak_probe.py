#!/usr/bin/env python3
"""R1 B2 follow-up: is the RSS growth of 1000 snapshot swaps a leak?

B2 (predictions_r1.py) predicted < 256 KiB of VmRSS growth over swaps
100..1000; snapshot measured +496 KiB (close: +8 KiB). Mojo allocates through
TCMalloc, which keeps freed memory, so VmRSS cannot tell a leak from retained
memory. This runs the B2 host under probes/kgen_alloc_count.c (an LD_PRELOAD
shim over KGEN_CompilerRT_AlignedAlloc/Free) for K = 100 and K = 1000 swaps
and compares the Mojo allocations still live at process exit.

Prediction, written before the first run of this script: live_count and
live_bytes at exit do not depend on K (no leak); the RSS growth is memory
TCMalloc retains, because every swap's snapshot buffer and trail are a few
bytes larger than the previous one's (the trail grows by one entry per frame).

Decision rule: leak per swap = (live_bytes(K=1000) - live_bytes(K=100)) / 900.
Above 0 bytes is a leak; its size is reported.

    python3 experiments/hot_reload/native/leak_probe.py
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_native import HERE, OUT, ROOT  # noqa: E402

SHIM_SRC = HERE / "probes" / "kgen_alloc_count.c"
SHIM = OUT / "kgen_alloc_count.so"


def build_shim() -> None:
    subprocess.run(["cc", "-O2", "-shared", "-fPIC", "-o", str(SHIM), str(SHIM_SRC), "-ldl"], check=True)


def run(strategy: str, k: int) -> dict:
    cell = OUT / "leak" / f"{strategy}-{k}"
    if cell.exists():
        shutil.rmtree(cell)
    cell.mkdir(parents=True)
    a, b = cell / "old.so", cell / "new.so"
    shutil.copy(OUT / "v1" / "libengine.so", a)
    shutil.copy(OUT / "v2_code" / "libengine.so", b)
    p = subprocess.run([str(OUT / "host"), str(a), str(b), strategy, "repeat", str(k)], cwd=ROOT,
                       capture_output=True, text=True, timeout=600,
                       env={"LD_PRELOAD": str(SHIM), "PATH": "/usr/bin:/bin"})
    kv = dict(line.split("=", 1) for line in p.stdout.splitlines() if "=" in line)
    m = re.search(r"kgen_alloc live_count=(-?\d+) live_bytes=(-?\d+) allocs=(\d+) frees=(\d+)", p.stderr)
    if p.returncode != 0 or not m:
        raise SystemExit(f"{strategy} K={k}: rc={p.returncode}\n{p.stderr[-2000:]}")
    return {"strategy": strategy, "k": k, "live_count": int(m[1]), "live_bytes": int(m[2]),
            "allocs": int(m[3]), "frees": int(m[4]), "rss_first": kv.get("rss_first"),
            "rss_100": kv.get("rss_100"), "rss_last": kv.get("rss_last")}


def main() -> int:
    build_shim()
    rows = [run(s, k) for s in ("close", "snapshot") for k in (100, 1000)]
    for r in rows:
        print(f"{r['strategy']:<9} K={r['k']:<5} live_count={r['live_count']:<5} live_bytes={r['live_bytes']:<7} "
              f"allocs={r['allocs']:<7} frees={r['frees']:<7} rss {r['rss_first']} -> {r['rss_100']} -> {r['rss_last']} KiB")
    verdict = {}
    for s in ("close", "snapshot"):
        short, long_ = (next(r for r in rows if r["strategy"] == s and r["k"] == k) for k in (100, 1000))
        per_swap = (long_["live_bytes"] - short["live_bytes"]) / 900
        verdict[s] = per_swap
        print(f"{s:<9} leak per swap: {per_swap:.1f} bytes ({'leak' if per_swap > 0 else 'no leak'})")
    (OUT / "leak_probe.json").write_text(json.dumps({"rows": rows, "leak_bytes_per_swap": verdict}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
