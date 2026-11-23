#!/usr/bin/env python3
"""`window.game` in a real page (ludens-engine #115): headless Chrome opens the built site with `?manual&offscreen&seed=3&scene=arena`.

    pixi run -e wasm python3 scripts/hook_web_check.py        # builds build/app.wasm and build/web first

Checks, against the same job run under node (scripts/game_run.mjs):
  - ?manual: the animation loop does not run (the tick stays 0 for 1 s), frames come only from step();
  - ?seed= and ?scene= start the game with that seed and scene (state().seed, state().scene);
  - 300 undrawn steps with W held give the node run's hash, and 10 more steps with drawing do too (offscreen: nothing is
    drawn to the canvas, but the game steps through app_frame);
  - the page is a wasm64 module in a browser, so this compares browser against node, not against the native build."""
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import divergence  # noqa: E402

EXPR = """(async () => {
  const g = window.game;
  const first = g.state();
  await new Promise((r) => setTimeout(r, 1000));
  const idle = g.state().tick;
  g.hold("KeyW");
  g.step(300, false);
  const undrawn = { hash: g.hash(), state: g.state() };
  g.step(10, true);
  return { first, idle, undrawn, drawnHash: g.hash(), drawnTick: g.state().tick, events: g.events() };
})()"""


def main() -> int:
    chrome = shutil.which("google-chrome") or shutil.which("chromium")
    if not chrome:
        sys.exit("hook_web_check: no Chrome found")
    subprocess.run(["bash", "scripts/build_wasm.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    subprocess.run([sys.executable, "scripts/build_web.py"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    server = subprocess.Popen([sys.executable, "shell/web/serve.py", "8141", "build/web"], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(2)
        with tempfile.TemporaryDirectory() as t:
            expr = Path(t) / "expr.js"
            expr.write_text(EXPR)
            r = subprocess.run(["node", "scripts/hook_web.mjs", chrome, "http://127.0.0.1:8141/index.html?manual&offscreen&seed=3&scene=arena", str(expr)],
                               cwd=ROOT, capture_output=True, text=True, check=False)
    finally:
        server.kill()
    if r.returncode:
        sys.exit(r.stdout + r.stderr)
    page = json.loads(r.stdout.strip().splitlines()[-1])
    node = divergence.run_trace({"ticks": 310, "seed": 3, "scene": "arena", "script": [{"tick": 0, "hold": "KeyW"}]})
    checks = {
        "?seed=3&scene=arena reached the game": page["first"]["seed"] == "3" and page["first"]["scene"] == "arena" and page["first"]["tick"] == 0,
        "?manual: no frame ran in 1 s": page["idle"] == 0,
        "300 undrawn steps: the page's hash is node's": page["undrawn"]["hash"] == node[300]["hash"] and page["undrawn"]["state"] == node[300]["state"],
        "10 drawn steps more: the page's hash is node's": page["drawnTick"] == 310 and page["drawnHash"] == node[310]["hash"],
    }
    for label, ok in checks.items():
        print("  [PASS]" if ok else "  [FAIL]", label)
    print("first:", json.dumps(page["first"])[:300], "idle:", page["idle"])
    print(f"page hash {page['drawnHash']}  node hash {node[310]['hash']}")
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
