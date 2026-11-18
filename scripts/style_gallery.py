#!/usr/bin/env python3
"""Render every style pipeline (tests/style_gallery_native.mojo) and lay the frames out as PNGs.

    pixi run -e wasm style-gallery                 # build/gallery/<name>.png and build/gallery/sheet_<n>.png
    pixi run -e wasm style-gallery -- --only crt   # frames whose name contains "crt"

The Mojo program writes build/gallery/<name>.rgba (W x H RGBA8, the size it prints) and one "style <name> ..." line per
frame; this script converts them and draws contact sheets of 4 x 4 frames with the names under them."""
import argparse
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import build_core  # noqa: E402

OUT = ROOT / "build/gallery"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--cols", type=int, default=4)
    ap.add_argument("--rows", type=int, default=4)
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.rgba"):
        old.unlink()
    exe = build_core.build_native("tests/style_gallery_native.mojo", ROOT / "build/style_gallery_native", asserts=True)
    proc = subprocess.run([str(exe), "--dump", a.only], cwd=ROOT, capture_output=True, text=True)
    sys.stdout.write(proc.stdout)
    sys.stderr.write(proc.stderr[-4000:])
    size = None
    names = []
    for line in proc.stdout.splitlines():
        w = line.split()
        if w[:1] == ["size"]:
            size = (int(w[1]), int(w[2]))
        if w[:1] == ["style"]:
            names.append(w[1])
    if size is None:
        return proc.returncode or 1
    thumbs = []
    for n in names:
        raw = (OUT / f"{n}.rgba").read_bytes()
        im = Image.frombytes("RGBA", size, raw).convert("RGB")
        im.save(OUT / f"{n}.png")
        thumbs.append((n, im))
    per = a.cols * a.rows
    tw, th = size[0] // 2, size[1] // 2
    for s in range(0, len(thumbs), per):
        page = thumbs[s:s + per]
        sheet = Image.new("RGB", (a.cols * tw, a.rows * (th + 14)), (24, 24, 24))
        d = ImageDraw.Draw(sheet)
        for i, (n, im) in enumerate(page):
            x, y = (i % a.cols) * tw, (i // a.cols) * (th + 14)
            sheet.paste(im.resize((tw, th), Image.LANCZOS), (x, y))
            d.text((x + 3, y + th + 1), n, fill=(235, 235, 235))
        sheet.save(OUT / f"sheet_{s // per}.png")
    print("wrote", len(thumbs), "frames and", (len(thumbs) + per - 1) // per, "sheets to", OUT)
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
