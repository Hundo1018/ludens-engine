"""Selftest fixture for scripts/stability.py: same output every run, plus a
timing line the golden normaliser drops."""

from std.time import perf_counter_ns


def main():
    print("  value 42")
    print("  step", Int(perf_counter_ns() % 1000), "ms")
