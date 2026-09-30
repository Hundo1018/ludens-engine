#!/usr/bin/env python3
"""End-to-end check of native hot compile (dev_native.py + live_host).

Edits a COPY of engine.mojo three times while the host runs:
  1. SPEED/COLOR (code only)   -> swap in place, frame counter continues, 6 entities
  2. syntax error              -> build fails, host keeps running the old module
  3. fix + insert a field      -> swap via snapshot, frame counter continues, 6 entities
  4. H1 crash rollback (predictions written 2026-09-30, before live_host had it):
     a. engine_update writes through a null pointer, same layout (in-place path)
        -> host does not exit; prints `rollback version=N`; the restored frame
           equals the swap's frame_before; 6 entities; the old module's colour
           (green) keeps ticking and the frame keeps increasing
     b. the same crash plus an appended field (snapshot path) -> same as (a)
     c. the crash removed again (new SPEED) -> ordinary swap in place, then
        `commit` after the probation frames
  5. H5 package edit (prediction written 2026-09-30, before dev_native watched
     packages): `SparseSet.__len__` in the copy of ecs/ returns len + 100
     -> build line with pkgs=ecs (nothing imports ecs among diag/geometry/ecs),
        build_s = pkg_s + engine_s, swap in place, ticks report count=106
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
from run_native import HERE, OUT, PACKAGES, ROOT, VARIANTS  # noqa: E402

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
    # packages: private copies (step 5 edits ecs/) and their own .mojoc directory
    pkgs, include = E2E / "pkgs", E2E / "include"
    include.mkdir(parents=True)
    for pkg in PACKAGES:
        shutil.copytree(ROOT / pkg, pkgs / pkg)
        if (ROOT / "build" / f"{pkg}.mojoc").exists():
            shutil.copy(ROOT / "build" / f"{pkg}.mojoc", include / f"{pkg}.mojoc")

    proc = Proc([sys.executable, str(HERE / "dev_native.py"), "--run-host", "--source", str(src),
                 "--out", str(E2E / "dev"), "--seconds", "600", "--packages-root", str(pkgs),
                 "--include", str(include)])
    results, ok = [], True
    rollbacks: list[dict] = []
    package_edit: dict = {}

    def check(name: str, cond: bool, detail) -> None:
        nonlocal ok
        ok &= bool(cond)
        results.append({"name": name, "pass": bool(cond), "detail": detail})
        print(f"{'PASS' if cond else 'FAIL'}  {name}  {json.dumps(detail)}", flush=True)

    try:
        proc.wait_for(lambda kv: kv["_kind"] == "load")
        _, kv, _ = proc.wait_for(lambda kv: kv["_kind"] == "tick")
        check("boot: 6 entities, red", kv["count"] == "6" and kv["color"] == str(0xFF0000FF), kv)

        # 1. code-only edit, repeated for latency statistics. Every round uses a
        # SPEED never built before: mojo caches builds per (path, code), so
        # repeating a value measures a cache hit (~0.9 s), not a compile (~3 s).
        code_edit = VARIANTS["v2_code"][0]
        latencies, builds = [], []
        salt = time.time_ns() % 1_000_000
        for r in range(a.rounds):
            text = apply(original, code_edit)
            text = text.replace("comptime SPEED: Float32 = 120.0", f"comptime SPEED: Float32 = {salt + r}.5")
            t_edit = time.perf_counter()
            src.write_text(text)
            _, b, _ = proc.wait_for(lambda kv: kv["_kind"] == "build")
            builds.append(float(b["build_s"]))
            t_swap, kv, line = proc.wait_for(lambda kv: kv["_kind"] in ("swap", "swap_error"))
            latencies.append(t_swap - t_edit)
            check(f"edit 1.{r}: code edit swapped in place, frame continues, 6 entities",
                  kv["_kind"] == "swap" and kv["used"] == "inplace" and kv["frame_before"] == kv["frame_after"]
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
        _, kv, _ = proc.wait_for(lambda kv: kv["_kind"] in ("commit", "rollback"))
        check("edit 3: probation passes (commit)", kv["_kind"] == "commit", kv)
        good3 = src.read_text()

        # 4. H1: a crashing build is rolled back
        crash = [("    # @@UPDATE@@", "    BytePtr(unsafe_from_address=8)[] = 1  # H1: null write")]
        for tag, edits, used in (("4a", crash, "inplace"), ("4b", crash + VARIANTS["v6_append"][0][:2], "snapshot")):
            src.write_text(apply(good3, edits))
            _, sw, _ = proc.wait_for(lambda kv: kv["_kind"] in ("swap", "swap_error"))
            _, rb, _ = proc.wait_for(lambda kv: kv["_kind"] in ("commit", "rollback"))
            rollbacks.append(rb)
            check(f"edit {tag}: crash ({used} path) rolled back to the swap's frame, 6 entities",
                  sw.get("used") == used and rb["_kind"] == "rollback" and rb["version"] == sw["version"]
                  and rb["frame"] == sw["frame_before"] and rb["count"] == "6", {"swap": sw, "rollback": rb})
            _, t1, _ = proc.wait_for(lambda kv: kv["_kind"] == "tick")
            _, t2, _ = proc.wait_for(lambda kv: kv["_kind"] == "tick")
            check(f"edit {tag}: old module keeps running (green, frame increases)",
                  int(t2["frame"]) > int(t1["frame"]) > int(rb["frame"]) and t2["color"] == str(0x00FF00FF)
                  and t2["count"] == "6", {"ticks": [t1, t2]})

        # 4c. crash removed: an ordinary swap again
        src.write_text(good3.replace("comptime SPEED: Float32 = ", f"comptime SPEED: Float32 = 1{salt}", 1))
        _, sw, _ = proc.wait_for(lambda kv: kv["_kind"] in ("swap", "swap_error"))
        _, cm, _ = proc.wait_for(lambda kv: kv["_kind"] in ("commit", "rollback"))
        check("edit 4c: fixed build swaps in place and commits",
              sw.get("used") == "inplace" and sw["frame_before"] == sw["frame_after"] and cm["_kind"] == "commit",
              {"swap": sw, "commit": cm})

        # 5. H5: edit a package the engine imports
        ss = pkgs / "ecs" / "sparse_set.mojo"
        t_edit = time.perf_counter()
        ss.write_text(apply(ss.read_text(), [("        return len(self._dense)\n",
                                              "        return len(self._dense) + 100  # H5 e2e\n")]))
        _, b, _ = proc.wait_for(lambda kv: kv["_kind"] == "build")
        t_swap, sw, _ = proc.wait_for(lambda kv: kv["_kind"] in ("swap", "swap_error"))
        latencies.append(t_swap - t_edit)
        check("edit 5: package edit rebuilds ecs, then the engine",
              b["ok"] == "1" and b["pkgs"] == "ecs"
              and abs(float(b["build_s"]) - float(b["pkg_s"]) - float(b["engine_s"])) < 0.02, b)
        _, t1, _ = proc.wait_for(lambda kv: kv["_kind"] == "tick")
        check("edit 5: swapped in place and the new package code runs (count=106)",
              sw.get("used") == "inplace" and t1["count"] == "106", {"swap": sw, "tick": t1})
        package_edit = {"pkg_s": float(b["pkg_s"]), "engine_s": float(b["engine_s"]),
                        "edit_to_swap_s": t_swap - t_edit}
    except TimeoutError as err:
        check("e2e ran to completion", False, str(err))
    finally:
        (E2E / "dev").mkdir(parents=True, exist_ok=True)
        (E2E / "dev" / "stop").touch()
        proc.p.wait(timeout=30)

    if latencies:
        summary = {"edit_to_swap_s": {"median": statistics.median(latencies), "max": max(latencies),
                                      "n": len(latencies)},
                   "build_s": {"median": statistics.median(builds), "max": max(builds)} if builds else None,
                   "rollbacks": rollbacks, "package_edit": package_edit}
        print("edit -> swap latency:", json.dumps(summary), flush=True)
        (E2E / "e2e.json").write_text(json.dumps({"results": results, "summary": summary,
                                                   "log": proc.log}, indent=2))
    if not ok:
        return 1
    print("PASS  native hot compile: edit -> mojo build -> swap, state kept", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
