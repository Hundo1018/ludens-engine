#!/usr/bin/env python3
"""The frame-budget gate (ludens-engine #123, docs/frame-budgets.md), end to end through real processes.

    pixi run -e wasm test-perf-gate          # builds build/app.wasm first; needs lavapipe for the native run

  - the stats layout in scripts/frame_layout.py equals app/frame_stats.mojo (names, order, sizes);
  - `check`: a counter equal to its budget passes, one over fails, a p95 over its budget only warns, a missing counter fails;
  - the budgets file: a mistyped key, a negative budget and a ring shorter than 300 frames are errors;
  - the Chrome trace of a ring: one `frame` event per frame, segments inside their frame, counters as `C` events;
  - the wasm64 build under node: 300 frames in the ring, 9 bodies, the step and audio rows ran, the GPU rows did not;
  - the native run: the counters match the scene (2 draw calls, 3,460 triangles, 9 bodies), a GPU frame is the sum of its passes;
  - the gate itself: the shipped budgets.toml passes; the same file with `draw_calls = 1` (a breach injected) exits 1 and names the
    counter; a counter budget lowered to the observed value passes and to one below it fails; a tiny `frame_ms` only warns.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import frame_layout as L  # noqa: E402
import frame_trace  # noqa: E402
import perf_gate  # noqa: E402

passed = 0
failed = 0


def check(cond: bool, label: str) -> None:
    global passed, failed
    if cond:
        passed += 1
        print(f"  [PASS] {label}")
    else:
        failed += 1
        print(f"  [FAIL] {label}")


def gate(budgets_text: str, *extra: str, actions: bool = False) -> subprocess.CompletedProcess:
    """Run scripts/perf_gate.py on `budgets_text`. The environment is fixed: the gate prints `FAIL:` / `WARNING:` lines, or GitHub
    annotations (`::error ...`) when GITHUB_ACTIONS is set, and appends to $GITHUB_STEP_SUMMARY when that is set, so the caller's
    values of both are removed and `actions=True` sets GITHUB_ACTIONS on purpose."""
    env = {k: v for k, v in os.environ.items() if k not in ("GITHUB_ACTIONS", "GITHUB_STEP_SUMMARY")}
    if actions:
        env["GITHUB_ACTIONS"] = "true"
    with tempfile.TemporaryDirectory() as d:
        f = Path(d) / "budgets.toml"
        f.write_text(budgets_text)
        return subprocess.run([sys.executable, str(ROOT / "scripts/perf_gate.py"), "--budgets", str(f), *extra], cwd=ROOT, capture_output=True, text=True, check=False, env=env)


SCENE = '[scene]\nname = "arena"\nseed = 7\nframes = 600\nwidth = 1280\nheight = 720\n'


def layout() -> None:
    m = L.mojo_layout()
    check(m["segments"] == L.SEGMENTS, "segment names and order equal app/frame_stats.mojo")
    check(m["counters"] == L.COUNTERS, "counter names and order equal app/frame_stats.mojo")
    check(m["SEGMENTS"] == len(L.SEGMENTS) and m["COUNTERS"] == len(L.COUNTERS), "SEGMENTS and COUNTERS equal the list lengths")
    check(m["STAT_FIELDS"] == len(L.STAT_FIELDS) and m["CTR_FIELDS"] == len(L.CTR_FIELDS), "the field counts equal")
    check(m["FRAME_RING"] == L.FRAME_RING == 300, "the ring is 300 frames")
    check(all(m["seg_ids"][n] == i for i, n in enumerate(L.SEGMENTS) if n in m["seg_ids"]), "SEG_* ids equal the list positions")
    alias = {"draws": "draw_calls"}  # CTR_DRAWS is counter `draw_calls`
    check({alias.get(k, k): v for k, v in m["ctr_ids"].items()} == {n: i for i, n in enumerate(L.COUNTERS)}, "CTR_* ids equal the list positions")


def checks() -> None:
    b = {"counters": {"draw_calls": 3}, "frame_ms": {"frame": 1.0}}
    f, w = perf_gate.check(b, {"counters": {"draw_calls": 3}, "ms": {"frame": 1.0}})
    check(f == [] and w == [], "a counter equal to its budget and a p95 equal to its budget pass")
    f, w = perf_gate.check(b, {"counters": {"draw_calls": 4}, "ms": {"frame": 0.2}})
    check(len(f) == 1 and "draw_calls" in f[0] and "4 > budget 3" in f[0], "a counter one over its budget fails and says by how much")
    f, w = perf_gate.check(b, {"counters": {"draw_calls": 3}, "ms": {"frame": 1.001}})
    check(f == [] and len(w) == 1 and "frame" in w[0], "a p95 over its budget is a warning, not a failure")
    f, w = perf_gate.check(b, {"counters": {}, "ms": {}})
    check(len(f) == 1 and len(w) == 1, "a counter the run did not report fails; a segment that did not run warns")
    check(perf_gate.unique(["a", "b", "a", "a", "c", "b"]) == ["a", "b", "c"], "a finding that every run makes is reported once, in order")


def budgets_file() -> None:
    with tempfile.TemporaryDirectory() as d:
        def load(text: str):
            p = Path(d) / "b.toml"
            p.write_text(text)
            try:
                return perf_gate.load_budgets(p)
            except perf_gate.BudgetError as e:
                return str(e)

        ok = load(SCENE + "[counters]\ndraw_calls = 4\n")
        check(isinstance(ok, dict) and ok["counters"] == {"draw_calls": 4}, "a valid file loads")
        check("draw_cals" in str(load("[counters]\ndraw_cals = 4\n")), "a mistyped counter name is an error that names it")
        check("number >= 0" in str(load("[counters]\ndraw_calls = -1\n")), "a negative budget is an error")
        check("number >= 0" in str(load("[counters]\ndraw_calls = true\n")), "a boolean budget is an error")
        check("below the ring" in str(load('[scene]\nframes = 100\n')), "a scene shorter than the 300-frame ring is an error")
        check("unknown table" in str(load("[counter]\ndraw_calls = 4\n")), "a mistyped table name is an error")
    r = gate("[counters]\ndraw_cals = 4\n")
    check(r.returncode == 2 and "draw_cals" in r.stderr, "the gate exits 2 on a bad budgets file")
    shipped = perf_gate.load_budgets(ROOT / "budgets.toml")
    check(set(shipped["counters"]) == set(L.COUNTERS), "the shipped budgets.toml gives every counter a budget")


def trace() -> None:
    ring = []
    for k in range(3):
        row = [-1] * len(L.SEGMENTS) + [0] * len(L.COUNTERS)
        row[L.SEGMENTS.index("frame")] = 1000 + k
        row[L.SEGMENTS.index("step")] = 400
        row[L.SEGMENTS.index("physics")] = 300
        row[L.SEGMENTS.index("draw")] = 500
        row[L.SEGMENTS.index("gpu_scene")] = 7000
        row[len(L.SEGMENTS) + L.COUNTERS.index("draw_calls")] = 2 + k
        ring.append(row)
    t = frame_trace.to_chrome(ring)
    ev = t["traceEvents"]
    json.dumps(t)
    frames = [e for e in ev if e["name"] == "frame"]
    check(len(frames) == 3 and [e["dur"] for e in frames] == [1.0, 1.001, 1.002], "one `frame` event per frame, in microseconds")
    check(frames[1]["ts"] == 1.0 and frames[2]["ts"] == 2.001, "frames lie end to end")
    step = [e for e in ev if e["name"] == "step"][0]
    phys = [e for e in ev if e["name"] == "physics"][0]
    check(phys["ts"] >= step["ts"] and phys["ts"] + phys["dur"] <= step["ts"] + step["dur"], "physics lies inside step")
    check(not [e for e in ev if e["name"] in ("net", "present", "audio", "ai")], "a segment that did not run has no event")
    check([e["args"]["draw_calls"] for e in ev if e["ph"] == "C" and e["name"] == "draw_calls"] == [2, 3, 4], "the counters are C events, one per frame")
    check(any(e["name"] == "gpu_scene" and e["tid"] == 3 for e in ev), "GPU passes are on their own thread")


def wasm_run(budgets: dict) -> None:
    w = perf_gate.measure_wasm(budgets)
    check(len(w["ring"]) == 300, "the wasm64 ring holds 300 frames after 600")
    check(w["counters"]["bodies"]["max"] == 9, "wasm64: the arena has 9 bodies")
    check(w["counters"]["particles"]["max"] == 0 and w["counters"]["ai_agents"]["max"] == 0, "wasm64: no particles, no AI agents")
    check(w["stats"]["step"]["count"] == 300 and w["stats"]["audio"]["count"] == 300, "wasm64: step and audio ran in every frame of the ring")
    check(w["stats"]["gpu_frame"]["count"] == 0 and w["stats"]["draw"]["count"] == 0, "wasm64 under node: no draw and no GPU rows (reported as did not run)")
    check(w["stats"]["ai"]["count"] == 0, "the demo game has no AI row")
    check(all(r[L.SEGMENTS.index("gpu_frame")] == -1 for r in w["ring"]), "absent GPU time is -1 in every frame, not 0")


def native_run(budgets: dict) -> dict:
    n = perf_gate.measure_native(budgets)
    c = n["counters"]
    check(c["draw_calls"]["max"] == 2, "native: 2 draw calls (the primitive draw and the HUD)")
    check(c["triangles"]["max"] == 9 * 384 + 4, "native: 9 primitives of 384 triangles and the HUD's 4")
    check(c["bodies"]["max"] == 9, "native: 9 bodies")
    check(c["texture_bytes"]["max"] == 28_109_472, "native: 28,109,472 bytes of textures")
    check(n["stats"]["frame"]["count"] == 300 and n["stats"]["draw"]["count"] == 300, "native: frame and draw ran in all 300 frames")
    gi = {s: i for i, s in enumerate(L.SEGMENTS)}
    if n["gpu_timing"]:
        parts = ["gpu_shadow", "gpu_scene", "gpu_post"]
        ok = all(r[gi["gpu_frame"]] == sum(max(r[gi[p]], 0) for p in parts) and r[gi["gpu_frame"]] > 0 for r in n["ring"])
        check(ok, "native: gpu_frame equals the sum of the GPU passes in every frame, and is > 0")
        check(n["stats"]["gpu_post"]["count"] == 0, "native: this pipeline has no post stages, so gpu_post did not run")
    else:
        check(all(r[gi["gpu_frame"]] == -1 for r in n["ring"]), "native, no timestamp queries: the GPU rows are -1")
    return n


def gate_runs(budgets_text: str) -> None:
    r = gate(budgets_text)
    check(r.returncode == 0 and "perf-gate: ok" in r.stdout, "the shipped budgets pass")
    r = gate(budgets_text.replace("draw_calls = 4", "draw_calls = 1"))
    check(r.returncode == 1 and "FAIL: run 1: counter `draw_calls`: 2 > budget 1" in r.stdout, "an injected breach (draw_calls = 1) exits 1 and names the counter")
    r = gate(budgets_text.replace("draw_calls = 4", "draw_calls = 2").replace("triangles = 4000", "triangles = 3460").replace("bodies = 12", "bodies = 9"), "--no-wasm")
    check(r.returncode == 0, "budgets equal to the observed counters pass")
    r = gate(budgets_text.replace("triangles = 4000", "triangles = 3459"), "--no-wasm")
    check(r.returncode == 1 and "triangles" in r.stdout, "triangles one below the observed value fails")
    r = gate(budgets_text.replace("frame = 0.5", "frame = 0.0001"))
    check(r.returncode == 0 and "WARNING" in r.stdout and "p95 of `frame`" in r.stdout, "a p95 budget of 0.0001 ms warns and does not fail")
    # under GitHub Actions the same findings are annotations
    r = gate(budgets_text.replace("draw_calls = 4", "draw_calls = 1"), "--no-wasm", actions=True)
    check(r.returncode == 1 and "::error title=perf-gate::run 1: counter `draw_calls`: 2 > budget 1" in r.stdout, "under GITHUB_ACTIONS a breach is an ::error annotation and still exits 1")
    r = gate(budgets_text.replace("frame = 0.5", "frame = 0.0001"), "--no-wasm", actions=True)
    check(r.returncode == 0 and "::warning title=perf-gate::p95 of `frame`" in r.stdout, "under GITHUB_ACTIONS a slow p95 is a ::warning annotation and exits 0")


def main() -> int:
    """`test_perf_gate.py [layout] [check] [budgets] [trace] [wasm] [native] [gate]`: only those sections (default: all)."""
    want = set(sys.argv[1:]) or {"layout", "check", "budgets", "trace", "wasm", "native", "gate"}
    budgets = perf_gate.load_budgets(ROOT / "budgets.toml")
    sections = [
        ("layout", layout), ("check", checks), ("budgets", budgets_file), ("trace", trace),
        ("wasm", lambda: wasm_run(budgets)), ("native", lambda: native_run(budgets)),
        ("gate", lambda: gate_runs((ROOT / "budgets.toml").read_text())),
    ]
    for name, fn in sections:
        if name in want:
            print(name)
            fn()
    print(f"{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
