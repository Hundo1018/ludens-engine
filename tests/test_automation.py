#!/usr/bin/env python3
"""The automation contract (ludens-engine #115, docs/automation.md), end to end through real processes.

    pixi run -e wasm test-automation          # builds build/app.wasm first

  - the `window.game` hook under node, no WebGPU: 600 ticks driven twice give equal hashes, tick for tick;
  - the hook reaches the game: keys change the state, a tap makes a jump and one `events()` cue, `draw` does not change the run;
  - seeds and scenes: seed 0 is the unseeded run, other seeds differ, an unknown scene is an error;
  - the divergence trace: a one-tick input difference injected at tick 300 is found at tick 301, with the state keys that differ;
  - the batch runner: a fixed seed set prints the table in tests/golden/sim_demo_table.txt byte for byte, and its rows agree with the
    same seeds driven through the wasm64 hook.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import divergence  # noqa: E402
import sim_batch  # noqa: E402

GOLDEN = ROOT / "tests/golden/sim_demo_table.txt"
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


# The scripted run every check starts from: D held for the whole run, W from tick 60 to 400, a jump tap at tick 120.
BASE = {"ticks": 600, "script": [
    {"tick": 0, "hold": "KeyD"}, {"tick": 60, "hold": "w"}, {"tick": 120, "press": "Space"}, {"tick": 400, "release": "w"},
]}


def job(**over) -> dict:
    return {**BASE, **over}


def refuses(j: dict) -> str:
    """The message of a run that must fail."""
    try:
        divergence.run_trace(j)
    except SystemExit as e:
        return str(e)
    return ""


def main() -> int:
    a = divergence.run_trace(job())
    b = divergence.run_trace(job())
    check(len(a) == 601 and a[0]["tick"] == 0 and a[-1]["tick"] == 600, "600 ticks give 601 trace lines (tick 0 is the start)")
    check([l["hash"] for l in a] == [l["hash"] for l in b], "the demo game driven for 600 ticks twice: all 601 hashes are equal")
    check(a[0]["hash"] != a[100]["hash"] != a[600]["hash"], "the hash changes while the game runs")
    check(all(l["state"]["tick"] == l["tick"] for l in a), "one frame is one game tick (state().tick == frames stepped)")
    check(all(l["state"]["hash"] == l["hash"] for l in a), "state().hash is hash()")

    last = a[-1]["state"]
    check(last["jumps"] == 1, f"the tap at tick 120 made one jump (state jumps = {last['jumps']})")
    check(a[119]["state"]["ball"]["pos"][1] < 0.41 and max(l["state"]["ball"]["pos"][1] for l in a[120:160]) > 1.0,
          "the ball left the floor after the tap (peak y %.2f)" % max(l["state"]["ball"]["pos"][1] for l in a[120:160]))
    check(a[59]["state"]["ball"]["pos"][2] == a[0]["state"]["ball"]["pos"][2] and a[100]["state"]["ball"]["pos"][2] < 3.0,
          "W held from tick 60 moves the ball toward -z; before that it stays")
    check(a[100]["state"]["ball"]["pos"][0] > 1.0, "D held moves the ball toward +x")
    idle = divergence.run_trace({"ticks": 600})
    check(idle[-1]["hash"] != a[-1]["hash"], "a run with no keys ends in a different state")

    ev = divergence.run_trace(job(events=True))
    cues = [(l["tick"], e) for l in ev for e in l.get("events", [])]
    check(cues == [(121, {"frame": 121, "cue": 1})], f"events(): one jump cue, in the step after the tap {cues}")
    drawn = divergence.run_trace(job(draw=True))
    check([l["hash"] for l in drawn] == [l["hash"] for l in a], "step(1, true) and step(1, false) give the same 601 hashes")

    # seeds and scenes
    s0 = divergence.run_trace(job(seed=0, scene="arena"))
    check([l["hash"] for l in s0] == [l["hash"] for l in a], "seed 0 and scene arena are the unseeded run")
    s5 = divergence.run_trace(job(seed=5))
    s5b = divergence.run_trace(job(seed=5))
    check(s5[0]["hash"] != a[0]["hash"] and s5[-1]["hash"] != a[-1]["hash"], "seed 5 starts and ends in a different state")
    check([l["hash"] for l in s5] == [l["hash"] for l in s5b], "seed 5 twice: equal traces")
    bare = divergence.run_trace(job(scene="bare", ticks=60))
    check(bare[-1]["state"]["crates"] == [] and bare[-1]["state"]["scene"] == "bare", "scene bare has no crates")
    check("failed (-2)" in refuses(job(scene="nope", ticks=1)), "an unknown scene is an error")
    check("seed must be" in refuses(job(seed="x", ticks=1)), "a seed that is not an integer is an error")

    # divergence: the same run, plus one jump tap at tick 300
    inject = {"tick": 300, "press": "Space"}
    c = divergence.run_trace(job(script=BASE["script"] + [inject]))
    d = divergence.first_divergence(a, c)
    check(d is not None and d["tick"] == 301, f"a tap injected at tick 300 is found at tick 301 (found {d and d['tick']})")
    check(d is not None and all(x["hash"] == y["hash"] for x, y in zip(a[:301], c[:301], strict=True)), "the traces agree on every tick before it")
    check(d is not None and "jumps" in d["keys"] and d["keys"]["jumps"] == (1, 2), f"the differing keys name jumps: {d and sorted(d['keys'])}")
    check(divergence.first_divergence(a, b) is None, "two equal traces report no divergence")
    check(divergence.first_divergence(a, a[:300]) == {"tick": 300, "length": (601, 300)}, "a trace that ends early is reported as a length difference")
    with tempfile.TemporaryDirectory() as t:
        pa, pc, pj = Path(t) / "a.jsonl", Path(t) / "c.jsonl", Path(t) / "job.json"
        pj.write_text(json.dumps(job()))
        divergence.write_trace(pa, a)
        divergence.write_trace(pc, c)
        run = lambda *args: subprocess.run([sys.executable, str(ROOT / "scripts/divergence.py"), *args], capture_output=True, text=True, check=False)
        r = run("diff", str(pa), str(pc))
        check(r.returncode == 1 and "first difference at tick 301" in r.stdout and "jumps: 1 against 2" in r.stdout, "the diff tool prints the tick and the keys, exit 1")
        check(run("diff", str(pa), str(pa)).returncode == 0, "the diff tool exits 0 on equal traces")
        pb = Path(t) / "rec.jsonl"
        r = run("record", str(pj), "-o", str(pb))
        check(r.returncode == 0 and divergence.read_trace(pb) == a, "`record` writes the same trace as run_trace")

    # the batch runner
    seeds = sim_batch.parse_seeds("1..16")
    fields = ["tick", "jumps", "ball.pos[0]", "ball.pos[2]", "crates[1][2]", "hash"]
    t1 = sim_batch.run("demo", seeds, 300, "", "W", 100, fields)
    t2 = sim_batch.run("demo", seeds, 300, "", "W", 100, fields)
    check(t1 == t2, "the same batch twice gives the same table")
    check(GOLDEN.exists() and t1 == GOLDEN.read_text(encoding="utf-8"), f"the table of seeds 1..16 equals {GOLDEN.relative_to(ROOT)} byte for byte")
    rows = {int(l.split()[0]): l.split() for l in t1.splitlines()[1:17]}
    for seed in (1, 3, 11, 16):  # native batch rows against the wasm64 hook, same seed and keys
        taps = [{"tick": t, "press": "Space"} for t in (0, 100, 200)]  # --jump-every 100
        w = divergence.run_trace({"ticks": 300, "seed": seed, "script": [{"tick": 0, "hold": "KeyW"}, *taps]})[-1]
        check(rows[seed][-1] == w["hash"] and float(rows[seed][3]) == float(f"{w['state']['ball']['pos'][0]:.6g}"),
              f"seed {seed}: the native batch row and the wasm64 hook end in the same hash ({w['hash']})")
    check(len({r[-1] for r in rows.values()}) == 16, "16 seeds give 16 different final hashes")
    check(sim_batch.parse_seeds("1,5,9") == [1, 5, 9] and sim_batch.parse_seeds("1..3,7") == [1, 2, 3, 7], "--seeds takes lists and ranges")
    try:
        sim_batch.run("demo", [1], 10, "", "", 0, ["no.such"])
        check(False, "an unknown report field is an error")
    except SystemExit as e:
        check("no field `no.such`" in str(e), "an unknown report field is an error naming the field")
    try:
        sim_batch.run("demo", [1], 10, "nope", "", 0, ["tick"])
        check(False, "an unknown scene is an error")
    except SystemExit as e:
        check("unknown scene `nope`" in str(e), "the batch runner reports an unknown scene")

    print(f"automation: {passed} / {passed + failed} checks")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
