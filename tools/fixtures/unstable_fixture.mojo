"""Selftest fixture for scripts/stability.py: prints a different number every
run, on a line that is not a timing line."""

from std.time import perf_counter_ns


def main():
    print("  value", Int(perf_counter_ns() % 1000003))
