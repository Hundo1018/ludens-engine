#!/usr/bin/env python3
"""Native hot-reload experiment runner (pure Mojo, host = this machine).

  build   precompile the engine packages it needs, build every engine variant
          (text edits of engine.mojo -> `mojo build --emit shared-lib`) and host.mojo
  test    variant x strategy matrix, one host process per cell, vs a float32
          oracle; PREDICTED below was written before the first run
  bench   repeated swaps per strategy + rebuild time of the engine .so
  r1      edits to heap, trait, comptime and ABI state; an empty state;
          1000 swaps checked for leaks
  all     build + test + bench (default)

    python3 experiments/hot_reload/native/run_native.py [build|test|bench|all] [--reps N]

Needs `mojo` on PATH (pixi env, or `pip install mojo==1.1.0` into .venv).
"""
from __future__ import annotations

import argparse
import json
import re
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

# name -> ([(old, new) or (old, new, "all") text edits], oracle facts)
V1 = {"speed": 60.0, "color": 0xFF0000FF, "label": "ludens: engine v1",
      "gain": 1, "damping": 0, "extra": 0}  # bodies: x += v * gain - damping + extra
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
    # H3: schema migration
    "v7_delete": ([("    var capacity: Int\n", ""), ("        self.capacity = capacity\n", "")], V1),
    "v8_rename": ([("box_x", "offset_x", "all")], V1),
    "v8_rule": ([("box_x", "offset_x", "all"),
                 ("    # @@MIGRATE@@", '    alias_field(sch, "offset_x", "box_x")')], V1),
    # R1: edits to the heap, trait, comptime and ABI parts of the state
    "m1_elem": ([("comptime TRAIL_T = Int\n", "comptime TRAIL_T = Int32\n")], V1),
    "m2_nested": ([("    # @@BODY_FRONT@@", "    var mass: Int"),
                   ("        # @@BODY_INIT@@", "        self.mass = 0")], V1),
    "c1_comptime_n": ([("comptime GRID_N = 4\n", "comptime GRID_N = 8\n")], V1),
    "t1_impl": ([("        # @@ADVANCE@@\n        return x + v * self.gain + self.bias + self.extra()",
                  "        return x + v * self.gain * 2 + self.bias + self.extra()")], {**V1, "gain": 2}),
    "t2_swap_type": ([("comptime ActiveMover = Linear\n", "comptime ActiveMover = Damped\n")],
                     {**V1, "damping": 1}),
    "t3_default": ([("        # @@EXTRA@@\n        return 0", "        return 1")], {**V1, "extra": 1}),
    "s1_retype": ([("    var box_x: Float32", "    var box_x: Float64"),
                   ("s.box_x += s.speed() * dt", "s.box_x += Float64(s.speed() * dt)"),
                   ("return s.core.box_x + s.entities.value_at(i)",
                    "return Float32(s.core.box_x) + s.entities.value_at(i)")], V1),
    "a1_abi": ([('def engine_update(addr: Int, dt: Float32) abi("C"):\n',
                 'def engine_update(addr: Int, dt64: Float64) abi("C"):\n    var dt = Float32(dt64)\n')], V1),
}
# Edits that must NOT build: the compile-time rule of nostatic.mojo (H2).
REJECTED = {
    "x_static_field": ([("    # @@FIELDS_BACK@@", "    var note: StaticString"),
                        ("        # @@INIT_BACK@@", '        self.note = "dangles after unload"')],
                       "state field holds a pointer or string view: note"),
}
STRATEGIES = ["restart", "keep", "close", "snapshot", "auto", "samepath"]

# state: ok | lost | stale-code | corrupt | trap | rejected (engine_load refused the snapshot)
# label: new | old | none | trap | - ; `new` also requires the new variant's label text
_PHASE1 = ["v2_code", "v3_label", "v4_layout", "v5_swap", "v6_append"]
_ALL = _PHASE1 + ["v7_delete", "v8_rename", "v8_rule"]

