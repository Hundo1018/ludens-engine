#!/usr/bin/env python3
"""The in-game console, cheats and photo mode (issue #146, docs/console.md).

    pixi run -e wasm test-console

1. tests/console.mojo: the console, the cheats in the demo game, replay, the saved mark, photo mode.
2. tests/console_release.mojo built with `-D LUDENS_RELEASE`: the console does nothing.
3. The console's strings (`unknown command`, `is registered twice`, `console replay line`) are in the debug binary of
   step 1 and not in the release binary of step 2: the code is left out at compile time, not switched off.
4. tests/platform_png.mojo writes PNG files; each is decoded with Pillow and compared byte for byte with the RGB it was
   made from."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import build_core  # noqa: E402

MARKERS = [b"unknown command `", b"is registered twice", b"console replay line"]


def main() -> int:
    ok = True
    debug = build_core.build_native("tests/console.mojo", ROOT / "build/console", asserts=True)
    ok &= subprocess.run([str(debug)], cwd=ROOT, check=False).returncode == 0
    # the release variant links only what it uses, so the debug check is the same entry built without the define
    debug_rel = build_core.build_native("tests/console_release.mojo", ROOT / "build/console_debug", asserts=True)
    release = build_core.build_native("tests/console_release.mojo", ROOT / "build/console_release", asserts=True,
                                      defines=("LUDENS_RELEASE",), force=True)
    ok &= subprocess.run([str(release)], cwd=ROOT, check=False).returncode == 0
    d = debug_rel.read_bytes()
    r = release.read_bytes()
    for m in MARKERS:
        in_d, in_r = m in d, m in r
        good = in_d and not in_r
        ok &= good
        print(f"  [{'PASS' if good else 'FAIL'}] `{m.decode()}`: in the debug build {in_d}, in the release build {in_r}")
    print(f"  binary sizes: debug {len(d)} bytes, release {len(r)} bytes")
    png = build_core.build_native("tests/platform_png.mojo", ROOT / "build/platform_png", asserts=True, engine=False)
    ok &= subprocess.run([str(png)], cwd=ROOT, check=False).returncode == 0
    from PIL import Image
    for name in ("one", "noise", "stripes"):
        im = Image.open(ROOT / f"build/png/{name}.png")
        im.load()
        want = (ROOT / f"build/png/{name}.rgb").read_bytes()
        good = im.mode == "RGB" and im.tobytes() == want
        ok &= good
        print(f"  [{'PASS' if good else 'FAIL'}] Pillow decodes build/png/{name}.png ({im.size[0]} x {im.size[1]}) to the bytes it was made from")
    print("test-console:", "ok" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
