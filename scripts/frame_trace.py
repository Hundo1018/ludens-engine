#!/usr/bin/env python3
"""Write the frame ring as a Chrome trace (Perfetto, chrome://tracing) file (#123).

    pixi run -e wasm python3 scripts/frame_trace.py native OUT.json [--frames N]    # the demo game's scripted scene, native
    pixi run -e wasm python3 scripts/frame_trace.py wasm OUT.json                   # the same scene, wasm64 under node

Frames are laid end to end on one timeline: frame k starts where frame k - 1 ended (its `frame` segment). Within a frame,
the CPU segments are `X` events on thread 1 in the order the host runs them (net, step, scene, push, hud, draw, present), with
physics and ai nested at the start of step; audio is on thread 2 (the mixer's work since the last frame), the GPU passes on
thread 3 (shadow, scene, post one after another from the start of the frame's draw: the GPU runs after the CPU submits).
Every counter is a `C` event at the frame's start. A segment that did not run in a frame has no event. Timestamps and
durations are microseconds, as the format wants, with the nanosecond part kept as a fraction."""
import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import frame_layout as L  # noqa: E402

CPU_ORDER = ["net", "step", "scene", "push", "hud", "draw", "present"]
GPU_ORDER = ["gpu_shadow", "gpu_scene", "gpu_post"]


def to_chrome(ring: list[list[int]]) -> dict:
    """`ring`: one list per frame, oldest first: the SEGMENTS times in ns (-1 = did not run), then the COUNTERS."""
    ev: list[dict] = []
    t = 0.0  # ns
    seg = {n: i for i, n in enumerate(L.SEGMENTS)}
    for tid, name in ((1, "cpu"), (2, "audio"), (3, "gpu")):
        ev.append({"name": "thread_name", "ph": "M", "pid": 1, "tid": tid, "args": {"name": name}})
    for k, row in enumerate(ring):
        ns = {n: row[seg[n]] for n in L.SEGMENTS}
        frame = max(ns["frame"], 0)

        def x(name: str, start: float, dur: int, tid: int, k: int = k) -> None:
            ev.append({"name": name, "ph": "X", "pid": 1, "tid": tid, "ts": start / 1000.0, "dur": dur / 1000.0, "args": {"frame": k}})

        x("frame", t, frame, 1)
        cur = t
        for n in CPU_ORDER:
            if ns[n] >= 0:
                x(n, cur, ns[n], 1)
                if n == "step":  # physics and ai are inside step; they are drawn at its start, one after the other
                    inner = cur
                    for m in ("physics", "ai"):
                        if ns[m] >= 0:
                            x(m, inner, ns[m], 1)
                            inner += ns[m]
                cur += ns[n]
        if ns["audio"] >= 0:
            x("audio", t, ns["audio"], 2)
        gcur = t + sum(ns[n] for n in CPU_ORDER if n != "present" and ns[n] >= 0)
        for n in GPU_ORDER:
            if ns[n] >= 0:
                x(n, gcur, ns[n], 3)
                gcur += ns[n]
        for i, c in enumerate(L.COUNTERS):
            ev.append({"name": c, "ph": "C", "pid": 1, "ts": t / 1000.0, "args": {c: row[len(L.SEGMENTS) + i]}})
        t += frame
    return {"traceEvents": ev, "displayTimeUnit": "ms"}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("target", choices=["native", "wasm"])
    ap.add_argument("out", type=Path)
    ap.add_argument("--frames", type=int, default=600)
    a = ap.parse_args()
    import perf_gate  # noqa: E402

    budgets = perf_gate.load_budgets(ROOT / "budgets.toml")
    m = perf_gate.measure_native(budgets, a.frames) if a.target == "native" else perf_gate.measure_wasm(budgets)
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps(to_chrome(m["ring"])))
    print(f"frame_trace: {len(m['ring'])} frames -> {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
