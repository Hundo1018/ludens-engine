#!/usr/bin/env bash
# Rebuild build/golden only when tools/golden.mojo is newer, then run it.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -x build/golden ] || [ tools/golden.mojo -nt build/golden ]; then
  mkdir -p build
  if command -v mojo >/dev/null; then mojo build -o build/golden tools/golden.mojo; else pixi run mojo build -o build/golden tools/golden.mojo; fi
fi
exec build/golden "$@"
