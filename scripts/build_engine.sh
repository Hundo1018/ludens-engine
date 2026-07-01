#!/usr/bin/env bash
# Precompile every ludens-engine package into build/*.mojoc, in dependency order.
# This nightly only resolves cross-file imports through precompiled .mojoc on the
# -I path (source dirs are not searched), so packages must be built before tests.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

mojo precompile harness   -o build/harness.mojoc
mojo precompile geometry  -o build/geometry.mojoc
mojo precompile spatial   -I build -o build/spatial.mojoc
mojo precompile ecs       -I build -o build/ecs.mojoc
mojo precompile scheduler -I build -o build/scheduler.mojoc
mojo precompile collision -I build -o build/collision.mojoc
mojo precompile physics   -I build -o build/physics.mojoc
mojo precompile oop       -I build -o build/oop.mojoc

echo "build: all packages precompiled into build/"
