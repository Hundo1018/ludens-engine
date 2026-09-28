#!/usr/bin/env bash
# Wrapper for the architecture index + gate (tools/archindex.mojo).
#
# Rebuilds build/archindex only when the source is newer than the binary
# (so `pixi run arch -- <cmd>` is instant on repeat calls), then execs the
# binary with all given arguments. The binary manages its own data cache
# (build/archindex.json) separately, rebuilding it only when a *.mojo file
# under a scanned package is newer than that JSON -- see tools/archindex.mojo.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -x build/archindex ] || [ tools/archindex.mojo -nt build/archindex ]; then
    mkdir -p build
    if command -v mojo >/dev/null; then mojo build tools/archindex.mojo -o build/archindex; else pixi run mojo build tools/archindex.mojo -o build/archindex; fi
fi

exec build/archindex "$@"
