#!/usr/bin/env python3
"""Reference images of the rendering tier 3 features (#141), native on lavapipe.

    pixi run -e wasm python3 scripts/tier3_shots.py            # build/shots/tier3/*.png
    pixi run -e wasm python3 scripts/tier3_shots.py --docs     # also docs/images/tier3/*.png (the committed references)

Runs tests/volumetric_native.mojo, tests/probes_native.mojo and tests/mesh_lod_native.mojo with --dump, then turns each W x H RGBA dump into a PNG.
The dumps carry no size: all are 320 x 180."""
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import build_core  # noqa: E402

TESTS = ["volumetric_native", "probes_native", "mesh_lod_native"]  # every dump is 320 x 180 RGBA


def main(argv: list[str]) -> int:
    out = ROOT / "build/shots/tier3"
    out.mkdir(parents=True, exist_ok=True)
    for name in TESTS:
        if not (ROOT / f"tests/{name}.mojo").exists():
            continue
        exe = build_core.build_native(f"tests/{name}.mojo", ROOT / f"build/{name}", asserts=True)
        rc = subprocess.run([str(exe), "--dump", str(out)], cwd=ROOT, check=False).returncode
        if rc != 0:
            print(f"tier3_shots: {name} failed ({rc})", file=sys.stderr)
            return rc
    pngs = []
    for raw in sorted(out.glob("*.rgba")):
        data = raw.read_bytes()
        w, h = 320, 180
        if len(data) != w * h * 4:
            print(f"tier3_shots: {raw.name} is {len(data)} bytes, not {w} x {h} RGBA", file=sys.stderr)
            return 1
        png = raw.with_suffix(".png")
        Image.frombytes("RGBA", (w, h), data).convert("RGB").save(png, optimize=True)
        pngs.append(png)
        print(png.relative_to(ROOT))
    if "--docs" in argv:
        dst = ROOT / "docs/images/tier3"
        dst.mkdir(parents=True, exist_ok=True)
        for p in pngs:
            shutil.copy(p, dst / p.name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
