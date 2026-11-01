#!/usr/bin/env python3
"""Run scripts/node_smoke.mjs against build/app.wasm with the sibling wgpu-mojo / miniaudio-mojo checkouts."""
import os
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent
wgpu = Path(os.environ.get("WGPU_MOJO", ROOT / "../wgpu-mojo")).resolve()
ma = Path(os.environ.get("MINIAUDIO_MOJO", ROOT / "../miniaudio-mojo/miniaudio-mojo")).resolve()
sys.exit(subprocess.run(["node", str(ROOT / "scripts/node_smoke.mjs"), str(ROOT / "build/app.wasm"),
                         str(ludens_wasm_rt.HOST_MJS), str(wgpu), str(ma)]).returncode)
