#!/bin/bash
# Run build/web/index.html?selftest in headless Firefox (every check) and Chrome (all but the pixel check:
# headless Chrome destroys the GPUDevice after a canvas draw). Each browser is skipped if not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${PORT:-8123}"
python3 shell/web/serve.py "$PORT" build/web > /dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$PORT/index.html" > /dev/null && break; sleep 0.1; done
URL="http://127.0.0.1:$PORT/index.html?selftest=parity"
ran=0 failed=0
GECKO="${GECKODRIVER:-$(command -v geckodriver || true)}"
if [ -n "$GECKO" ] && command -v firefox > /dev/null; then ran=1; echo "== firefox"; node scripts/web_firefox.mjs "$GECKO" "$URL" 120 || failed=1; fi
CHROME="${CHROME:-$(command -v google-chrome || command -v chromium || true)}"
if [ -n "$CHROME" ]; then ran=1; echo "== chrome"; node scripts/web_cdp.mjs "$CHROME" "http://127.0.0.1:$PORT/index.html?selftest=parity-offscreen" 120 || failed=1; fi
[ "$ran" = 1 ] || { echo "test-web: neither Firefox (geckodriver) nor Chrome found" >&2; exit 1; }
exit "$failed"
