"""Selftest fixture for scripts/fuzz.py: fails exactly when seed % 7 == 3."""

from harness.runner import Suite, fuzz_seed


def main() raises:
    var s = Suite("fuzz_fixture")
    var seed = fuzz_seed(1)
    s.check(seed % 7 != 3, "planted failure at seed % 7 == 3")
    s.finish()
