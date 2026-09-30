#!/usr/bin/env python3
"""End-to-end check of native hot compile (dev_native.py + live_host).

Edits a COPY of engine.mojo three times while the host runs:
  1. SPEED/COLOR (code only)   -> swap via rebind, frame counter continues, 6 entities
  2. syntax error              -> build fails, host keeps running the old module
  3. fix + insert a field      -> swap via snapshot, frame counter continues, 6 entities
and measures edit -> swap latency (file write to the host's swap line).

    python3 experiments/hot_reload/native/e2e_native.py [--rounds N]
"""
from __future__ import annotations

import argparse
import json
import queue
import re
import shutil
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_native import HERE, OUT, ROOT, VARIANTS  # noqa: E402

E2E = OUT / "e2e"
KV = re.compile(r"(\w+)=(\S+)")


class Proc:
    def __init__(self, cmd: list[str]):
        self.p = subprocess.Popen(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  text=True, bufsize=1)
        self.q: queue.Queue = queue.Queue()
        self.log: list[str] = []
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self) -> None:
        for line in self.p.stdout:
            self.q.put((time.perf_counter(), line.rstrip("\n")))

    def wait_for(self, pred, timeout: float = 120.0) -> tuple[float, dict, str]:
        end = time.perf_counter() + timeout
        while time.perf_counter() < end:
            try:
                t, line = self.q.get(timeout=0.5)
            except queue.Empty:
                continue
            self.log.append(line)
            kv = dict(KV.findall(line))
            kv["_kind"] = line.split(" ", 1)[0]
            if pred(kv):
                return t, kv, line
        raise TimeoutError("no matching line; last lines:\n" + "\n".join(self.log[-15:]))


def apply(src: str, edits: list[tuple[str, str]]) -> str:
    for old, new in edits:
        assert old in src, old
        src = src.replace(old, new, 1)
    return src


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rounds", type=int, default=1, help="repeat the code-only edit N times for latency stats")
    a = ap.parse_args()

    if E2E.exists():
        shutil.rmtree(E2E)
    src = E2E / "src" / "engine.mojo"
    src.parent.mkdir(parents=True)
    original = (HERE / "engine.mojo").read_text()
    src.write_text(original)

    proc = Proc([sys.executable, str(HERE / "dev_native.py"), "--run-host", "--source", str(src),
                 "--out", str(E2E / "dev"), "--seconds", "600"])
    results, ok = [], True

    def check(name: str, cond: bool, detail) -> None:
        nonlocal ok
        ok &= bool(cond)
        results.append({"name": name, "pass": bool(cond), "detail": detail})
        print(f"{'PASS' if cond else 'FAIL'}  {name}  {json.dumps(detail)}", flush=True)

    try:
        proc.wait_for(lambda kv: kv["_kind"] == "load")
        _, kv, _ = proc.wait_for(lambda kv: kv["_kind"] == "tick")
        check("boot: 6 entities, red", kv["count"] == "6" and kv["color"] == str(0xFF0000FF), kv)

        # 1. code-only edit (repeated for latency statistics, alternating speeds)
        code_edit = VARIANTS["v2_code"][0]
        latencies, builds = [], []
        for r in range(a.rounds):
            text = apply(original, code_edit)
            if r % 2 == 1:  # alternate so every round is a real change
                text = text.replace("comptime SPEED: Float32 = 120.0", "comptime SPEED: Float32 = 90.0")
            t_edit = time.perf_counter()
            src.write_text(text)
            _, b, _ = proc.wait_for(lambda kv: kv["_kind"] == "build")
            builds.append(float(b["build_s"]))
            t_swap, kv, line = proc.wait_for(lambda kv: kv["_kind"] in ("swap", "swap_error"))
            latencies.append(t_swap - t_edit)
            check(f"edit 1.{r}: code edit swapped via rebind, frame continues, 6 entities",
                  kv["_kind"] == "swap" and kv["used"] == "rebind" and kv["frame_before"] == kv["frame_after"]
                  and kv["count"] == "6", kv)
        _, kv, _ = proc.wait_for(lambda kv: kv["_kind"] == "tick")
        check("edit 1: new color live (green)", kv["color"] == str(0x00FF00FF), kv)
        good = src.read_text()

        # 2. syntax error
        src.write_text(good + "\nthis is not mojo\n")
        _, kv, _ = proc.wait_for(lambda kv: kv["_kind"] == "build")
        check("edit 2: build fails", kv["ok"] == "0", kv)
        _, t1, _ = proc.wait_for(lambda kv: kv["_kind"] == "tick")
        _, t2, _ = proc.wait_for(lambda kv: kv["_kind"] == "tick")
        check("edit 2: old module keeps running", int(t2["frame"]) > int(t1["frame"]) and t2["color"] == str(0x00FF00FF),
              {"frames": [t1["frame"], t2["frame"]]})

        # 3. fix + layout change
        t_edit = time.perf_counter()
        src.write_text(apply(good, VARIANTS["v4_layout"][0]))
        t_swap, kv, _ = proc.wait_for(lambda kv: kv["_kind"] in ("swap", "swap_error"))
        check("edit 3: layout edit swapped via snapshot, frame continues, 6 entities",
              kv["_kind"] == "swap" and kv["used"] == "snapshot" and kv["frame_before"] == kv["frame_after"]
              and kv["count"] == "6", kv)
        latencies.append(t_swap - t_edit)
    except TimeoutError as err:
        check("e2e ran to completion", False, str(err))
    finally:
        (E2E / "dev").mkdir(parents=True, exist_ok=True)
        (E2E / "dev" / "stop").touch()
        proc.p.wait(timeout=30)

    if latencies:
        summary = {"edit_to_swap_s": {"median": statistics.median(latencies), "max": max(latencies),
                                      "n": len(latencies)},
                   "build_s": {"median": statistics.median(builds), "max": max(builds)} if builds else None}
        print("edit -> swap latency:", json.dumps(summary), flush=True)
        (E2E / "e2e.json").write_text(json.dumps({"results": results, "summary": summary,
                                                   "log": proc.log}, indent=2))
    if not ok:
        return 1
    print("PASS  native hot compile: edit -> mojo build -> swap, state kept", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
