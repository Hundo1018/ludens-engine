#!/usr/bin/env python3
"""Static server with COOP/COEP so SharedArrayBuffer (audio ring) works."""
import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class Handler(SimpleHTTPRequestHandler):
    extensions_map = {**SimpleHTTPRequestHandler.extensions_map,
                      ".wasm": "application/wasm", ".mjs": "text/javascript",
                      ".js": "text/javascript"}

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
