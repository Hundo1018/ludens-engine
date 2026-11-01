#!/usr/bin/env python3
"""Static server with COOP/COEP so SharedArrayBuffer (audio ring) works."""
import sys
from functools import partial
from pathlib import Path
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class Handler(SimpleHTTPRequestHandler):
    extensions_map = {**SimpleHTTPRequestHandler.extensions_map,
                      ".wasm": "application/wasm", ".mjs": "text/javascript",
                      ".js": "text/javascript"}

    def do_PUT(self):
        """PUT /upload/<name>: the self-tests hand a recording back to be checked with ffmpeg (writes <root>/../<name>)."""
        name = self.path.rsplit("/", 1)[-1]
        if not self.path.startswith("/upload/") or not name.replace(".", "").isalnum():
            return self.send_error(404)
        data = self.rfile.read(int(self.headers["Content-Length"]))
        (Path(self.directory).parent / name).write_bytes(data)
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    root = sys.argv[2] if len(sys.argv) > 2 else "."
    srv = ThreadingHTTPServer(("127.0.0.1", port), partial(Handler, directory=root))
    print(f"serving {root} on http://127.0.0.1:{port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
