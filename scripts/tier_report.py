#!/usr/bin/env python3
"""Run every test file of the given tiers on its own and report each result,
instead of stopping at the first failure as scripts/run_tests.sh does.

For checking an environment (T1: does the pip-installed toolchain run the
dev suite?), where some files are expected to fail for reasons outside the
code, e.g. no GPU.

    python3 scripts/tier_report.py unit [component ...] [--timeout 600] [--jobs 2]

Each file runs as run_tests.sh runs it: `mojo run -D ASSERT=all -I build <file>`.
Prints one line per file (PASS / FAIL / TIMEOUT, seconds, first error line)
and writes build/tier_report.json.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TIERS = ("unit", "component", "integration", "system", "stress")


def mojo() -> str:
    for cand in (os.environ.get("MOJO"), shutil.which("mojo"), str(ROOT / ".venv" / "bin" / "mojo")):
        if cand and Path(cand).exists():
            return cand
    sys.exit("mojo not found")


def tier_of(path: Path) -> str | None:
    first = path.read_text().split("\n", 1)[0]
    return first[len("# tier: "):].split()[0] if first.startswith("# tier: ") else None


def first_error(text: str) -> str:
    for line in text.splitlines():
        if "error:" in line or "FAIL" in line or "Error" in line or "ABORT" in line:
            return line.strip()[:240]
    return text.strip().splitlines()[-1][:240] if text.strip() else ""


def run(path: Path, timeout: int) -> dict:
    t0 = time.perf_counter()
    try:
        p = subprocess.run([mojo(), "run", "-D", "ASSERT=all", "-I", "build", str(path)], cwd=ROOT,
                           capture_output=True, text=True, timeout=timeout)
        status = "PASS" if p.returncode == 0 else "FAIL"
        err = "" if status == "PASS" else first_error(p.stderr + "\n" + p.stdout)
        rc = p.returncode
    except subprocess.TimeoutExpired:
        status, err, rc = "TIMEOUT", f"> {timeout} s", None
    return {"file": str(path.relative_to(ROOT)), "tier": tier_of(path), "status": status, "rc": rc,
            "seconds": round(time.perf_counter() - t0, 1), "error": err}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tiers", nargs="+", choices=TIERS)
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--jobs", type=int, default=2)
    a = ap.parse_args()
    files = [f for t in a.tiers for f in sorted((ROOT / "tests").glob("test_*.mojo")) if tier_of(f) == t]
    rows = []
    with ThreadPoolExecutor(a.jobs) as ex:
        for r in ex.map(lambda f: run(f, a.timeout), files):
            rows.append(r)
            print(f"{r['status']:<8}{r['seconds']:>7}s  {r['file']}  {r['error']}", flush=True)
    counts = {s: sum(r["status"] == s for r in rows) for s in ("PASS", "FAIL", "TIMEOUT")}
    print(f"{len(rows)} files: {counts}")
    (ROOT / "build").mkdir(exist_ok=True)
    (ROOT / "build" / "tier_report.json").write_text(json.dumps({"tiers": a.tiers, "counts": counts, "rows": rows},
                                                                indent=2))
    return 0 if counts["FAIL"] == counts["TIMEOUT"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
