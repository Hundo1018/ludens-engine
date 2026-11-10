#!/usr/bin/env python3
"""Play the arena game in headless Chrome (SwiftShader WebGPU, no GPU needed) and save PNG frames to build/shots/.

Builds the web bundle, serves it, drives the keyboard (hold W+D, then pause) through scripts/game_screenshot.mjs.
Run: pixi run -e wasm game-shot"""
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    chrome = shutil.which("google-chrome") or shutil.which("chromium")
    if not chrome:
        sys.exit("game_shot: no Chrome found")
    subprocess.run(["bash", "scripts/build_wasm.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    subprocess.run([sys.executable, "scripts/build_web.py"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    out = ROOT / "build/shots"
    out.mkdir(parents=True, exist_ok=True)
    server = subprocess.Popen([sys.executable, "shell/web/serve.py", "8139", "build/web"], cwd=ROOT,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(2)
        r = subprocess.run(["node", "scripts/game_screenshot.mjs", chrome, "http://127.0.0.1:8139/index.html?offscreen",
                            str(out / "game"), "150"], cwd=ROOT)
    finally:
        server.kill()
    print("frames in", out)
    return r.returncode


if __name__ == "__main__":
    sys.exit(main())
