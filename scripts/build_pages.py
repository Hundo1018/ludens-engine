#!/usr/bin/env python3
"""Build the arena game as a static site for GitHub Pages: build/pages.

`ludens build --target web`, then a copy of build/web without the files only the self-tests read, plus `.nojekyll`
(Pages must serve every file as it is) and `build.txt` (the commit). The site needs no server-side headers: without
COOP/COEP the page posts audio blocks to the worklet instead of sharing a buffer with it (shell/web/app.ts).

Run: pixi run -e wasm build-pages [--check]
  --check   also serve build/pages the way Pages does (no COOP/COEP) and play it in headless Chrome on a software
            WebGPU adapter: frames, reaction to keys, and sound through the posted-block path must all work;
            then again by touch only on an emulated phone, through the virtual pad."""
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WEB = ROOT / "build/web"
OUT = ROOT / "build/pages"
TEST_ONLY = {"pixels_native.rgba", "pixel_tolerance.json", "MANIFEST.sha256"}
PORT = 8141


def build() -> None:
    subprocess.run([sys.executable, "scripts/ludens.py", "build", "--target", "web"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    for f in sorted(WEB.iterdir()):
        if f.name not in TEST_ONLY:
            shutil.copy(f, OUT / f.name)
    (OUT / ".nojekyll").write_text("")
    rev = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    (OUT / "build.txt").write_text(f"ludens-engine {rev}\n")
    files = sorted(p for p in OUT.iterdir() if p.is_file())
    print(f"build-pages: {len(files)} files, {sum(p.stat().st_size for p in files)} bytes in {OUT}")


def check() -> int:
    chrome = shutil.which("google-chrome") or shutil.which("chromium")
    if not chrome:
        sys.exit("build-pages --check: no Chrome found")
    shots = ROOT / "build/shots"
    shots.mkdir(parents=True, exist_ok=True)
    server = subprocess.Popen([sys.executable, "shell/web/serve.py", str(PORT), str(OUT), "plain"], cwd=ROOT,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(2)
        base = f"http://127.0.0.1:{PORT}/index.html?offscreen"
        r = subprocess.run(["node", "scripts/game_screenshot.mjs", chrome, base, str(shots / "pages"), "150", "posted"], cwd=ROOT)
        # the same site played by touch only, on an emulated phone (scripts/touch_check.mjs)
        t = subprocess.run(["node", "scripts/touch_check.mjs", chrome, base, str(shots / "touch"), "150"], cwd=ROOT)
    finally:
        server.kill()
    return r.returncode or t.returncode


def main(argv: list[str]) -> int:
    build()
    return check() if "--check" in argv else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
