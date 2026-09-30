#!/usr/bin/env bash
# Compile-and-run every language spike in tests/_spikes.
#
# Spikes are throwaway probes that proved a Mojo mechanism before the real code
# depended on it (type packs, trait swaps, erased pointer slots, parallel world
# writes). They are kept because they are the cheapest reproduction of each
# mechanism when the toolchain moves under us -- but that only works if they
# still build, so they get a task of their own rather than being maintained by
# hand and discovered broken during the next migration.
set -euo pipefail
cd "$(dirname "$0")/.."
for s in tests/_spikes/spike_*.mojo; do
    echo "--- $s ---"
    mojo run -I build "$s"
done
echo "all spikes ran"
