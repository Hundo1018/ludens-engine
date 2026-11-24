#!/usr/bin/env python3
"""The frame-budget gate (#123): run a fixed scripted scene and check it against `budgets.toml`.

    pixi run -e wasm perf-gate                       # measure, check, print the table; exit 1 on a counter over its budget
    pixi run -e wasm perf-gate --runs 10 --spread    # repeat the timed run and print the spread of each p95
    pixi run -e wasm perf-gate --budgets other.toml  # a project's own file

What it runs (the scene is `[scene]` in the budgets file; the default is the demo game's `arena`, seed 7):
  - native, on lavapipe (app/frame_budget.mojo): the real renderer, so draw calls, triangles and texture bytes, and the CPU
    time of each segment of the frame;
  - wasm64 under node (scripts/frame_stats_node.mjs, the `window.game` hook of docs/automation.md): the game's own counters (bodies,
    particles, AI agents) and the step, physics and audio time of the real build.

What fails and what only warns:
  - `[counters]`: a work count (draw calls, triangles, texture bytes, particles, bodies, AI agents), the largest value over the last
    300 frames. It does not depend on the machine's speed, so a value above its budget FAILS (exit 1). The budget is a maximum:
    equal passes.
  - `[frame_ms]`: the p95 of a segment, in ms. Wall clock on a shared runner is noisy, so a value above its budget only WARNS
    (a GitHub annotation under Actions). `--spread` shows how far a p95 moves between runs, which is what a budget must clear.
  - a counter the native and the wasm64 run both report (bodies, particles, AI agents) must be equal: a difference fails.
A key that is not a counter or segment name is an error (exit 2), so a typo cannot switch a gate off. The trace of the native run
(Chrome trace format) is written to build/perf_gate/trace.json."""
import argparse
import json
import os
import statistics
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import frame_layout as L  # noqa: E402

OUT = ROOT / "build/perf_gate"
NATIVE_COUNTERS = {"draw_calls", "triangles", "texture_bytes"}  # counted by the renderer: only the native run has it
SHARED_COUNTERS = {"particles", "bodies", "ai_agents"}  # counted by the game: the native and the wasm64 run both report them
KEYS = {"scene": {"name", "seed", "frames", "width", "height", "hold", "jump_every"}, "counters": set(L.COUNTERS), "frame_ms": set(L.SEGMENTS)}


class BudgetError(Exception):
    """The budgets file is wrong (exit 2)."""


def load_budgets(path: Path) -> dict:
    try:
        b = tomllib.loads(Path(path).read_text())
    except (OSError, tomllib.TOMLDecodeError) as e:
        raise BudgetError(f"{path}: {e}") from e
    for table, vals in b.items():
        if table not in KEYS:
            raise BudgetError(f"{path}: unknown table [{table}] (tables: {', '.join(KEYS)})")
        for k, v in vals.items():
            if k not in KEYS[table]:
                raise BudgetError(f"{path}: [{table}] has no `{k}` (known: {', '.join(sorted(KEYS[table]))})")
            if table != "scene" and (isinstance(v, bool) or not isinstance(v, (int, float)) or v < 0):
                raise BudgetError(f"{path}: [{table}] {k} = {v!r}: a budget is a number >= 0")
    scene = {"name": "arena", "seed": 7, "frames": 600, "width": 1280, "height": 720, "hold": "KeyD", "jump_every": 120, **b.get("scene", {})}
    if scene["frames"] < L.FRAME_RING:
        raise BudgetError(f"{path}: [scene] frames = {scene['frames']} is below the ring of {L.FRAME_RING}: the stats would cover fewer frames than the budget names")
    return {"scene": scene, "counters": b.get("counters", {}), "frame_ms": b.get("frame_ms", {})}


def check(budgets: dict, measured: dict) -> tuple[list[str], list[str]]:
    """(failures, warnings). `measured`: {"counters": {name: max over the ring}, "ms": {segment: p95 in ms}}. Pure: no I/O."""
    failures, warnings = [], []
    for name, limit in budgets["counters"].items():
        if name not in measured["counters"]:
            failures.append(f"counter `{name}` has a budget but the run did not report it")
        elif measured["counters"][name] > limit:
            failures.append(f"counter `{name}`: {measured['counters'][name]} > budget {limit}")
    for name, limit in budgets["frame_ms"].items():
        if name not in measured["ms"]:
            warnings.append(f"segment `{name}` has a p95 budget but did not run (no samples)")
        elif measured["ms"][name] > limit:
            warnings.append(f"p95 of `{name}`: {measured['ms'][name]:.3f} ms > budget {limit} ms")
    return failures, warnings


