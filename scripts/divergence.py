#!/usr/bin/env python3
"""Per-tick hash traces of the game under node, and the first tick where two traces differ (ludens-engine #115).

    pixi run -e wasm python3 scripts/divergence.py record job.json -o a.jsonl
    pixi run -e wasm python3 scripts/divergence.py diff a.jsonl b.jsonl      # exit 1 and print the first differing tick

`record` runs build/app.wasm through the `window.game` hook (scripts/game_run.mjs, no WebGPU, no drawing) and writes one JSON
line per tick: {"tick": N, "hash": "...", "state": {...}}. Tick 0 is the state before the first step, tick N the state after N
steps. The job file is described at the top of scripts/game_run.mjs: ticks, seed, scene, and a key script.

`diff` prints the first tick whose hashes differ and every state key that differs at that tick (nested keys by path, e.g.
`ball.pos[1]`), with both values. A trace that ends earlier than the other is reported as a length difference."""
import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEPS = ROOT / "build/deps"


def run_trace(job: dict) -> list[dict]:
    """Run `job` under node against build/app.wasm and return the trace lines (build the module first: `pixi run -e wasm build-wasm`)."""
    import ludens_wasm_rt
    wasm = ROOT / "build/app.wasm"
    if not wasm.exists():
        sys.exit(f"divergence: {wasm} is missing; run `pixi run -e wasm build-wasm`")
    with tempfile.TemporaryDirectory() as t:
        jobfile = Path(t) / "job.json"
        jobfile.write_text(json.dumps(job), encoding="utf-8")
        cmd = ["node", "--experimental-strip-types", "--no-warnings", str(ROOT / "scripts/game_run.mjs"), str(wasm),
               str(ludens_wasm_rt.HOST_MJS), str(DEPS / "wgpu-mojo"), str(DEPS / "miniaudio-mojo"), str(jobfile)]
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode:
        sys.exit("divergence: game_run.mjs failed\n" + proc.stdout[-1000:] + proc.stderr[-3000:])
    return [json.loads(l) for l in proc.stdout.splitlines() if l]


def read_trace(path: str | Path) -> list[dict]:
    return [json.loads(l) for l in Path(path).read_text(encoding="utf-8").splitlines() if l]


def write_trace(path: str | Path, trace: list[dict]) -> None:
    Path(path).write_text("".join(json.dumps(l, separators=(",", ":")) + "\n" for l in trace), encoding="utf-8")


def flatten(value, prefix: str = "") -> dict:
    """{"ball": {"pos": [1, 2]}} -> {"ball.pos[0]": 1, "ball.pos[1]": 2}"""
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            out.update(flatten(v, f"{prefix}.{k}" if prefix else k))
        return out
    if isinstance(value, list):
        out = {}
        for i, v in enumerate(value):
            out.update(flatten(v, f"{prefix}[{i}]"))
        return out
    return {prefix: value}


def first_divergence(a: list[dict], b: list[dict]) -> dict | None:
    """None when the traces are equal; otherwise {"tick", "hash_a", "hash_b", "keys": {key: (a, b)}} for the first differing tick,
    or {"tick", "length": (len_a, len_b)} when one trace is a prefix of the other."""
    for x, y in zip(a, b, strict=False):  # the lengths are compared below
        if x["tick"] != y["tick"]:
            return {"tick": min(x["tick"], y["tick"]), "error": "tick numbers do not line up"}
        if x["hash"] != y["hash"]:
            fa, fb = flatten(x.get("state", {})), flatten(y.get("state", {}))
            keys = {k: (fa.get(k), fb.get(k)) for k in sorted(set(fa) | set(fb)) if fa.get(k) != fb.get(k)}
            return {"tick": x["tick"], "hash_a": x["hash"], "hash_b": y["hash"], "keys": keys}
    if len(a) != len(b):
        return {"tick": min(len(a), len(b)), "length": (len(a), len(b))}
    return None


def report(d: dict | None) -> str:
    if d is None:
        return "traces are equal"
    if "error" in d:
        return f"tick {d['tick']}: {d['error']}"
    if "length" in d:
        return f"traces agree up to tick {d['tick'] - 1}, then one ends: {d['length'][0]} lines against {d['length'][1]}"
    lines = [f"first difference at tick {d['tick']}: hash {d['hash_a']} against {d['hash_b']}"]
    if d["keys"]:
        lines.append(f"{len(d['keys'])} state key(s) differ:")
        lines += [f"  {k}: {va!r} against {vb!r}" for k, (va, vb) in d["keys"].items()]
    else:
        lines.append("no state key differs (the traces carry no state, or the hash covers something state() does not show)")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="sub", required=True)
    p = sp.add_parser("record", help="run a job under node and write its per-tick trace")
    p.add_argument("job")
    p.add_argument("-o", "--output", required=True)
    p = sp.add_parser("diff", help="the first tick where two traces differ")
    p.add_argument("a")
    p.add_argument("b")
    a = ap.parse_args()
    if a.sub == "record":
        trace = run_trace(json.loads(Path(a.job).read_text(encoding="utf-8")))
        write_trace(a.output, trace)
        print(f"divergence: {len(trace)} ticks -> {a.output}")
        return 0
    d = first_divergence(read_trace(a.a), read_trace(a.b))
    print(report(d))
    return 0 if d is None else 1


if __name__ == "__main__":
    sys.exit(main())
