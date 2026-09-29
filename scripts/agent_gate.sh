#!/usr/bin/env bash
# The one gate command for agents and humans. Runs the whole suite in the
# FOREGROUND (a backgrounded run that gets killed leaves an agent waiting
# forever), then prints a fixed-format summary computed by the tested
# tools/golden.mojo instead of an ad-hoc grep, and compares against the
# golden output file section by file section.
#
#   scripts/agent_gate.sh                  gate: suite + summary + golden compare
#   scripts/agent_gate.sh --update-golden  gate, then record this run as golden
#   scripts/agent_gate.sh --selftest       test the gate's own tools first
set -uo pipefail
cd "$(dirname "$0")/.."
GOLDEN=tests/golden/test_stdout.txt
LOG=build/agent_gate.log
mkdir -p build

if [ "${1:-}" = "--selftest" ]; then
  bash scripts/golden.sh selftest && bash scripts/arch.sh selftest
  exit $?
fi

timeout 1800 pixi run test > "$LOG" 2>&1
rc=$?
[ $rc -eq 124 ] && echo "SUITE  TIMEOUT after 1800 s (log: $LOG)"
bash scripts/golden.sh summary "$LOG"; srow=$?
if [ "${1:-}" = "--update-golden" ] && [ $rc -eq 0 ] && [ $srow -eq 0 ]; then
  bash scripts/golden.sh normalize "$LOG" > "$GOLDEN"
  echo "GOLDEN updated ($(wc -l < "$GOLDEN") lines)"; grow=0
else
  bash scripts/golden.sh compare "$GOLDEN" "$LOG"; grow=$?
fi
if [ $rc -eq 0 ] && [ $srow -eq 0 ] && [ $grow -eq 0 ]; then
  echo "GATE   PASS  (log: $LOG)"; exit 0
fi
echo "GATE   FAIL  (suite exit $rc; log: $LOG)"; exit 1
