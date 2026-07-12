#!/usr/bin/env bash
# Run every research experiment against the precompiled packages. Experiments
# are standalone programs (like tests/examples): feasibility probes for the GA
# research track — CGA meet, GA autodiff, discrete exterior calculus, Clifford
# neural physics. See docs/CATEGORY.md for how they relate to the engine seams.
set -euo pipefail
cd "$(dirname "$0")/.."
for e in experiments/exp_*.mojo; do
    echo "--- $e ---"
    mojo run -I build "$e"
done
echo "all experiments ran"
