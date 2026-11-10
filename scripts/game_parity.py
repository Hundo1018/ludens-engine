#!/usr/bin/env python3
"""The arena game gives the same numbers natively and as the wasm64 app driven through its `app_*` exports under node.

Native runs app/game_parity.mojo (serial engine); node loads build/app.wasm, switches to game mode, feeds the same key events
through app_input and steps app_frame. Also checks the jump's sound effect came out of app_audio_render.

Run: pixi run -e wasm python3 scripts/game_parity.py   (builds build/app.wasm first if it is missing)"""
import json
import re
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent
D = ROOT / "build/deps"
sys.path.insert(0, str(ROOT / "scripts"))
from bench import serial_engine  # noqa: E402


def main() -> int:
    subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True)
    subprocess.run(["bash", "scripts/build_wasm.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    import native_libs
    native_libs.build_all()
    eng = serial_engine()
    cmd = [sys.executable, "-m", "ludens_wasm_rt.build_wasm", "--lib", str(eng), "--lib", ".", "-I", str(eng), "-I", ".",
           "app/game_parity.mojo", "--target", "native", "-o", "build/game_parity"]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)
    out = subprocess.run([str(ROOT / "build/game_parity")], capture_output=True, text=True, check=True).stdout
    nat = dict(zip(("hash", "score", "collected", "status"), re.search(r"hash (\d+) score (\d+) collected (\d+) status (\d+)", out).groups()))
    r = subprocess.run(["node", str(ROOT / "scripts/game_node.mjs"), str(ROOT / "build/app.wasm"), str(ludens_wasm_rt.HOST_MJS),
                        str(D / "wgpu-mojo"), str(D / "miniaudio-mojo")], capture_output=True, text=True)
    if r.returncode:
        sys.exit(r.stdout + r.stderr[-2000:])
    wasm = json.loads(r.stdout.strip().splitlines()[-1])
    ok = True
    for k in ("hash", "score", "collected", "status"):
        same = str(wasm[k]) == nat[k]
        ok &= same
        print(f"{k:10} native {nat[k]:>22}  wasm64 {str(wasm[k]):>22}  {'equal' if same else 'DIFFERENT'}")
    sound = wasm["rmsAfterJump"] > 0.01
    ok &= sound
    print(f"jump sound rms {wasm['rmsAfterJump']:.4f}  {'audible' if sound else 'SILENT'}")
    print("game parity:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
