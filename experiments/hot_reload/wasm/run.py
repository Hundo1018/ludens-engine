#!/usr/bin/env python3
"""Hot-reload experiment runner.

Builds the engine_hot.c variants through the normal retarget back-half
(scripts/emit-and-link.sh), then runs the pieces of the experiment:

  build   compile every variant, write build/hot/manifest.json
  test    variant x strategy matrix vs float32 oracle (hot_reload.test.mjs)
  bench   swap latency + memory-size scaling (bench.mjs), summarised here
  e2e     edit a source file under the dev server, verify the browser swapped
  all     build + test + bench + e2e (default)

    python3 experiments/hot_reload/wasm/run.py [build|test|bench|e2e|all] [--reps N] [--core c|mojo]

--core mojo (W1) builds engine_hot.mojo instead of engine_hot.c: each variant
is a text edit of the Mojo source, compiled with `mojo build --emit llvm`,
retargeted to wasm32 (experiments/wasm_mojo/retarget_ir.py) and linked by the
same back half. Its outputs go to build/hot_mojo/. The e2e step (browser dev
loop) exists only for the C core.
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from layout_map import fingerprint  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
OUT = ROOT / "build" / "hot"
sys.path.insert(0, str(ROOT / "experiments" / "wasm_mojo"))
from retarget_ir import retarget  # noqa: E402

CORE = ["toolchain/standin/sparse_set.c", "toolchain/standin/wasm_rt.c"]
SOURCE = "experiments/hot_reload/wasm/engine_hot.c"
EXPORTS = ["__heap_base", "__data_end"]  # engine_* come from export_name attrs

# name -> (clang -D flags, what the oracle must know about the variant)
VARIANTS = {
    "v1": ([], {"speed": 60.0, "color": 0xFF0000FF, "msg": "ludens: engine_init v1"}),
    "v2_code": (["-DSPEED=120.0f", "-DCOLOR=0x00ff00ffu"],
                {"speed": 120.0, "color": 0x00FF00FF, "msg": "ludens: engine_init v1"}),
    "v3_rodata": (["-DMSG_V3"], {"speed": 60.0, "color": 0xFF0000FF, "msg": "ludens: engine_init v3"}),
    "v4_layout": (["-DLAYOUT_V2"], {"speed": 60.0, "color": 0xFF0000FF, "msg": "ludens: engine_init v1"}),
    "v5_swap": (["-DLAYOUT_SWAP"], {"speed": 60.0, "color": 0xFF0000FF, "msg": "ludens: engine_init v1"}),
    "v6_static": (["-DEXTRA_STATIC"], {"speed": 60.0, "color": 0xFF0000FF, "msg": "ludens: engine_init v1"}),
}


# --core mojo: name -> ([(old, new) text edits of engine_hot.mojo], oracle facts)
MOJO_SOURCE = HERE / "engine_hot.mojo"
MOJO_SHIMS = ["toolchain/standin/wasm_rt.c", "experiments/wasm_mojo/mojo_rt.c",
              "experiments/hot_reload/wasm/engine_hot_rt.c"]
MOJO_EXPORTS = ["__heap_base", "__data_end", "engine_layout_id", "engine_init", "engine_despawn", "engine_update",
                "engine_entity_count", "engine_frame", "engine_log_msg", "engine_save", "engine_load"]
MOJO_V1 = {"speed": 60.0, "color": 0xFF0000FF, "msg": "ludens: engine_init v1"}
MOJO_VARIANTS = {
    "v1": ([], MOJO_V1),
    "v2_code": ([("comptime SPEED: Float32 = 60.0", "comptime SPEED: Float32 = 120.0"),
                 ("comptime COLOR: UInt32 = 0xFF0000FF", "comptime COLOR: UInt32 = 0x00FF00FF")],
                {**MOJO_V1, "speed": 120.0, "color": 0x00FF00FF}),
    "v3_rodata": ([('"ludens: engine_init v1"', '"ludens: engine_init v3"')],
                  {**MOJO_V1, "msg": "ludens: engine_init v3"}),
    "v4_layout": ([("    # @@FIELDS_FRONT@@", "    var speed_scale: Float32"),
                   ("        # @@INIT_FRONT@@", "        self.speed_scale = 1.0"),
                   ("        # @@SPEED@@\n        return SPEED", "        return SPEED * self.speed_scale")], MOJO_V1),
    "v5_swap": ([("    var capacity: Int\n    var frame: Int", "    var frame: Int\n    var capacity: Int")], MOJO_V1),
    "v6_append": ([("    # @@FIELDS_BACK@@", "    var extra: Int"),
                   ("        # @@INIT_BACK@@", "        self.extra = 0"),
                   ("    # @@UPDATE@@", "    g.extra += 1")], MOJO_V1),
}


def mojo() -> str:
    cand = ROOT / ".venv" / "bin" / "mojo"
    return str(cand) if cand.exists() else "mojo"


def mojo_source(edits: list[tuple[str, str]]) -> str:
    src = MOJO_SOURCE.read_text()
    for old, new in edits:
        if old not in src:
            raise SystemExit(f"edit anchor not found in engine_hot.mojo: {old!r}")
        src = src.replace(old, new, 1)
    return src


def build_one_mojo(out: Path, source_text: str) -> dict:
    """Mojo source -> host IR -> wasm32 IR -> the same back half as build_one."""
    out.parent.mkdir(parents=True, exist_ok=True)
    src = out.parent / "engine_hot.mojo"
    src.write_text(source_text)
    host_ll = out.parent / "engine_hot.host.ll"
    sh([mojo(), "build", "--emit", "llvm", "-I", "build", str(src), "-o", str(host_ll)])
    (out.parent / "ir").mkdir(exist_ok=True)
    ir = out.parent / "ir" / "engine_hot.ll"
    retarget(host_ll, ir)
    cmd = ["bash", "scripts/emit-and-link.sh", "--out", str(out)]
    for e in MOJO_EXPORTS:
        cmd += ["--export", e]
    link_map = out.with_suffix(".map")
    sh(cmd + MOJO_SHIMS + [str(ir)], env={"LDFLAGS": f"--Map={link_map}"})
    layout = fingerprint(link_map)
    out.with_suffix(".layout.json").write_text(json.dumps(layout, indent=2))
    return layout


def build_mojo() -> Path:
    out_root = ROOT / "build" / "hot_mojo"
    manifest = {"core": "mojo", "variants": []}
    for name, (edits, meta) in MOJO_VARIANTS.items():
        wasm = out_root / name / "engine_hot.wasm"
        layout = build_one_mojo(wasm, mojo_source(edits))
        entry = {"name": name, "wasm": str(wasm.relative_to(ROOT)), "edits": edits,
                 "mapFingerprint": layout["mapFingerprint"], **meta}
        if name == "v1":
            manifest["base"] = entry
        else:
            manifest["variants"].append(entry)
    path = out_root / "manifest.json"
    path.write_text(json.dumps(manifest, indent=2))
    print(f"wrote {path.relative_to(ROOT)}")
    return path


def sh(cmd: list[str], env: dict | None = None) -> None:
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, cwd=ROOT, check=True, env={**os.environ, **(env or {})})


def build_one(out: Path, cflags: list[str], source: str = SOURCE) -> dict:
    """Build one variant; write <out>.layout.json (link-map fingerprint) beside it."""
    cmd = ["bash", "scripts/emit-and-link.sh", "--out", str(out)]
    for e in EXPORTS:
        cmd += ["--export", e]
    link_map = out.with_suffix(".map")
    sh(cmd + CORE + [source], env={"CFLAGS": " ".join(cflags), "LDFLAGS": f"--Map={link_map}"})
    layout = fingerprint(link_map)
    out.with_suffix(".layout.json").write_text(json.dumps(layout, indent=2))
    return layout


def build() -> Path:
    manifest = {"variants": []}
    for name, (cflags, meta) in VARIANTS.items():
        wasm = OUT / name / "engine_hot.wasm"
        layout = build_one(wasm, cflags)
        entry = {"name": name, "wasm": str(wasm.relative_to(ROOT)), "cflags": cflags,
                 "mapFingerprint": layout["mapFingerprint"], **meta}
        if name == "v1":
            manifest["base"] = entry
        else:
            manifest["variants"].append(entry)
    path = OUT / "manifest.json"
    path.write_text(json.dumps(manifest, indent=2))
    print(f"wrote {path.relative_to(ROOT)}")
    return path


def test(out: Path = OUT) -> None:
    rel = out.relative_to(ROOT)
    sh(["node", "experiments/hot_reload/wasm/hot_reload.test.mjs", f"{rel}/manifest.json", f"{rel}/matrix.json"])


def pct(xs: list[float], q: float) -> float:
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))]


def bench(reps: int, root: Path = OUT) -> None:
    out = root / "bench.json"
    sh(["node", "experiments/hot_reload/wasm/bench.mjs", str(root / "manifest.json"), str(out), str(reps)])
    data = json.loads(out.read_text())

    print(f"\nswap latency, {reps} reps, v1 -> v2_code, ms")
    print(f"{'strategy':<12}{'phase':<13}{'median':>9}{'p95':>9}{'max':>9}")
    for strat, phases in data["swap"].items():
        for phase, xs in phases.items():
            print(f"{strat:<12}{phase:<13}{statistics.median(xs):>9.3f}{pct(xs, .95):>9.3f}{max(xs):>9.3f}")

    print("\ntransfer cost vs live memory size (median ms)")
    print(f"{'MiB':>6}{'memcopy':>11}{'memcopy-rw':>12}{'snapshot':>10}")
    for row in data["scaling"]:
        print(f"{row['mib']:>6}{statistics.median(row['memcopy']):>11.3f}"
              f"{statistics.median(row['memcopy-rw']):>12.3f}{statistics.median(row['snapshot']):>10.3f}")

    summary = {
        "swap": {s: {p: {"median": statistics.median(xs), "p95": pct(xs, .95), "max": max(xs)}
                     for p, xs in ph.items()} for s, ph in data["swap"].items()},
        "scaling": [{"mib": r["mib"], **{k: statistics.median(r[k]) for k in ("memcopy", "memcopy-rw", "snapshot")}}
                    for r in data["scaling"]],
        "env": data["env"],
    }
    (root / "bench_summary.json").write_text(json.dumps(summary, indent=2))
    print(f"wrote {(root / 'bench_summary.json').relative_to(ROOT)}")


def e2e() -> None:
    sh([sys.executable, "experiments/hot_reload/wasm/e2e.py"])


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("step", nargs="?", default="all", choices=["build", "test", "bench", "e2e", "all"])
    ap.add_argument("--reps", type=int, default=200)
    ap.add_argument("--core", default="c", choices=["c", "mojo"])
    a = ap.parse_args()
    if a.core == "mojo":
        root = ROOT / "build" / "hot_mojo"
        if a.step in ("build", "all") or not (root / "manifest.json").exists():
            build_mojo()
        if a.step in ("test", "all"):
            test(root)
        if a.step in ("bench", "all"):
            bench(a.reps, root)
        return
    if a.step in ("build", "all") or not (OUT / "manifest.json").exists():
        build()
    if a.step in ("test", "all"):
        test()
    if a.step in ("bench", "all"):
        bench(a.reps)
    if a.step in ("e2e", "all"):
        e2e()


if __name__ == "__main__":
    main()