def unique(xs: list[str]) -> list[str]:
    """`xs` without repeats, in order: a finding that every run makes is reported once."""
    out: list[str] = []
    for x in xs:
        if x not in out:
            out.append(x)
    return out


def _env() -> dict:
    env = dict(os.environ)
    env.setdefault("VK_ICD_FILENAMES", "/usr/share/vulkan/icd.d/lvp_icd.json")
    env.setdefault("LIBGL_ALWAYS_SOFTWARE", "1")
    env.setdefault("WGPU_BACKEND", "vulkan")
    return env


def measure_native(budgets: dict, frames: int | None = None) -> dict:
    import build_core
    import native_libs

    s = budgets["scene"]
    subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    native_libs.build_all()
    exe = build_core.build_native("app/frame_budget.mojo", ROOT / "build/frame_budget")
    env = {**native_libs.native_env(), **{k: v for k, v in _env().items() if k in ("VK_ICD_FILENAMES", "LIBGL_ALWAYS_SOFTWARE", "WGPU_BACKEND")}}
    out = subprocess.run([str(exe), str(s["width"]), str(s["height"]), str(frames or s["frames"]), s["name"], str(s["seed"]), "ring"],
                         cwd=ROOT, env=env, capture_output=True, text=True, check=True).stdout
    return L.parse_native(out)


def measure_wasm(budgets: dict) -> dict:
    import ludens_wasm_rt

    s = budgets["scene"]
    OUT.mkdir(parents=True, exist_ok=True)
    job = OUT / "job.json"
    script = [{"tick": 0, "hold": s["hold"]}] + [{"tick": t, "press": "Space"} for t in range(10, s["frames"], s["jump_every"])]
    job.write_text(json.dumps({"ticks": s["frames"], "seed": s["seed"], "scene": s["name"], "script": script}))
    d = ROOT / "build/deps"
    r = subprocess.run(["node", "--experimental-strip-types", "--no-warnings", str(ROOT / "scripts/frame_stats_node.mjs"), str(ROOT / "build/app.wasm"),
                        str(ludens_wasm_rt.HOST_MJS), str(d / "wgpu-mojo"), str(d / "miniaudio-mojo"), str(job)],
                       capture_output=True, text=True, check=False)
    if r.returncode:
        sys.exit(r.stdout + r.stderr[-2000:])
    return L.from_node(json.loads(r.stdout.strip().splitlines()[-1]))


def merge(native: dict, wasm: dict | None) -> dict:
    """The numbers `check` reads, and the cross-check findings (a counter both runs report must be equal)."""
    counters = {n: native["counters"][n]["max"] for n in NATIVE_COUNTERS}
    mismatch = []
    for n in SHARED_COUNTERS:
        counters[n] = native["counters"][n]["max"]
        if wasm is not None:
            if wasm["counters"][n]["max"] != counters[n]:
                mismatch.append(f"counter `{n}`: native {counters[n]}, wasm64 {wasm['counters'][n]['max']}")
            counters[n] = max(counters[n], wasm["counters"][n]["max"])
    ms = {n: v["p95"] / 1e6 for n, v in native["stats"].items() if v["count"] > 0}
    if wasm is not None:
        for n in ("audio", "net"):  # only the wasm64 build has them
            if wasm["stats"][n]["count"] > 0:
                ms[n] = wasm["stats"][n]["p95"] / 1e6
    return {"counters": counters, "ms": ms, "mismatch": mismatch}


