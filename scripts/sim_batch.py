#!/usr/bin/env python3
"""`ludens sim <mode>`: run a game headless over many seeds and print a table (ludens-engine #115).

    pixi run -e wasm python3 scripts/ludens.py sim demo --seeds 1..1000 --ticks 300 --report tick,jumps,ball.pos[0],ball.pos[2]

One row per seed, then min / mean / max of each numeric column. `--report` names fields of `GameMode.state()` by path
(`jumps`, `ball.pos[0]`, `hash`); `seed` is always the first column. Every run is a fresh game started with
`reset(seed, scene)` and stepped `--ticks` frames of 1/60 s with the same input: `--hold W,D` keeps those keys down
(W A S D) and `--jump-every N` presses jump every N frames. The same arguments give the same bytes: the simulation is
deterministic and numbers print with `%.6g`.

Modes: `demo` (app/sim_main.mojo). A game in another repository adds its own entry point built on game/batch.mojo."""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

MODES = {"demo": "app/sim_main.mojo"}
HOLD = {"W": (1, 0), "S": (-1, 0), "D": (0, 1), "A": (0, -1)}  # key -> (forward, right), as game/controls.mojo reads them


def parse_seeds(spec: str) -> list[int]:
    """`1..1000`, `7`, `1,5,9` or `1..10,20..30`: inclusive ranges and single values, kept in the order given."""
    seeds: list[int] = []
    for part in spec.split(","):
        m = re.fullmatch(r"(\d+)\.\.(\d+)", part) or re.fullmatch(r"(\d+)", part)
        if not m:
            sys.exit(f"sim: bad --seeds `{spec}` (examples: 1..1000, 7, 1,5,9)")
        lo, hi = int(m.group(1)), int(m.group(m.lastindex))
        if hi < lo:
            sys.exit(f"sim: bad --seeds range `{part}`: the end is before the start")
        seeds += range(lo, hi + 1)
    return seeds


def parse_hold(spec: str) -> tuple[int, int]:
    forward = right = 0
    for k in filter(None, spec.upper().split(",")):
        if k not in HOLD:
            sys.exit(f"sim: unknown key `{k}` in --hold (W, A, S, D)")
        forward += HOLD[k][0]
        right += HOLD[k][1]
    return max(-1, min(1, forward)), max(-1, min(1, right))


def lookup(state: dict, path: str):
    """`ball.pos[1]` -> state["ball"]["pos"][1]"""
    cur = state
    for key, idx in re.findall(r"([^.\[\]]+)|\[(\d+)\]", path):
        try:
            cur = cur[int(idx)] if idx else cur[key]
        except (KeyError, IndexError, TypeError):
            sys.exit(f"sim: the state has no field `{path}` (state keys: {', '.join(state)})")
    if isinstance(cur, (dict, list)):
        sys.exit(f"sim: `{path}` is not a single value; name one element, e.g. `{path}[0]`")
    return cur


def fmt(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    return format(v, ".6g") if isinstance(v, float) else str(v)


def table(rows: list[list], header: list[str]) -> str:
    """Right-aligned columns, then min / mean / max over the numeric ones ("-" where a column is not numeric)."""
    cells = [header] + [[fmt(v) for v in r] for r in rows]
    stats = []
    for name, fn in (("min", min), ("mean", lambda c: sum(c) / len(c)), ("max", max)):
        row = [name]
        for i in range(1, len(header)):
            col = [r[i] for r in rows]
            numeric = all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in col)
            row.append(fmt(fn(col)) if numeric else "-")
        stats.append(row)
    all_rows = cells + [["---"] * len(header)] + stats
    widths = [max(len(r[i]) for r in all_rows) for i in range(len(header))]
    return "\n".join("  ".join(c.rjust(w) for c, w in zip(r, widths, strict=True)).rstrip() for r in all_rows) + "\n"


def build_sim(mode: str) -> Path:
    """Build the mode's native runner the way the parity gates build theirs (scripts/game_same.py): ludens-core in its serial
    variant (the code path of wasm64) and the wasm runtime's libm, so no FMA fusion changes the last bits. Its hashes are then
    the ones the wasm64 module gives (checked in tests/test_automation.py). Rebuilt only when a source is newer."""
    import build_core
    import native_libs
    from bench import serial_engine
    entry, out = MODES[mode], ROOT / f"build/sim_{mode}"
    if out.exists() and out.stat().st_mtime >= build_core.newest(build_core.native_sources(entry)):
        return out
    subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    native_libs.build_all()
    eng = serial_engine()
    cmd = [sys.executable, "-m", "ludens_wasm_rt.build_wasm", "--lib", str(eng), "--lib", ".", "-I", str(eng), "-I", ".",
           entry, "--target", "native", "-o", str(out)]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=False)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)
    return out


def run(mode: str, seeds: list[int], ticks: int, scene: str, hold: str, jump_every: int, report: list[str]) -> str:
    if mode not in MODES:
        sys.exit(f"sim: unknown mode `{mode}` (known: {', '.join(MODES)})")
    exe = build_sim(mode)
    fwd, right = parse_hold(hold)
    cmd = [str(exe), ",".join(map(str, seeds)), str(ticks), scene, str(fwd), str(right), str(jump_every)]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode:
        sys.exit(proc.stderr.strip() or f"sim: {exe.name} exited with {proc.returncode}")
    runs = [json.loads(l) for l in proc.stdout.splitlines() if l]
    rows = [[r["seed"]] + [lookup(r["state"], f) for f in report] for r in runs]
    return table(rows, ["seed"] + report)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="ludens sim", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", help=f"the game ({', '.join(MODES)})")
    ap.add_argument("--seeds", default="1..10", help="1..1000, 7, 1,5,9 (default 1..10)")
    ap.add_argument("--ticks", type=int, required=True, help="frames of 1/60 s per run")
    ap.add_argument("--report", default="tick,hash", help="comma-separated state fields (default tick,hash)")
    ap.add_argument("--scene", default="", help="the game's scene name (default: its default scene)")
    ap.add_argument("--hold", default="", help="keys held for the whole run, e.g. W,D")
    ap.add_argument("--jump-every", type=int, default=0, help="press jump every N frames (0 = never)")
    a = ap.parse_args(argv)
    if a.ticks < 0 or a.jump_every < 0:
        sys.exit("sim: --ticks and --jump-every must not be negative")
    sys.stdout.write(run(a.mode, parse_seeds(a.seeds), a.ticks, a.scene, a.hold, a.jump_every, [f for f in a.report.split(",") if f]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
