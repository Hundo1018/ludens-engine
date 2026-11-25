#!/usr/bin/env python3
"""Where one frame of the demo game goes, segment by segment, against the 6.94 ms frame of a 144 Hz display (#123).

    pixi run -e wasm frame-budget [--frames N]

Two runs, both reading the same per-segment ring (app/frame_stats.mojo, the last 300 frames):
1. native: app/frame_budget.mojo on native wgpu (lavapipe without a GPU) at three resolutions. It steps and draws the
   game as `AppOf` does but into an offscreen texture, so there is no net poll and no present.
2. wasm64: the real app (build/app.wasm) under node through scripts/game_node.mjs, read through `app_frame_stats`. Node
   has no WebGPU, so the frame stops after the step: the draw rows are not measured there.

DemoMode has no scene-size knob, so every run draws the default scene (11 boxes and the ball). Prints a markdown table of
p50 / p95 in ms per segment."""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent
D = ROOT / "build/deps"
sys.path.insert(0, str(ROOT / "scripts"))
import build_core  # noqa: E402
import native_libs  # noqa: E402

BUDGET_MS = 1000.0 / 144.0
SIZES = [(640, 480), (1280, 720), (1920, 1080)]
# app/frame_stats.mojo SEG_* order (the first nine rows are the table's; ai, audio and the GPU rows have their own tools)
SEGMENTS = ["net", "step", "physics", "scene", "push", "hud", "draw", "present", "frame"]
LABELS = {
    "net": "net (packets)", "step": "input + game step", "physics": "&nbsp;&nbsp;physics (inside step)",
    "scene": "scene build (`GameMode.scene`)", "push": "renderer push", "hud": "HUD (`GameMode.hud` + `Hud.set`)",
    "draw": "draw: encode + submit (CPU)", "present": "acquire + present", "frame": "**whole frame**",
}


def native(w: int, h: int, frames: int, exe: Path) -> dict[str, list[int]]:
    out = subprocess.run([str(exe), str(w), str(h), str(frames)], cwd=ROOT, env=native_libs.native_env(),
                         capture_output=True, text=True, check=True).stdout
    # `seg name avg A p50 B p95 C p99 D max E count N` -> [p50, p95, max, count]
    return {n: [int(p50), int(p95), int(mx), int(c)] for n, _avg, p50, p95, _p99, mx, c in
            re.findall(r"^seg (\w+) avg (\d+) p50 (\d+) p95 (\d+) p99 (\d+) max (\d+) count (\d+)", out, re.M)}


def wasm(frames: int) -> dict[str, list[int]]:
    r = subprocess.run(["node", str(ROOT / "scripts/game_node.mjs"), str(ROOT / "build/app.wasm"), str(ludens_wasm_rt.HOST_MJS),
                        str(D / "wgpu-mojo"), str(D / "miniaudio-mojo"), str(frames)], capture_output=True, text=True, check=False)
    if r.returncode:
        sys.exit(r.stdout + r.stderr[-2000:])
    stats = json.loads(r.stdout.strip().splitlines()[-1])["stats"]
    return {n: [row[1], row[2], row[4], row[5]] for n, row in zip(SEGMENTS, stats, strict=False)}  # p50, p95, max, count


def cell(v: list[int]) -> str:
    if not v or v[3] == 0:
        return "not run"
    return f"{v[0] / 1e6:.3f} / {v[1] / 1e6:.3f}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--frames", type=int, default=600, help="frames per run; the stats are over the last 300")
    a = ap.parse_args()
    subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    native_libs.build_all()
    exe = build_core.build_native("app/frame_budget.mojo", ROOT / "build/frame_budget")
    subprocess.run(["bash", "scripts/build_wasm.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)

    cols = [(f"native {w}x{h}", native(w, h, a.frames, exe)) for w, h in SIZES]
    cols.append(("wasm64, node (no WebGPU)", wasm(a.frames)))
    print(f"## Frame breakdown of the demo game, p50 / p95 in ms over the last 300 of {a.frames} frames\n")
    print(f"Budget: {BUDGET_MS:.2f} ms (144 Hz). CPU time only; the GPU's own time is not measured. "
          "\"not run\": the segment does not exist on that target (no net poll or present natively, no draw under node).\n")
    print("| segment | " + " | ".join(c for c, _ in cols) + " |")
    print("|---|" + "---:|" * len(cols))
    for s in SEGMENTS:
        print(f"| {LABELS[s]} | " + " | ".join(cell(d.get(s, [])) for _, d in cols) + " |")
    print("| whole frame p95, share of the budget | " + " | ".join(
        f"{d['frame'][1] / 1e6 / BUDGET_MS * 100:.1f} %" for _, d in cols) + " |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
