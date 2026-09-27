#!/usr/bin/env bash
# Run every test file against the precompiled packages. Each test's Suite.finish()
# exits non-zero on failure, so `set -e` stops the run at the first failing file.
#
# `-D ASSERT=all` turns on std `debug_assert` (off by default -- see
# `diag/assert.mojo`), so the suite runs with every invariant live: a real bug
# behind a `debug_assert` fails loudly here instead of silently passing in a
# build that never checks it.
set -euo pipefail
cd "$(dirname "$0")/.."
for t in tests/test_*.mojo; do
    echo "--- $t ---"
    mojo run -D ASSERT=all -I build "$t"
done
echo "all tests passed"