def table(budgets: dict, native: dict, wasm: dict | None, measured: dict) -> str:
    rows = ["| counter | max over 300 frames | budget | |", "|---|---:|---:|---|"]
    for n in L.COUNTERS:
        lim = budgets["counters"].get(n)
        v = measured["counters"][n]
        rows.append(f"| {n} | {v:,} | {'-' if lim is None else f'{lim:,}'} | {'' if lim is None else ('OVER' if v > lim else 'ok')} |")
    rows += ["", "| segment | avg | p50 | p95 | p99 | max (ms) | p95 budget | |", "|---|---:|---:|---:|---:|---:|---:|---|"]
    for src, st in (("native", native["stats"]), ("wasm64", wasm["stats"] if wasm else {})):
        for n in L.SEGMENTS:
            v = st.get(n)
            if not v or v["count"] == 0 or (src == "wasm64" and n not in ("net", "step", "physics", "ai", "audio", "frame")) or (src == "native" and n in ("net", "audio")):
                continue
            lim = budgets["frame_ms"].get(n) if src == "native" or n in ("net", "audio") else None
            p95 = v["p95"] / 1e6
            mark = "" if lim is None else ("WARN" if p95 > lim else "ok")
            rows.append(f"| {n} ({src}) | {v['avg'] / 1e6:.3f} | {v['p50'] / 1e6:.3f} | {p95:.3f} | {v['p99'] / 1e6:.3f} | {v['max'] / 1e6:.3f} | {'-' if lim is None else lim} | {mark} |")
    return "\n".join(rows)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--budgets", type=Path, default=ROOT / "budgets.toml")
    ap.add_argument("--runs", type=int, default=1, help="repeat the native run; the counters are checked on every run, the p95 on the median run")
    ap.add_argument("--spread", action="store_true", help="print min / median / max of each p95 over --runs")
    ap.add_argument("--no-wasm", action="store_true", help="skip the node run (bodies, particles, AI agents are then the native run's)")
    a = ap.parse_args(argv)
    try:
        budgets = load_budgets(a.budgets)
    except BudgetError as e:
        print(f"perf-gate: {e}", file=sys.stderr)
        return 2
    runs = [measure_native(budgets) for _ in range(max(a.runs, 1))]
    wasm = None if a.no_wasm else measure_wasm(budgets)
    failures: list[str] = []
    warnings: list[str] = []
    mismatch: list[str] = []
    for i, nat in enumerate(runs):
        m = merge(nat, wasm)
        f, _ = check(budgets, m)
        failures += [f"run {i + 1}: {x}" for x in f]
        mismatch += m["mismatch"]
    failures += unique(mismatch)
    mid = sorted(runs, key=lambda r: r["stats"]["frame"]["p95"])[len(runs) // 2]
    measured = merge(mid, wasm)
    _, warnings = check(budgets, measured)
    OUT.mkdir(parents=True, exist_ok=True)
    import frame_trace

    (OUT / "trace.json").write_text(json.dumps(frame_trace.to_chrome(mid["ring"])))
    report = table(budgets, mid, wasm, measured)
    print(f"## perf-gate: scene `{budgets['scene']['name']}` seed {budgets['scene']['seed']}, {budgets['scene']['frames']} frames at "
          f"{budgets['scene']['width']}x{budgets['scene']['height']}, {len(runs)} native run(s); GPU timing: {'present' if mid['gpu_timing'] else 'absent'}\n")
    print(report)
    if a.spread and len(runs) > 1:
        print("\n| p95 over runs (ms) | min | median | max | max / min |\n|---|---:|---:|---:|---:|")
        for n in L.SEGMENTS:
            xs = [r["stats"][n]["p95"] / 1e6 for r in runs if r["stats"][n]["count"] > 0]
            if xs:
                print(f"| {n} | {min(xs):.3f} | {statistics.median(xs):.3f} | {max(xs):.3f} | {max(xs) / max(min(xs), 1e-9):.2f} |")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as fh:
            fh.write(f"### perf-gate\n\n{report}\n")
    for w in warnings:
        print(f"::warning title=perf-gate::{w}" if os.environ.get("GITHUB_ACTIONS") else f"WARNING: {w}")
    for f in failures:
        print(f"::error title=perf-gate::{f}" if os.environ.get("GITHUB_ACTIONS") else f"FAIL: {f}")
    print(f"\nperf-gate: {'FAILED' if failures else 'ok'} ({len(failures)} counter failure(s), {len(warnings)} warning(s))")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
