#!/usr/bin/env python3
"""Native hot-reload experiment runner (pure Mojo, host = this machine).

  build   precompile the engine packages it needs, build every engine variant
          (text edits of engine.mojo -> `mojo build --emit shared-lib`) and host.mojo
  test    variant x strategy matrix, one host process per cell, vs a float32
          oracle; PREDICTED below was written before the first run
  bench   repeated swaps per strategy + rebuild time of the engine .so
  all     build + test + bench (default)

    python3 experiments/hot_reload/native/run_native.py [build|test|bench|all] [--reps N]

Needs `mojo` on PATH (pixi env, or `pip install mojo==1.1.0` into .venv).
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import statistics
import struct
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = ROOT / "build" / "hot_native"
ENGINE = HERE / "engine.mojo"
PACKAGES = ["diag", "geometry", "ecs"]  # what engine.mojo imports, in dependency order

CAPACITY, PRE, MID, POST = 8, 30, 10, 30
DESPAWN = [2, 5]

# name -> ([(old, new) text edits], oracle facts)
V1 = {"speed": 60.0, "color": 0xFF0000FF, "label": "ludens: engine v1"}
VARIANTS = {
    "v1": ([], V1),
    "v2_code": ([("comptime SPEED: Float32 = 60.0", "comptime SPEED: Float32 = 120.0"),
                 ("comptime COLOR: UInt32 = 0xFF0000FF", "comptime COLOR: UInt32 = 0x00FF00FF")],
                {**V1, "speed": 120.0, "color": 0x00FF00FF}),
    "v3_label": ([('"ludens: engine v1"', '"ludens: engine v3"')], {**V1, "label": "ludens: engine v3"}),
    "v4_layout": ([("    # @@FIELDS_FRONT@@", "    var speed_scale: Float32"),
                   ("        # @@INIT_FRONT@@", "        self.speed_scale = 1.0"),
                   ("        # @@SPEED@@\n        return SPEED", "        return SPEED * self.speed_scale")], V1),
    "v5_swap": ([("    var capacity: Int\n    var frame: Int", "    var frame: Int\n    var capacity: Int")], V1),
    "v6_append": ([("    # @@FIELDS_BACK@@", "    var extra: Int"),
                   ("        # @@INIT_BACK@@", "        self.extra = 0"),
                   ("    # @@UPDATE@@", "    s.extra += 1")], V1),
}
STRATEGIES = ["restart", "keep", "close", "rebind", "snapshot", "auto", "samepath"]

# state: ok | lost | stale-code | corrupt | trap     label: new | old | trap | -
# Written before the first run of the matrix; see README.md for outcomes.
_ALL = ["v2_code", "v3_label", "v4_layout", "v5_swap", "v6_append"]
PREDICTED = {
    "restart":  {v: "lost/new" for v in _ALL},
    "keep":     {"v2_code": "ok/old", "v3_label": "ok/old", "v4_layout": "corrupt|trap",
                 "v5_swap": "corrupt/old", "v6_append": "ok/old"},
    "close":    {"v2_code": "ok/trap", "v3_label": "ok/trap", "v4_layout": "corrupt|trap",
                 "v5_swap": "corrupt/trap", "v6_append": "ok/trap"},
    "rebind":   {"v2_code": "ok/new", "v3_label": "ok/new", "v4_layout": "corrupt|trap",
                 "v5_swap": "corrupt/new", "v6_append": "ok/new"},
    "snapshot": {v: "ok/new" for v in _ALL},
    "auto":     {v: "ok/new" for v in _ALL},
    "samepath": {v: "stale-code/old" for v in _ALL},
}
PREDICTED_USED = {"auto": {"v2_code": "rebind", "v3_label": "rebind", "v4_layout": "snapshot",
                           "v5_swap": "snapshot", "v6_append": "snapshot"}}


def mojo() -> str:
    for cand in (os.environ.get("MOJO"), shutil.which("mojo"), str(ROOT / ".venv" / "bin" / "mojo")):
        if cand and Path(cand).exists():
            return cand
    sys.exit("mojo not found: use the pixi env or `python3 -m venv .venv && .venv/bin/pip install mojo==1.1.0`")


def sh(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    print("+", " ".join(str(c) for c in cmd), flush=True)
    return subprocess.run(cmd, cwd=ROOT, check=True, **kw)


# ---- build ----------------------------------------------------------------------

def precompile() -> None:
    stage = ROOT / "build" / ".stage"
    stage.mkdir(parents=True, exist_ok=True)
    for pkg in PACKAGES:
        sh([mojo(), "precompile", pkg, "-I", "build", "-o", str(stage / f"{pkg}.mojoc")])
        shutil.move(stage / f"{pkg}.mojoc", ROOT / "build" / f"{pkg}.mojoc")


def variant_source(edits: list[tuple[str, str]]) -> str:
    src = ENGINE.read_text()
    for old, new in edits:
        if old not in src:
            raise SystemExit(f"edit anchor not found in engine.mojo: {old!r}")
        src = src.replace(old, new, 1)
    return src


def build_variant(name: str, src: str) -> float:
    """Build one engine .so; returns the wall time of `mojo build`, seconds."""
    d = OUT / name
    d.mkdir(parents=True, exist_ok=True)
    (d / "engine.mojo").write_text(src)
    t0 = time.perf_counter()
    sh([mojo(), "build", "--emit", "shared-lib", "-I", "build", str(d / "engine.mojo"), "-o", str(d / "libengine.so")],
       stdout=subprocess.DEVNULL)
    return time.perf_counter() - t0


def build() -> None:
    precompile()
    times = {name: build_variant(name, variant_source(edits)) for name, (edits, _) in VARIANTS.items()}
    sh([mojo(), "build", "-I", "build", "-I", str(HERE), str(HERE / "host.mojo"), "-o", str(OUT / "host")])
    (OUT / "build_times.json").write_text(json.dumps(times, indent=2))


# ---- oracle -----------------------------------------------------------------------

def f32(x: float) -> float:
    return struct.unpack("<f", struct.pack("<f", x))[0]


def f32_bits(x: float) -> int:
    return struct.unpack("<I", struct.pack("<f", x))[0]


def oracle(v_old: dict, v_new: dict) -> dict:
    """Sparse set with swap-remove, entity value = e*24, box_x in float32."""
    dense = list(range(CAPACITY))
    values = {e: f32(e * 24.0) for e in dense}
    dt = f32(1.0 / 60.0)
    x, frame = 0.0, 0

    def step(speed: float) -> None:
        nonlocal x, frame
        x = f32(x + f32(f32(speed) * dt))
        frame += 1

    for _ in range(PRE):
        step(v_old["speed"])
    for e in DESPAWN:
        i = dense.index(e)
        dense[i] = dense[-1]
        dense.pop()
    for _ in range(MID):
        step(v_old["speed"])
    for _ in range(POST):
        step(v_new["speed"])
    return {"count": len(dense), "frame": frame, "color": v_new["color"], "keys": dense,
            "xbits": [f32_bits(f32(x + values[e])) for e in dense]}


# ---- matrix -----------------------------------------------------------------------

def run_cell(old: str, new: str, strategy: str, cell_dir: Path, extra: list[str] | None = None) -> dict:
    """Run host in a fresh process on private copies of the two .so files."""
    if cell_dir.exists():
        shutil.rmtree(cell_dir)
    cell_dir.mkdir(parents=True)
    a, b = cell_dir / "old.so", cell_dir / "new.so"
    shutil.copy(OUT / old / "libengine.so", a)
    shutil.copy(OUT / new / "libengine.so", b)
    p = subprocess.run([str(OUT / "host"), str(a), str(b), strategy, *(extra or [])],
                       cwd=ROOT, capture_output=True, text=True, timeout=60)
    kv = dict(line.split("=", 1) for line in p.stdout.splitlines() if "=" in line)
    kv["returncode"] = p.returncode
    return kv


def ints(csv: str) -> list[int]:
    return [int(t) for t in csv.split(",") if t]


def classify(kv: dict, v_old: dict, v_new: dict) -> tuple[str, str]:
    """state from behaviour + which module's code ran (code_owner);
    label from where the state's label pointer points (label_owner),
    `trap` when reading it crashed the process."""
    if "xbits" not in kv:
        state = "trap"
    else:
        got = {"count": int(kv["count"]), "frame": int(kv["frame"]), "color": int(kv["color"]),
               "keys": ints(kv["keys"]), "xbits": ints(kv["xbits"])}
        code = kv.get("code_owner")
        if code == "new" and got == oracle(v_old, v_new):
            state = "ok"
        elif code == "old" and got == oracle(v_old, v_old):
            state = "stale-code"
        elif got["count"] == CAPACITY and got["frame"] == POST:
            state = "lost"
        else:
            state = "corrupt"
    owner = kv.get("label_owner")
    if owner is None:
        label = "-"
    elif "label" not in kv:
        label = "trap"
    else:
        label = owner
    return state, label


def matches(pred: str, state: str, label: str) -> bool:
    if "|" in pred:  # a set of acceptable states, label not predicted
        return state in pred.split("|")
    return pred == f"{state}/{label}"


def test() -> int:
    facts = {name: meta for name, (_, meta) in VARIANTS.items()}
    cells, failures = [], 0
    print(f"\n{'':6}{'strategy':<10}{'variant':<11}{'observed':<18}{'predicted':<18}{'used':<9}{'rc':>4}"
          f"  code  label_ptr")
    for s in STRATEGIES:
        for v in _ALL:
            kv = run_cell("v1", v, s, OUT / "cells" / f"{s}-{v}")
            state, label = classify(kv, facts["v1"], facts[v])
            pred = PREDICTED[s][v]
            hit = matches(pred, state, label)
            want_used = PREDICTED_USED.get(s, {}).get(v)
            if want_used and kv.get("used") != want_used:
                hit = False
            failures += not hit
            cells.append({"strategy": s, "variant": v, "state": state, "label": label, "predicted": pred,
                          "hit": hit, **{k: kv.get(k) for k in ("used", "swap_us", "old_mapped", "returncode",
                                                                   "teardown", "frame", "code_owner", "label_owner", "label")}})
            print(f"{'PASS' if hit else 'FAIL':<6}{s:<10}{v:<11}{state + '/' + label:<18}{pred:<18}"
                  f"{kv.get('used', '-'):<9}{kv['returncode']:>4}  {kv.get('code_owner', '-'):<5} {kv.get('label_owner', '-')}")
    (OUT / "matrix.json").write_text(json.dumps(cells, indent=2))
    print(f"wrote {(OUT / 'matrix.json').relative_to(ROOT)}")
    if failures:
        print(f"FAIL  {failures} observation(s) contradict the predictions")
        return 1
    print("PASS  native hot reload: all observations match predictions")
    return 0


# ---- bench ------------------------------------------------------------------------

def bench(reps: int) -> None:
    rows = {}
    for s in ["restart", "rebind", "snapshot"]:
        us = [float(run_cell("v1", "v2_code", s, OUT / "bench_cell")["swap_us"]) for _ in range(reps)]
        rows[s] = {"median_us": statistics.median(us), "p95_us": sorted(us)[int(0.95 * (len(us) - 1))],
                   "max_us": max(us)}
    rebuild = []
    for _ in range(max(3, reps // 10)):
        rebuild.append(build_variant("bench_rebuild", variant_source(VARIANTS["v2_code"][0])))
    summary = {"swap": rows, "rebuild_s": {"median": statistics.median(rebuild), "max": max(rebuild),
                                           "n": len(rebuild)}, "reps": reps}
    (OUT / "bench_summary.json").write_text(json.dumps(summary, indent=2))
    print(f"\nswap (host process, v1 -> v2_code, {reps} reps), microseconds")
    for s, r in rows.items():
        print(f"  {s:<9} median {r['median_us']:9.1f}  p95 {r['p95_us']:9.1f}  max {r['max_us']:9.1f}")
    print(f"engine .so rebuild (mojo build --emit shared-lib): median {summary['rebuild_s']['median']:.2f} s, "
          f"max {summary['rebuild_s']['max']:.2f} s over {len(rebuild)}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("step", nargs="?", default="all", choices=["build", "test", "bench", "all"])
    ap.add_argument("--reps", type=int, default=50)
    a = ap.parse_args()
    if a.step in ("build", "all") or not (OUT / "host").exists():
        build()
    rc = 0
    if a.step in ("test", "all"):
        rc = test()
    if a.step in ("bench", "all"):
        bench(a.reps)
    return rc


if __name__ == "__main__":
    sys.exit(main())
