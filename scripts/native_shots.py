#!/usr/bin/env python3
"""PNG frames from a native lavapipe test that writes raw RGBA dumps with `--dump DIR`.

    pixi run -e wasm python3 scripts/native_shots.py shadows_native 960x540              # build/shots/shadows_native/*.png
    pixi run -e wasm python3 scripts/native_shots.py shadows_native 960x540 --docs images/shadows   # also docs/images/shadows/
    pixi run -e wasm python3 scripts/native_shots.py shadows_native --cost                # the test's --cost table instead

Builds tests/<name>.mojo, runs it with --dump into build/shots/<name>/ and turns each W x H RGBA dump into a PNG. Every
dump of one test has the size given on the command line."""
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import build_core  # noqa: E402


def main(argv: list[str]) -> int:
    if not argv:
        sys.exit(__doc__)
    name = argv[0]
    env = dict(os.environ)
    env.setdefault("WGPU_BACKEND", "vulkan")
    if "--cost" in argv:
        exe = build_core.build_native(f"tests/{name}.mojo", ROOT / f"build/{name}_cost", asserts=False)
        return subprocess.run([str(exe), "--cost"], cwd=ROOT, env=env, check=False).returncode
    from PIL import Image

    w, h = (int(x) for x in argv[1].split("x"))
    out = ROOT / "build/shots" / name
    out.mkdir(parents=True, exist_ok=True)
    exe = build_core.build_native(f"tests/{name}.mojo", ROOT / f"build/{name}", asserts=True)
    rc = subprocess.run([str(exe), "--dump", str(out)], cwd=ROOT, env=env, check=False).returncode
    if rc != 0:
        print(f"native_shots: {name} failed ({rc})", file=sys.stderr)
        return rc
    pngs = []
    for raw in sorted(out.glob("*.rgba")):
        data = raw.read_bytes()
        if len(data) != w * h * 4:
            print(f"native_shots: {raw.name} is {len(data)} bytes, not {w} x {h} RGBA", file=sys.stderr)
            return 1
        png = raw.with_suffix(".png")
        Image.frombytes("RGBA", (w, h), data).convert("RGB").save(png, optimize=True)
        pngs.append(png)
        print(png.relative_to(ROOT))
    if "--docs" in argv:
        dst = ROOT / "docs" / argv[argv.index("--docs") + 1]
        dst.mkdir(parents=True, exist_ok=True)
        for p in pngs:
            shutil.copy(p, dst / p.name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
