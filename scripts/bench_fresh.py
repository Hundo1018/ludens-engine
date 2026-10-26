"""Check that BENCHMARK_REPORT.md is in sync with the benchmark programs.

Two checks, both git-based and read-only:
  1. every benchmarks/bench_*.mojo has an `@bench` line in
     scripts/benchmark_report.md.in (otherwise it never reaches the report);
  2. no bench program's last commit is newer than the report's last commit
     (a bench changed after the report was regenerated).

Exit 0 when fresh, 1 with the offending files otherwise. Usage:
    python3 scripts/bench_fresh.py
"""
import glob
import subprocess
import sys

TEMPLATE = "scripts/benchmark_report.md.in"
REPORT = "BENCHMARK_REPORT.md"


def last_commit_time(path: str) -> int:
    out = subprocess.run(
        ["git", "log", "-1", "--format=%ct", "--", path],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return int(out) if out else 0


def main() -> int:
    benches = sorted(glob.glob("benchmarks/bench_*.mojo"))
    template = open(TEMPLATE, encoding="utf-8").read()
    registered = {line.split(maxsplit=1)[1].strip() for line in template.splitlines()
                  if line.startswith("@bench ")}
    problems = []
    for b in benches:
        if b not in registered:
            problems.append(f"not registered in {TEMPLATE}: {b}")
    report_time = last_commit_time(REPORT)
    for b in benches:
        if last_commit_time(b) > report_time:
            problems.append(f"changed after the report was regenerated: {b}")
    if problems:
        print(f"bench-fresh: {len(problems)} problem(s)")
        for p in problems:
            print("  " + p)
        return 1
    print(f"bench-fresh: {len(benches)} benches, all registered and no newer than {REPORT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
