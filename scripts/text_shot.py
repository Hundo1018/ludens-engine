#!/usr/bin/env python3
"""Screenshot check for the HUD text (#116): play the demo game in headless Chrome (software WebGPU) with different UI
settings and save the frames to build/shots/text_<name>_{start,moved,paused}.png.

    pixi run -e wasm text-shot [--no-build]

Settings (page parameters read by shell/web/app.ts): `textscale`, `lang`, `pseudo`, `safe` (insets in CSS px).
Each run goes through scripts/game_screenshot.mjs, so it fails unless the frames show a scene, react to the keys and the
browser reports no WebGPU error. `text_ink` then counts the pixels of the HUD's text colour in each corner region to show
that the text is drawn and that it stays inside the safe area."""
import shutil
import struct
import subprocess
import sys
import time
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNS = {
    "en_100": "lang=en",
    "zh_100": "lang=zh-TW",
    "zh_200": "lang=zh-TW&textscale=2",
    "en_200": "lang=en&textscale=2",
    "pseudo_200_safe": "lang=en&pseudo&textscale=2&safe=48,0,48,24",
}


def read_png(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    pos, idat, w, h = 8, b"", 0, 0
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h = struct.unpack(">II", body[:8])
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = w * 4 + 1
    return w, h, b"".join(raw[y * stride + 1:(y + 1) * stride] for y in range(h))  # filter 0 only: game_screenshot.mjs writes that


def white_pixels(path: Path) -> tuple[int, int, list[tuple[int, int]]]:
    w, h, px = read_png(path)
    out = []
    for y in range(h):
        row = px[y * w * 4:(y + 1) * w * 4]
        for x in range(w):
            if row[4 * x] > 235 and row[4 * x + 1] > 235 and row[4 * x + 2] > 235:
                out.append((x, y))
    return w, h, out


def main(argv: list[str]) -> int:
    chrome = shutil.which("google-chrome") or shutil.which("chromium")
    if not chrome:
        sys.exit("text_shot: no Chrome found")
    if "--no-build" not in argv:
        subprocess.run(["bash", "scripts/build_wasm.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
        subprocess.run([sys.executable, "scripts/build_web.py"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    out = ROOT / "build/shots"
    out.mkdir(parents=True, exist_ok=True)
    server = subprocess.Popen([sys.executable, "shell/web/serve.py", "8143", "build/web"], cwd=ROOT,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    rc = 0
    try:
        time.sleep(2)
        for name, query in RUNS.items():
            r = subprocess.run(["node", "scripts/game_screenshot.mjs", chrome, "http://127.0.0.1:8143/index.html?offscreen%26" + query.replace("&", "%26"),
                                str(out / f"text_{name}"), "150"], cwd=ROOT, check=False, capture_output=True, text=True)
            ok = r.returncode == 0
            rc |= 0 if ok else 1
            w, h, ink = white_pixels(out / f"text_{name}_paused.png")
            left = min(x for x, _ in ink) if ink else -1
            right = max(x for x, _ in ink) if ink else -1
            print(f"text_shot {name}: {'ok' if ok else 'FAIL'}; paused frame {w}x{h}: {len(ink)} text pixels, x from {left} to {right}")
            if not ok:
                print(r.stdout[-800:])
    finally:
        server.kill()
    print("frames in", out)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