# Phase 1 (label = StaticString into the .so), written before its first run.
# All 35 cells matched; kept as the record. Not run any more: H2 removed the
# label pointer and `engine_rebind`.
PREDICTED_PHASE1 = {
    "restart":  {v: "lost/new" for v in _PHASE1},
    "keep":     {"v2_code": "ok/old", "v3_label": "ok/old", "v4_layout": "corrupt|trap",
                 "v5_swap": "corrupt/old", "v6_append": "ok/old"},
    "close":    {"v2_code": "ok/trap", "v3_label": "ok/trap", "v4_layout": "corrupt|trap",
                 "v5_swap": "corrupt/trap", "v6_append": "ok/trap"},
    "rebind":   {"v2_code": "ok/new", "v3_label": "ok/new", "v4_layout": "corrupt|trap",
                 "v5_swap": "corrupt/new", "v6_append": "ok/new"},
    "snapshot": {v: "ok/new" for v in _PHASE1},
    "auto":     {v: "ok/new" for v in _PHASE1},
    "samepath": {v: "stale-code/old" for v in _PHASE1},
}

# H2 (label = index, text looked up in the running code), written 2026-09-30
# before the first H2 run. Changes from phase 1: keep and close read the label
# from the new code (old/trap -> new); rebind no longer exists (it equals close).
PREDICTED = {
    "restart":  {v: "lost/new" for v in _PHASE1},
    "keep":     {"v2_code": "ok/new", "v3_label": "ok/new", "v4_layout": "corrupt|trap",
                 "v5_swap": "corrupt/new", "v6_append": "ok/new"},
    "close":    {"v2_code": "ok/new", "v3_label": "ok/new", "v4_layout": "corrupt|trap",
                 "v5_swap": "corrupt/new", "v6_append": "ok/new"},
    "snapshot": {v: "ok/new" for v in _PHASE1},
    "auto":     {v: "ok/new" for v in _PHASE1},
    "samepath": {v: "stale-code/old" for v in _PHASE1},
}
PREDICTED_USED = {"auto": {"v2_code": "inplace", "v3_label": "inplace", "v4_layout": "snapshot",
                           "v5_swap": "snapshot", "v6_append": "snapshot"}}

# H3 (snapshot = ecs/schema.mojo, migration by field name), written 2026-09-30
# before the first H3 run. The phase 1 / H2 columns are predicted unchanged.
# v7 deletes the FIRST Core field, so in place the new code misreads frame.
# v8 renames box_x: same offsets, so in place it is fine; the layout id hashes
# field names, so auto takes the snapshot path, where a rename without a rule
# must be refused (dropped + defaulted in one load), not silently zeroed.
PREDICTED_H3 = {
    "restart":  {"v7_delete": "lost/new", "v8_rename": "lost/new", "v8_rule": "lost/new"},
    "keep":     {"v7_delete": "corrupt|trap", "v8_rename": "ok/new", "v8_rule": "ok/new"},
    "close":    {"v7_delete": "corrupt|trap", "v8_rename": "ok/new", "v8_rule": "ok/new"},
    "snapshot": {"v7_delete": "ok/new", "v8_rename": "rejected/-", "v8_rule": "ok/new"},
    "auto":     {"v7_delete": "ok/new", "v8_rename": "rejected/-", "v8_rule": "ok/new"},
    "samepath": {v: "stale-code/old" for v in ["v7_delete", "v8_rename", "v8_rule"]},
}
for _s, _cells in PREDICTED_H3.items():
    PREDICTED[_s].update(_cells)
PREDICTED_USED["auto"].update({"v7_delete": "snapshot", "v8_rename": "snapshot", "v8_rule": "snapshot"})


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
    for old, new, *mode in edits:
        if old not in src:
            raise SystemExit(f"edit anchor not found in engine.mojo: {old!r}")
        src = src.replace(old, new) if mode == ["all"] else src.replace(old, new, 1)
    return src


