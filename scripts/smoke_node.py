#!/usr/bin/env python3
"""Run scripts/node_smoke.mjs against build/app.wasm with the sibling wgpu-mojo / miniaudio-mojo checkouts."""
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent
wgpu = ROOT / "build/deps/wgpu-mojo"
ma = ROOT / "build/deps/miniaudio-mojo"
sys.exit(subprocess.run(["node", str(ROOT / "scripts/node_smoke.mjs"), str(ROOT / "build/app.wasm"),
                         str(ludens_wasm_rt.HOST_MJS), str(wgpu), str(ma)]).returncode)
