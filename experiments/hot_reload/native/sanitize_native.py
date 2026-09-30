#!/usr/bin/env python3
"""H4: is v6_append's in-place swap an out-of-bounds write?

v6 appends `var extra: Int` to the state and increments it every frame. Under
an in-place swap the host's block was sized for the old state, so the new
code writes `extra` past its end. The matrix cannot see that (the output is
correct). Two independent detectors are run on the same cells:

  valgrind  memcheck; host and engines rebuilt with --target-cpu x86-64-v3,
            because valgrind 3.22 cannot decode the AVX-512 instructions a
            host-CPU build contains (first run: SIGILL in maps_count before
            any engine code ran); counts "Invalid write" errors
  asan      host and engine rebuilt with `mojo build --sanitize address`;
            the linker here is gcc (`cc`), which links libasan dynamically,
            so host and engine share one runtime (`--shared-libasan` passes a
            clang-only option and gcc rejects it); looks for an ASan report

Host state blocks come from libc malloc (hotswap.block): Mojo's `alloc` uses
its own arena, where valgrind cannot see a block's end
(probes/probe_alloc_bounds.mojo). The first valgrind runs used `alloc` blocks
and saw nothing.

How the valgrind verdict is read: `s.extra += 1` compiles to one `incq`, a
read-modify-write. memcheck files such an instruction's load and store as 2
errors in ONE context labelled "Invalid read" (probe_alloc_bounds: one
`addq` past a block -> "2 errors in context ... Invalid read of size 8").
So `detected` = an inline report whose top frame is `engine_update` in the
new .so and whose address lies past a block the host allocated
(`host::main`, where `block()` is inlined). The -s summary at exit cannot
be used for this: by then the engine's symbols print as `???`. The literal
count of "Invalid write" lines is kept in the output as well.

Predictions, written 2026-09-30 before the first run (ROADMAP_EXPERIMENT H4;
H2 turned `rebind` into `close`):
  keep x v6, close x v6  -> an invalid write is reported
  auto x v6              -> nothing (auto takes the snapshot path)
  keep / close / auto x v2_code (control, same layout) -> nothing

R1 B3 (asan-r1): the same ASan build on R1 cells, predictions in
predictions_r1.PREDICTED_B3 (committed before this code):
  keep/close/auto x t1_impl   -> nothing (the trail is reallocated by the new
                                 code; one allocator)
  keep/auto x m2_nested       -> nothing, although the new code reads past
                                 the end of the bodies buffer (H-e: Mojo's
                                 allocator hides block ends)

    python3 experiments/hot_reload/native/sanitize_native.py [valgrind|asan|asan-r1|all]
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_native import HERE, OUT, ROOT, VARIANTS, mojo, sh, variant_source  # noqa: E402

CELLS = [(s, v) for v in ("v2_code", "v6_append") for s in ("keep", "close", "auto")]
PREDICTED = {(s, v): (v == "v6_append" and s in ("keep", "close")) for s, v in CELLS}
ASAN = OUT / "asan"
VALGRIND = OUT / "valgrind"


def run_host(host: Path, old: Path, new: Path, strategy: str, cell: Path, prefix: list[str],
             env: dict | None = None) -> subprocess.CompletedProcess:
    if cell.exists():
        shutil.rmtree(cell)
    cell.mkdir(parents=True)
    a, b = cell / "old.so", cell / "new.so"
    shutil.copy(old, a)
    shutil.copy(new, b)
    return subprocess.run([*prefix, str(host), str(a), str(b), strategy], cwd=ROOT, capture_output=True,
                          text=True, timeout=600, env=env)


def build_set(root: Path, flags: list[str], names: tuple[str, ...] = ("v1", "v2_code", "v6_append")) -> None:
    """host + engines `names` under `root`, built with `flags`."""
    root.mkdir(parents=True, exist_ok=True)
    for name in names:
        d = root / name
        d.mkdir(parents=True, exist_ok=True)
        (d / "engine.mojo").write_text(variant_source(VARIANTS[name][0]))
        sh([mojo(), "build", *flags, "--emit", "shared-lib", "-I", "build", "-I", str(HERE), str(d / "engine.mojo"),
            "-o", str(d / "libengine.so")], stdout=subprocess.DEVNULL)
    sh([mojo(), "build", *flags, "-I", "build", "-I", str(HERE), str(HERE / "host.mojo"), "-o", str(root / "host")],
       stdout=subprocess.DEVNULL)


def valgrind() -> list[dict]:
    build_set(VALGRIND, ["--target-cpu", "x86-64-v3"])
    rows = []
    for s, v in CELLS:
        p = run_host(VALGRIND / "host", VALGRIND / "v1" / "libengine.so", VALGRIND / v / "libengine.so", s,
                     VALGRIND / "cells" / f"{s}-{v}", ["valgrind", "--tool=memcheck", "--error-limit=no"])
        writes = len(re.findall(r"Invalid write of size (\d+)", p.stderr))
        summary = re.search(r"ERROR SUMMARY: (\d+) errors", p.stderr)
        # inline report: kind / at <fn> (in <file>) / by.. / Address .. is K bytes after a block of size S alloc'd / at malloc / by <allocator>
        reports = re.findall(r"== (Invalid \w+ of size \d+)\n==\d+==\s+at 0x[0-9A-F]+: (\S+) \(in ([^)]+)\)\n"
                             r"(?:==\d+==\s+by [^\n]*\n)*==\d+==\s+Address 0x[0-9a-f]+ is (\d+) bytes after a block of "
                             r"size (\d+) alloc'd\n==\d+==\s+at [^\n]*\n==\d+==\s+by 0x[0-9A-F]+: (\S+)", p.stderr)
        hits = [r for r in reports if r[1] == "engine_update" and r[2].endswith("new.so") and r[5] == "host::main()"]
        rows.append({"tool": "valgrind", "strategy": s, "variant": v, "detected": bool(hits),
                     "reports": [f"{k} in {fn}, {off} bytes after a {size}-byte block from {by}"
                                 for k, fn, _, off, size, by in reports],
                     "invalid_write_lines": writes,
                     "all_errors": int(summary.group(1)) if summary else None, "rc": p.returncode,
                     "used": next((l.split("=", 1)[1] for l in p.stdout.splitlines() if l.startswith("used=")), None),
                     "completed": "teardown=ok" in p.stdout,
                     "sigill": "Unrecognised instruction" in p.stderr})
    return rows


def asan(cells: list[tuple[str, str]] = CELLS, root: Path = ASAN, tool: str = "asan") -> list[dict]:
    names = tuple(sorted({"v1", *(v for _, v in cells)}))
    build_set(root, ["--sanitize", "address"], names)
    rows = []
    for s, v in cells:
        p = run_host(root / "host", root / "v1" / "libengine.so", root / v / "libengine.so", s,
                     root / "cells" / f"{s}-{v}", [])
        m = re.search(r"ERROR: AddressSanitizer: ([\w-]+)", p.stderr)
        where = re.search(r"(WRITE|READ) of size (\d+)", p.stderr)
        frame = re.search(r"#0 0x[0-9a-f]+ in (\S+)", p.stderr)
        rows.append({"tool": tool, "strategy": s, "variant": v, "detected": m is not None,
                     "error": m.group(1) if m else None,
                     "access": f"{where.group(1)} {where.group(2)}" if where else None,
                     "frame0": frame.group(1) if frame else None, "rc": p.returncode,
                     "used": next((l.split("=", 1)[1] for l in p.stdout.splitlines() if l.startswith("used=")), None),
                     "stderr_head": p.stderr[:400] if (p.returncode != 0 and not m) else None})
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tool", nargs="?", default="all", choices=["valgrind", "asan", "asan-r1", "all"])
    a = ap.parse_args()
    if not (OUT / "host").exists():
        sys.exit("run `run_native.py build` first")
    rows = []
    if a.tool in ("valgrind", "all"):
        rows += valgrind()
    if a.tool in ("asan", "all"):
        rows += asan()
    if a.tool in ("asan-r1", "all"):
        from predictions_r1 import PREDICTED_B3, REFUTED_R1
        rows += asan(list(PREDICTED_B3), OUT / "asan_r1", "asan-r1")
        PREDICTED.update(PREDICTED_B3)
        for r in rows:
            if r["tool"] == "asan-r1" and ("B3", r["strategy"], r["variant"]) in REFUTED_R1:
                r["refuted_recorded"] = True
    fails = 0
    for r in rows:
        want = PREDICTED[(r["strategy"], r["variant"])]
        # a run that died of a tool problem (SIGILL under valgrind) is no evidence either way
        hit = r["detected"] == want and not r.get("sigill")
        if not hit and r.get("refuted_recorded") and r["detected"] != want:
            hit = True  # refuted before, kept as observed (predictions_r1.REFUTED_R1)
            want = f"{want} REFUTED(recorded)"
        fails += not hit
        detail = {k: r[k] for k in r if k not in ("tool", "strategy", "variant", "detected")}
        print(f"{'PASS' if hit else 'FAIL'}  {r['tool']:<9}{r['strategy']:<7}{r['variant']:<10} "
              f"detected={r['detected']!s:<5} predicted={want!s:<5} {json.dumps(detail)}")
    (OUT / "sanitize.json").write_text(json.dumps(rows, indent=2))
    print(("PASS  " if not fails else f"FAIL  {fails} cell(s) contradict the predictions; ") + "wrote build/hot_native/sanitize.json")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
