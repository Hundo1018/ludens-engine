#!/usr/bin/env python3
"""The frame-time overlay (F3) and the frame counters in the web shell, in headless Chrome on a software WebGPU adapter (#123).

    pixi run -e wasm perf-overlay-web

Builds the web bundle, serves it, and runs scripts/perf_overlay_shot.mjs: F3 draws the overlay and F3 again hides it;
`app_frame_stats` after 300 frames reports the demo scene's counters and no GPU rows. Frames go to build/shots/perf_*.rgba."""
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    chrome = shutil.which("google-chrome") or shutil.which("chromium")
    if not chrome:
        sys.exit("perf_overlay_web: no Chrome found")
    subprocess.run(["bash", "scripts/build_wasm.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    subprocess.run([sys.executable, "scripts/build_web.py"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    out = ROOT / "build/shots"
    out.mkdir(parents=True, exist_ok=True)
    server = subprocess.Popen([sys.executable, "shell/web/serve.py", "8142", "build/web"], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(2)
        r = subprocess.run(["node", "scripts/perf_overlay_shot.mjs", chrome, "http://127.0.0.1:8142/index.html?offscreen", str(out / "perf"), "240"], cwd=ROOT, check=False)
    finally:
        server.kill()
    return r.returncode


if __name__ == "__main__":
    sys.exit(main())
