#!/usr/bin/env python3
"""The live tuning panel in the web shell, in headless Chrome on a software WebGPU adapter (ludens-engine #119).

    pixi run -e wasm tuning-web

Builds the web bundle, serves it, and runs scripts/tuning_shot.mjs: F2 opens the panel, a pointer drag moves the speed
slider, Export downloads the table. Frames go to build/shots/tuning_*.png."""
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    chrome = shutil.which("google-chrome") or shutil.which("chromium")
    if not chrome:
        sys.exit("tuning_web: no Chrome found")
    subprocess.run(["bash", "scripts/build_wasm.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    subprocess.run([sys.executable, "scripts/build_web.py"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    out = ROOT / "build/shots"
    out.mkdir(parents=True, exist_ok=True)
    server = subprocess.Popen([sys.executable, "shell/web/serve.py", "8141", "build/web"], cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(2)
        r = subprocess.run(["node", "scripts/tuning_shot.mjs", chrome, "http://127.0.0.1:8141/index.html?offscreen", str(out / "tuning"), "150"], cwd=ROOT, check=False)
    finally:
        server.kill()
    return r.returncode


if __name__ == "__main__":
    sys.exit(main())
