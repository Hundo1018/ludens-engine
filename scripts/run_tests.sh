#!/usr/bin/env bash
# Run test files against the precompiled packages, optionally filtered by
# tier (docs/design/17.0b-test-tiers.md; docs/ARCHITECTURE.md S3). Each
# test's Suite.finish() exits non-zero on failure, so `set -e` stops the
# run at the first failing file.
#
# Usage: run_tests.sh [tier ...]
#   no args          -- every tests/test_*.mojo file, alphabetical
#   tier [tier ...]  -- only files declaring one of the given tiers, one
#                        tier at a time IN THE ORDER GIVEN (so
#                        `run_tests.sh unit component` runs every unit
#                        file, alphabetical, then every component file)
#
# Every file's header is validated up front -- regardless of which tiers
# this invocation will actually run -- so a file with no/invalid
# `# tier: <tier>` first line fails the run instead of silently vanishing
# from a filtered subset.
#
# `-D ASSERT=all` turns on std `debug_assert` (off by default -- see
# `diag/invariant.mojo`), so the suite runs with every invariant live: a real
# bug behind a `debug_assert` fails loudly here instead of silently passing
# in a build that never checks it.
set -euo pipefail
cd "$(dirname "$0")/.."

VALID_TIERS="unit component integration system stress"

is_valid_tier() {
    case " $VALID_TIERS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# The declared tier word from a file's first line (override annotation, if
# any, is ignored), or empty if there is no `# tier: ...` first line at all.
tier_of() {
    local first
    first=$(head -n1 "$1")
    if [[ "$first" != "# tier: "* ]]; then
        return
    fi
    local rest="${first#\# tier: }"
    local tier
    read -r tier _ <<< "$rest"
    printf '%s' "$tier"
}

for t in "$@"; do
    if ! is_valid_tier "$t"; then
        echo "usage: run_tests.sh [unit|component|integration|system|stress ...]" >&2
        exit 1
    fi
done

declare -A TIER_OF
for t in tests/test_*.mojo; do
    tier=$(tier_of "$t")
    if [ -z "$tier" ] || ! is_valid_tier "$tier"; then
        echo "FAIL: $t has no valid '# tier: <tier>' first line (got: '${tier:-<none>}')" >&2
        exit 1
    fi
    TIER_OF["$t"]="$tier"
done

run_one() {
    echo "--- $1 ---"
    mojo run -D ASSERT=all -I build "$1"
}

if [ "$#" -eq 0 ]; then
    for t in tests/test_*.mojo; do
        run_one "$t"
    done
else
    for want in "$@"; do
        for t in tests/test_*.mojo; do
            if [ "${TIER_OF[$t]}" = "$want" ]; then
                run_one "$t"
            fi
        done
    done
fi
echo "all tests passed"
