#!/usr/bin/env python3
"""Hot-reload dev server: watch -> rebuild -> push to the browser.

  * serves the repo root over HTTP (so bindings/js and build/ resolve)
  * polls the engine source (and the stand-in core it links) for changes
  * rebuilds through scripts/emit-and-link.sh into build/hot/dev/<n>/
  * pushes each build result over Server-Sent Events at /__hot/events
  * GET /__hot/latest returns the latest successful build as JSON

A failed build is pushed as {"ok": false, "error": ...}; the page keeps
running the previous module.

    python3 experiments/hot_reload/wasm/dev_server.py [--port 8080] [--source FILE]
    open http://localhost:8080/experiments/hot_reload/wasm/
"""
from __future__ import annotations

import argparse
import json
import queue
import subprocess
import sys
import threading
import time
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run import CORE, ROOT, SOURCE, build_one  # noqa: E402


class Builds:
    """Latest build + fan-out of build events to connected SSE clients."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.latest: dict | None = None
        self.clients: list[queue.Queue] = []

    def publish(self, event: dict) -> None:
        with self.lock:
            if event["ok"]:
                self.latest = event
            for q in self.clients:
                q.put(event)

    def subscribe(self) -> queue.Queue:
        q: queue.Queue = queue.Queue()
        with self.lock:
            self.clients.append(q)
        return q

    def unsubscribe(self, q: queue.Queue) -> None:
        with self.lock:
            self.clients.remove(q)


def rebuild(builds: Builds, version: int, source: Path, out_dir: Path, cflags: list[str]) -> None:
    wasm = out_dir / str(version) / "engine_hot.wasm"
    t0 = time.perf_counter()
    try:
        layout = build_one(wasm, cflags, str(source))
    except subprocess.CalledProcessError as err:
        builds.publish({"ok": False, "version": version, "error": f"build failed (exit {err.returncode})"})
        return
    builds.publish({
        "ok": True,
        "version": version,
        "wasm": "/" + str(wasm.relative_to(ROOT)),
        "mapFingerprint": layout["mapFingerprint"],
        "buildMs": round((time.perf_counter() - t0) * 1000, 1),
    })


def watch(builds: Builds, paths: list[Path], source: Path, out_dir: Path, cflags: list[str],
          interval: float) -> None:
    def snapshot() -> dict:
        return {p: p.stat().st_mtime_ns for p in paths if p.exists()}

    seen = snapshot()
    version = 1
    rebuild(builds, version, source, out_dir, cflags)
    while True:
        time.sleep(interval)
        now = snapshot()
        if now != seen:
            seen = now
            version += 1
            rebuild(builds, version, source, out_dir, cflags)


class Handler(SimpleHTTPRequestHandler):
    builds: Builds

    def log_message(self, fmt, *args):  # keep the console for build output
        pass

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_GET(self):
        if self.path == "/__hot/latest":
            body = json.dumps(self.builds.latest).encode()
            self.send_response(200 if self.builds.latest else 503)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/__hot/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            q = self.builds.subscribe()
            try:
                while True:
                    try:
                        event = q.get(timeout=15)
                        self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
                    except queue.Empty:
                        self.wfile.write(b": keep-alive\n\n")
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                self.builds.unsubscribe(q)
            return
        super().do_GET()


Handler.extensions_map = {**SimpleHTTPRequestHandler.extensions_map,
                          ".wasm": "application/wasm", ".mjs": "text/javascript"}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--source", default=str(ROOT / SOURCE), help="engine source to watch and build")
    ap.add_argument("--out", default=str(ROOT / "build" / "hot" / "dev"))
    ap.add_argument("--cflags", default="", help="extra clang flags for every build")
    ap.add_argument("--interval", type=float, default=0.2, help="poll interval, seconds")
    a = ap.parse_args()

    source = Path(a.source).resolve()
    watched = [source] + [ROOT / c for c in CORE]
    builds = Builds()
    threading.Thread(target=watch, daemon=True,
                     args=(builds, watched, source, Path(a.out).resolve(), a.cflags.split(), a.interval)).start()

    Handler.builds = builds
    server = ThreadingHTTPServer(("127.0.0.1", a.port), partial(Handler, directory=str(ROOT)))
    server.daemon_threads = True
    print(f"hot-reload dev server: http://127.0.0.1:{a.port}/experiments/hot_reload/wasm/  (watching {source})",
          flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
