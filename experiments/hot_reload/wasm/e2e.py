#!/usr/bin/env python3
"""End-to-end run of the browser hot-reload loop.

Copies engine_hot.c to build/hot/e2e/src/ (the test edits the copy, never the
tracked file), starts dev_server.py on a free port watching that copy, and runs
e2e_browser.mjs in headless Chromium against it.

    python3 experiments/hot_reload/wasm/e2e.py
"""
from __future__ import annotations

import shutil
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = ROOT / "build" / "hot" / "e2e"


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_ready(url: str, timeout: float = 60.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=2) as r:
                if r.status == 200:
                    return
        except OSError:
            pass
        time.sleep(0.2)
    raise TimeoutError(f"dev server not ready: {url}")


def main() -> int:
    if OUT.exists():
        shutil.rmtree(OUT)
    src = OUT / "src" / "engine_hot.c"
    src.parent.mkdir(parents=True)
    shutil.copy(HERE / "engine_hot.c", src)

    port = free_port()
    server = subprocess.Popen(
        [sys.executable, str(HERE / "dev_server.py"), "--port", str(port),
         "--source", str(src), "--out", str(OUT / "builds")],
        cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_ready(f"http://127.0.0.1:{port}/__hot/latest")
        url = f"http://127.0.0.1:{port}/experiments/hot_reload/wasm/"
        return subprocess.run(["node", str(HERE / "e2e_browser.mjs"), url, str(src), str(OUT)],
                              cwd=ROOT).returncode
    finally:
        server.terminate()
        server.wait(timeout=10)


if __name__ == "__main__":
    sys.exit(main())
