#!/usr/bin/env python3
"""Assemble build/web: the wasm module, the shell's JS (TS stripped with node), and the shared host files."""
import shutil
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build/web"
WGPU = ROOT / "build/deps/wgpu-mojo"
MA = ROOT / "build/deps/miniaudio-mojo"
STRIP = "import {stripTypeScriptTypes as s} from 'node:module';import fs from 'node:fs';" \
        "fs.writeFileSync(process.argv[2], s(fs.readFileSync(process.argv[1], 'utf8')))"


def main() -> None:
    subprocess.run([sys.executable, str(ROOT / "scripts/gen_exports.py"), "--check"], check=True)
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    shutil.copy(ROOT / "build/app.wasm", OUT / "app.wasm")
    for f in ("index.html", "worklet.js", "net_host.mjs", "os_host.mjs", "game_hook.mjs"):
        shutil.copy(ROOT / "shell/web" / f, OUT / f)
    shutil.copy(ludens_wasm_rt.HOST_MJS, OUT / "host.mjs")
    for f in ("webgpu_host.mjs", "webgpu_impl.mjs", "webgpu_runtime.mjs", "webgpu_layout.json"):
        shutil.copy(WGPU / "web" / f, OUT / f)
    shutil.copy(ROOT / "shell/web/pixel_tolerance.json", OUT / "pixel_tolerance.json")
    native_px = ROOT / "build/pixels_native.rgba"
    if native_px.exists():  # the native reference for ?selftest=parity (scripts/parity_pixels_native.py)
        shutil.copy(native_px, OUT / "pixels_native.rgba")
    shutil.copy(ROOT / "assets/fonts/NotoSansTC-Regular-24.lfont", OUT / "font.lfont")  # the HUD's SDF font (#116)
    sys.path.insert(0, str(ROOT / "scripts"))
    import check_font_asset
    check_font_asset.write_built_license(OUT)  # the OFL requires the license and copyright with every copy
    import check_audio_asset
    check_audio_asset.copy_to_build(OUT)  # the music (#120) and audio-LICENSE.txt
    shutil.copy(WGPU / "scripts/webgpu_enum_strings.json", OUT / "webgpu_enum_strings.json")
    shutil.copy(MA / "web/miniaudio_host.mjs", OUT / "miniaudio_host.mjs")
    for ts, js in (("app.ts", "app.js"), ("keys.ts", "keys.js"), ("record.ts", "record.js"), ("pad.ts", "pad.js"),
                   ("vpad.ts", "vpad.js"), ("vpad_view.ts", "vpad_view.js")):
        subprocess.run(["node", "--input-type=module", "-e", STRIP, str(ROOT / "shell/web" / ts), str(OUT / js)], check=True)
    problems = check_font_asset.check_built(OUT) + check_audio_asset.check_built(OUT)
    if problems:
        sys.exit("build_web: " + "; ".join(problems))
    print(f"build_web: {OUT} ({sum(1 for _ in OUT.iterdir())} files)")


if __name__ == "__main__":
    main()
