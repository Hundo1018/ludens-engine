#!/usr/bin/env python3
"""Before / after pictures of colour temperature, IES profiles and cookies (docs/LIGHTS_CAMERA.md), native on lavapipe.

    pixi run -e wasm python3 scripts/light_profiles_shots.py            # build/shots/light_profiles/*.png
    pixi run -e wasm python3 scripts/light_profiles_shots.py --docs     # also docs/images/light_profiles/*.png
    pixi run -e wasm python3 scripts/light_profiles_shots.py --cost     # the frame time table (1920 x 1080, lavapipe)

Runs tests/light_profiles_native.mojo with --dump (every dump is 640 x 360 RGBA) and puts each before / after pair side
by side in one PNG."""
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import build_core  # noqa: E402

W, H = 640, 360
PAIRS = ["kelvin", "ies", "cookie"]


def main(argv: list[str]) -> int:
    exe = build_core.build_native("tests/light_profiles_native.mojo", ROOT / "build/light_profiles_native", asserts=True)
    if "--cost" in argv:
        return subprocess.run([str(exe), "--cost"], cwd=ROOT, check=False).returncode
    out = ROOT / "build/shots/light_profiles"
    out.mkdir(parents=True, exist_ok=True)
    rc = subprocess.run([str(exe), "--dump", str(out)], cwd=ROOT, check=False).returncode
    if rc != 0:
        print(f"light_profiles_shots: the test failed ({rc})", file=sys.stderr)
        return rc
    pngs = []
    for name in PAIRS:
        both = Image.new("RGB", (2 * W + 8, H), (255, 255, 255))
        for i, half in enumerate(("before", "after")):
            raw = out / f"lp_{name}_{half}.rgba"
            data = raw.read_bytes()
            if len(data) != W * H * 4:
                print(f"light_profiles_shots: {raw.name} is {len(data)} bytes, not {W} x {H} RGBA", file=sys.stderr)
                return 1
            both.paste(Image.frombytes("RGBA", (W, H), data).convert("RGB"), (i * (W + 8), 0))
        png = out / f"{name}.png"
        both.save(png, optimize=True)
        pngs.append(png)
        print(png.relative_to(ROOT))
    if "--docs" in argv:
        dst = ROOT / "docs/images/light_profiles"
        dst.mkdir(parents=True, exist_ok=True)
        for p in pngs:
            shutil.copy(p, dst / p.name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
