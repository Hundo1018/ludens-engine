#!/usr/bin/env python3
"""Reference images of the screen-space effects and the lens shapes, native on lavapipe.

    pixi run -e wasm python3 scripts/tier4_shots.py                 # build/shots/tier4/*.png
    pixi run -e wasm python3 scripts/tier4_shots.py --docs          # also docs/images/tier4/*.png (the committed references)
    pixi run -e wasm python3 scripts/tier4_shots.py bokeh_native    # only the tests named

Runs each test with --dump DIR, then turns each 640 x 360 RGBA dump into a PNG."""
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import build_core  # noqa: E402

TESTS = ["bokeh_native", "ssr_native", "ssao_native"]
W, H = 640, 360


def main(argv: list[str]) -> int:
    docs = "--docs" in argv
    names = [a for a in argv if not a.startswith("--")] or TESTS
    out = ROOT / "build/shots/tier4"
    out.mkdir(parents=True, exist_ok=True)
    for name in names:
        if not (ROOT / f"tests/{name}.mojo").exists():
            continue
        exe = build_core.build_native(f"tests/{name}.mojo", ROOT / f"build/{name}", asserts=True)
        rc = subprocess.run([str(exe), "--dump", str(out)], cwd=ROOT, check=False).returncode
        if rc != 0:
            print(f"tier4_shots: {name} failed ({rc})", file=sys.stderr)
            return rc
    pngs = []
    for raw in sorted(out.glob("*.rgba")):
        data = raw.read_bytes()
        if len(data) != W * H * 4:
            print(f"tier4_shots: {raw.name} is {len(data)} bytes, not {W} x {H} RGBA", file=sys.stderr)
            return 1
        png = raw.with_suffix(".png")
        Image.frombytes("RGBA", (W, H), data).convert("RGB").save(png)
        raw.unlink()
        pngs.append(png)
        print(png.relative_to(ROOT))
    if docs:
        dst = ROOT / "docs/images/tier4"
        dst.mkdir(parents=True, exist_ok=True)
        for p in pngs:
            shutil.copy(p, dst / p.name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
