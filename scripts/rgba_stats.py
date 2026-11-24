#!/usr/bin/env python3
"""Compare raw RGBA8 frames (tightly packed) and print what shell/web/app.ts's pixel rows count, for looking at a frame
without a browser:  rgba_stats.py A.rgba B.rgba W H   (differences)   or   rgba_stats.py A.rgba W H   (the warm-grade count)
`--png OUT.png` also writes A as a PNG (needs Pillow, which the wasm environment has)."""
import sys


def load(path: str) -> bytes:
    with open(path, "rb") as f:
        return f.read()


def main(argv: list[str]) -> int:
    png = None
    if "--png" in argv:
        i = argv.index("--png")
        png = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    a = load(argv[0])
    if len(argv) == 3:
        w, h = int(argv[1]), int(argv[2])
        graded = sum(1 for i in range(0, w * h * 4, 4) if a[i] > a[i + 2] + 40)
        print(f"{argv[0]}: {w}x{h}, pixels with red > blue + 40: {graded}")
    else:
        b = load(argv[1])
        w, h = int(argv[2]), int(argv[3])
        if len(a) != len(b):
            print("sizes differ")
            return 1
        mx = over8 = over32 = 0
        for i in range(0, len(a), 4):
            d = max(abs(a[i + c] - b[i + c]) for c in range(4))
            mx = max(mx, d)
            over8 += d > 8
            over32 += d > 32
        print(f"max delta {mx}, over 8: {over8 / (w * h):.6f}, over 32: {over32 / (w * h):.6f}")
    if png:
        from PIL import Image
        Image.frombytes("RGBA", (w, h), a).save(png)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
