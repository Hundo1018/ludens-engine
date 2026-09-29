#!/usr/bin/env bash
# Run every benchmark program against the precompiled packages and assemble
# BENCHMARK_REPORT.md. Bench files are plain programs (no bench CLI on this
# toolchain), run with `mojo run -I build`.
#
# The report's PROSE lives in `scripts/benchmark_report.md.in`, not in this
# script. The template is copied through verbatim except for lines of the form
#
#     @bench benchmarks/bench_foo.mojo
#
# which are replaced by that program's stdout. Keeping the prose in a markdown
# file means it can be reviewed as markdown and edited without shell escaping;
# this script stays responsible only for running things.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=BENCHMARK_REPORT.md
TEMPLATE=scripts/benchmark_report.md.in

# The bench_ga teardown crash was ROOT-CAUSED on 2026-07-13: bare width-3 SIMD
# lists (List[Vec3]) captured across separate closures in one program crashed
# the runtime at teardown (libAsyncRT). Width 3 was never a supported SIMD
# width; Vec3 is four lanes now and the wrapper that mitigated it is gone.
# The separate GPU hang (multiple DeviceContexts per process) was fixed the
# same day via shared-context drivers (*_run_ctx). This retry is now just a
# thin SAFETY NET against residual teardown flakiness, not a known-bug workaround.
run_bench() {
    # stdout goes to a temp FILE, not the report pipe, so a crashed attempt
    # never leaves partial output in the report.
    local tmp
    tmp=$(mktemp)
    for _ in 1 2; do
        if mojo run -I build "$1" > "$tmp" 2>/dev/null; then
            cat "$tmp"
            rm -f "$tmp"
            return 0
        fi
        echo "(retrying $1 after a teardown crash)" >&2
    done
    rm -f "$tmp"
    echo "ERROR: $1 kept crashing" >&2
    return 1
}

render() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "@bench "*) run_bench "${line#@bench }" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$TEMPLATE"
}

render | tee "$OUT"

echo "benchmark: wrote $OUT"