def build_variant(name: str, src: str) -> float:
    """Build one engine .so; returns the wall time of `mojo build`, seconds."""
    d = OUT / name
    d.mkdir(parents=True, exist_ok=True)
    (d / "engine.mojo").write_text(src)
    t0 = time.perf_counter()
    sh([mojo(), "build", "--emit", "shared-lib", "-I", "build", "-I", str(HERE), str(d / "engine.mojo"),
        "-o", str(d / "libengine.so")],
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


def simulate(schedule: list[dict], despawn: list[int], color: int) -> dict:
    """The engine in Python. `schedule` = the facts of the code running each
    frame; entities in `despawn` are removed after PRE frames. Sparse set
    with swap-remove, entity value = e*24, box_x in float32; R1: trail of
    frame numbers, grid[frame % 4] += 1, 4 bodies x += v * gain - damping + extra."""
    dense = list(range(CAPACITY))
    values = {e: f32(e * 24.0) for e in dense}
    dt = f32(1.0 / 60.0)
    x, frame = 0.0, 0
    trail: list[int] = []
    grid = 0
    bodies = [[100 * i, i + 1] for i in range(4)]
    for n, facts in enumerate(schedule):
        if n == PRE:
            for e in despawn:
                i = dense.index(e)
                dense[i] = dense[-1]
                dense.pop()
        x = f32(x + f32(f32(facts["speed"]) * dt))
        frame += 1
        trail.append(frame)
        grid += 1
        for b in bodies:
            b[0] = b[0] + b[1] * facts["gain"] - facts["damping"] + facts["extra"]
    return {"count": len(dense), "frame": frame, "color": color, "keys": dense,
            "xbits": [f32_bits(f32(x + values[e])) for e in dense],
            "trail_len": len(trail), "trail_sum": sum(trail), "grid_sum": grid,
            "bodies": [b[0] for b in bodies]}


def oracle(v_old: dict, v_new: dict, despawn: list[int] | None = None) -> dict:
    return simulate([v_old] * (PRE + MID) + [v_new] * POST, DESPAWN if despawn is None else despawn,
                    v_new["color"])


# ---- matrix -----------------------------------------------------------------------

def run_cell(old: str, new: str, strategy: str, cell_dir: Path, extra: list[str] | None = None,
             timeout: int = 60) -> dict:
    """Run host in a fresh process on private copies of the two .so files."""
    if cell_dir.exists():
        shutil.rmtree(cell_dir)
    cell_dir.mkdir(parents=True)
    a, b = cell_dir / "old.so", cell_dir / "new.so"
    shutil.copy(OUT / old / "libengine.so", a)
    shutil.copy(OUT / new / "libengine.so", b)
    p = subprocess.run([str(OUT / "host"), str(a), str(b), strategy, *(extra or [])],
                       cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    kv = dict(line.split("=", 1) for line in p.stdout.splitlines() if "=" in line)
    kv["returncode"] = p.returncode
    return kv


def ints(csv: str) -> list[int]:
    return [int(t) for t in csv.split(",") if t]


def classify(kv: dict, v_old: dict, v_new: dict, despawn: list[int] | None = None) -> tuple[str, str]:
    """state from behaviour + which module's code ran (code_owner);
    label from where the state's label pointer points (label_owner),
    `trap` when reading it crashed the process."""
    if kv.get("load") == "rejected":
        return "rejected", "-"
    if "bodies" not in kv:
        state = "trap"
    else:
        got = {"count": int(kv["count"]), "frame": int(kv["frame"]), "color": int(kv["color"]),
               "keys": ints(kv["keys"]), "xbits": ints(kv["xbits"]),
               "trail_len": int(kv["trail_len"]), "trail_sum": int(kv["trail_sum"]),
               "grid_sum": int(kv["grid_sum"]), "bodies": ints(kv["bodies"])}
        code = kv.get("code_owner")
        if code == "new" and got == oracle(v_old, v_new, despawn):
            state = "ok"
        elif code == "old" and got == oracle(v_old, v_old, despawn):
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
    elif owner == "new" and kv["label"] != v_new["label"]:
        label = "new-wrong-text"
    else:
        label = owner
    return state, label


def matches(pred: str, state: str, label: str) -> bool:
    if "|" in pred:  # a set of acceptable states, label not predicted
        return state in pred.split("|")
    return pred == f"{state}/{label}"


def check_rejected() -> int:
    """Each REJECTED edit must fail `mojo build` with its expected message."""
    failures = 0
    for name, (edits, needle) in REJECTED.items():
        d = OUT / name
        d.mkdir(parents=True, exist_ok=True)
        (d / "engine.mojo").write_text(variant_source(edits))
        p = subprocess.run([mojo(), "build", "--emit", "shared-lib", "-I", "build", "-I", str(HERE),
                            str(d / "engine.mojo"), "-o", str(d / "libengine.so")],
                           cwd=ROOT, capture_output=True, text=True)
        hit = p.returncode != 0 and needle in p.stderr
        failures += not hit
        print(f"{'PASS' if hit else 'FAIL':<6}build rejected  {name:<16} rc={p.returncode}  expects {needle!r}")
    return failures


def test() -> int:
    facts = {name: meta for name, (_, meta) in VARIANTS.items()}
    cells, failures = [], check_rejected()
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
                          "hit": hit, **{k: kv.get(k) for k in ("used", "load_code", "swap_us", "old_mapped", "returncode",
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


# ---- R1: edits to heap, trait, comptime and ABI state ---------------------------

R1_VARIANTS = ["m1_elem", "m2_nested", "c1_comptime_n", "t1_impl", "t2_swap_type", "t3_default",
               "s1_retype", "a1_abi"]
# Written before the first R1 run. Reasoning:
# - the layout id sees a List's own fields but not its element type, so a
#   field added to Body (m2) keeps the id and auto swaps in place;
# - a changed element type (m1), Array length (c1) or field type (s1) is a
#   retype, which the snapshot load refuses;
# - trait and trait-default code (t1, t3) behave like any code-only edit;
# - nothing checks export signatures (a1), so every path running new code is wrong.
_BREAKS = "corrupt|trap"
_INPLACE_R1 = {"m1_elem": _BREAKS, "m2_nested": _BREAKS, "c1_comptime_n": _BREAKS, "t1_impl": "ok/new",
               "t2_swap_type": _BREAKS, "t3_default": "ok/new", "s1_retype": _BREAKS, "a1_abi": "corrupt/new"}
PREDICTED_R1 = {
    "restart": {v: "lost/new" for v in R1_VARIANTS},
    "keep": _INPLACE_R1,
    "close": _INPLACE_R1,
    "snapshot": {"m1_elem": "rejected/-", "m2_nested": "ok/new", "c1_comptime_n": "rejected/-",
                 "t1_impl": "ok/new", "t2_swap_type": "ok/new", "t3_default": "ok/new",
                 "s1_retype": "rejected/-", "a1_abi": "corrupt/new"},
    "auto": {"m1_elem": "rejected/-", "m2_nested": _BREAKS, "c1_comptime_n": "rejected/-",
             "t1_impl": "ok/new", "t2_swap_type": "ok/new", "t3_default": "ok/new",
             "s1_retype": "rejected/-", "a1_abi": "corrupt/new"},
    "samepath": {v: "stale-code/old" for v in R1_VARIANTS},
}
PREDICTED_USED_R1 = {"auto": {"m1_elem": "snapshot", "m2_nested": "inplace", "c1_comptime_n": "snapshot",
                              "t1_impl": "inplace", "t2_swap_type": "snapshot", "t3_default": "inplace",
                              "s1_retype": "snapshot", "a1_abi": "inplace"}}
# Every entity despawned before the swap: same verdicts as with entities.
PREDICTED_EMPTY = {("close", "v2_code"): "ok/new", ("snapshot", "v2_code"): "ok/new",
                   ("auto", "v2_code"): "ok/new", ("close", "v4_layout"): _BREAKS,
                   ("snapshot", "v4_layout"): "ok/new", ("auto", "v4_layout"): "ok/new"}
REPEAT_SHORT, REPEAT_LONG = 100, 1000
SHIM = OUT / "kgen_alloc_count.so"


def run_counted(strategy: str, k: int) -> dict:
    """`host repeat k` (v1 <-> v2_code) under probes/kgen_alloc_count.c: the
    returned dict also has the Mojo allocations still live at exit."""
    subprocess.run(["cc", "-O2", "-shared", "-fPIC", "-o", str(SHIM), str(HERE / "probes" / "kgen_alloc_count.c"),
                    "-ldl"], check=True)
    cell = OUT / "cells_r1" / f"repeat-{strategy}-{k}"
    if cell.exists():
        shutil.rmtree(cell)
    cell.mkdir(parents=True)
    a, b = cell / "old.so", cell / "new.so"
    shutil.copy(OUT / "v1" / "libengine.so", a)
    shutil.copy(OUT / "v2_code" / "libengine.so", b)
    p = subprocess.run([str(OUT / "host"), str(a), str(b), strategy, "repeat", str(k)], cwd=ROOT,
                       capture_output=True, text=True, timeout=600,
                       env={"LD_PRELOAD": str(SHIM), "PATH": "/usr/bin:/bin"})
    kv = dict(line.split("=", 1) for line in p.stdout.splitlines() if "=" in line)
    m = re.search(r"kgen_alloc live_count=(-?\d+) live_bytes=(-?\d+)", p.stderr)
    kv["returncode"] = p.returncode
    kv["live_bytes"] = int(m[2]) if m else None
    return kv


def observed(kv: dict) -> dict:
    return {"count": int(kv["count"]), "frame": int(kv["frame"]), "color": int(kv["color"]),
            "keys": ints(kv["keys"]), "xbits": ints(kv["xbits"]), "trail_len": int(kv["trail_len"]),
            "trail_sum": int(kv["trail_sum"]), "grid_sum": int(kv["grid_sum"]), "bodies": ints(kv["bodies"])}


def test_r1() -> int:
    facts = {name: meta for name, (_, meta) in VARIANTS.items()}
    rows, failures = [], 0

    def record(kind: str, s: str, v: str, kv: dict, seen: str, pred: str, hit: bool) -> None:
        nonlocal failures
        failures += not hit
        rows.append({"kind": kind, "strategy": s, "variant": v, "observed": seen, "predicted": pred, "hit": hit,
                     **{k: kv.get(k) for k in ("used", "load_code", "returncode")}})
        print(f"{'PASS' if hit else 'FAIL':<6}{kind:<7}{s:<10}{v:<15}{seen:<24}{pred:<24}{kv.get('used', '-')}")

    for s in STRATEGIES:
        for v in R1_VARIANTS:
            kv = run_cell("v1", v, s, OUT / "cells_r1" / f"{s}-{v}")
            state, label = classify(kv, facts["v1"], facts[v])
            pred = PREDICTED_R1[s][v]
            want_used = PREDICTED_USED_R1.get(s, {}).get(v)
            hit = matches(pred, state, label) and (want_used is None or kv.get("used") == want_used)
            record("edit", s, v, kv, f"{state}/{label}", pred, hit)

    for (s, v), pred in PREDICTED_EMPTY.items():
        kv = run_cell("v1", v, s, OUT / "cells_r1" / f"empty-{s}-{v}", ["empty"])
        state, label = classify(kv, facts["v1"], facts[v], despawn=list(range(CAPACITY)))
        record("empty", s, v, kv, f"{state}/{label}", pred, matches(pred, state, label))

    # REPEAT_LONG swaps: the state follows the oracle, the idle module is
    # unmapped, and the live Mojo allocations at exit equal those after
    # REPEAT_SHORT swaps (VmRSS cannot show this: TCMalloc keeps freed memory).
    k = REPEAT_LONG
    last = facts["v2_code"] if k % 2 else facts["v1"]
    sched = [facts["v1"]] * (PRE + MID) + [facts["v2_code"] if i % 2 else facts["v1"] for i in range(1, k + 1)]
    want = simulate(sched + [last] * POST, DESPAWN, last["color"])
    for s in ("close", "snapshot"):
        short, kv = run_counted(s, REPEAT_SHORT), run_counted(s, k)
        state_ok = "bodies" in kv and observed(kv) == want
        leak = None if None in (kv["live_bytes"], short["live_bytes"]) else kv["live_bytes"] - short["live_bytes"]
        hit = state_ok and kv.get("idle_mapped") == "0" and leak == 0
        record("repeat", s, f"x{k}", kv, f"{'ok' if state_ok else 'bad'} map={kv.get('idle_mapped')} leak={leak}B",
               "ok map=0 leak=0B", hit)

    (OUT / "r1.json").write_text(json.dumps(rows, indent=2))
    print(f"{'FAIL' if failures else 'PASS'}  R1: {len(rows) - failures}/{len(rows)} match the predictions")
    return 1 if failures else 0


# ---- bench ------------------------------------------------------------------------

def bench(reps: int) -> None:
    rows = {}
    for s in ["restart", "close", "snapshot"]:
        us = [float(run_cell("v1", "v2_code", s, OUT / "bench_cell")["swap_us"]) for _ in range(reps)]
        rows[s] = {"median_us": statistics.median(us), "p95_us": sorted(us)[int(0.95 * (len(us) - 1))],
                   "max_us": max(us)}
    rebuild = []
    salt = time.time_ns() % 100000  # a SPEED never built before: mojo caches builds per (path, code)
    for r in range(max(3, reps // 10)):
        src = variant_source(VARIANTS["v2_code"][0]).replace(
            "comptime SPEED: Float32 = 120.0", f"comptime SPEED: Float32 = {salt + r}.25")
        rebuild.append(build_variant("bench_rebuild", src))
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
    ap.add_argument("step", nargs="?", default="all", choices=["build", "test", "bench", "r1", "all"])
    ap.add_argument("--reps", type=int, default=50)
    a = ap.parse_args()
    if a.step in ("build", "all") or not (OUT / "host").exists():
        build()
    rc = 0
    if a.step in ("test", "all"):
        rc = test()
    if a.step in ("r1", "all"):
        rc |= test_r1()
    if a.step in ("bench", "all"):
        bench(a.reps)
    return rc


if __name__ == "__main__":
    sys.exit(main())
