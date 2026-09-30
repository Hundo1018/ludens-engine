#!/usr/bin/env python3
"""H6 gate: how much of an engine rebuild is fixed cost of `mojo build`?

Builds four shared libraries of increasing content, uncached (`--unique`:
each build gets code never built before) and interleaved:

  empty          one exported function returning a constant
  sparse_set     + uses ecs.SparseSet[Float32] (add / remove / len)
  schema         + uses ecs.schema (schema_of / write_value / read_value)
  engine         the current engine.mojo (both of the above and ~40 exports)

Predictions, written 2026-09-30 before the first run:
  * empty >= 0.8 s: process start, the Mojo front end and linking dominate
  * engine - empty ~ 2 s: the content, mostly instantiating SparseSet and the
    schema functions
Decision rule (ROADMAP_EXPERIMENT H6: "implement only with data"): a split
into several .so files can reach the H6 target (< 0.5 s for an edit to one
system) only if `empty` < 0.5 s. If `empty` >= 0.5 s, the split is not
implemented and this measurement is the result.

    python3 experiments/hot_reload/native/h6_fixed_cost.py [--reps 5]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_time import measure  # noqa: E402
from run_native import HERE, OUT, ROOT  # noqa: E402

SOURCES = {
    "empty": '''
@export
def probe_value() abi("C") -> Int:
    return 1
''',
    "sparse_set": '''
from ecs.sparse_set import SparseSet


@export
def probe_value() abi("C") -> Int:
    var s = SparseSet[Float32]()
    for e in range(8):
        s.add(e, Float32(e))
    s.remove(3)
    return len(s)
''',
    "schema": '''
from ecs.sparse_set import SparseSet
from ecs.schema import read_value, schema_of, write_value


struct Core(Copyable, Movable):
    var frame: Int
    var box_x: Float32

    def __init__(out self):
        self.frame = 0
        self.box_x = 0.0


@export
def probe_value() abi("C") -> Int:
    var s = SparseSet[Float32]()
    s.add(1, 2.0)
    var c = Core()
    var out = List[UInt8]()
    write_value(c, schema_of[Core](), out)
    var pos = 0
    try:
        _ = read_value(c, schema_of[Core](), out, pos)
    except:
        return -1
    return len(s) + len(out)
''',
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reps", type=int, default=5)
    a = ap.parse_args()
    d = OUT / "h6"
    d.mkdir(parents=True, exist_ok=True)
    paths = []
    for name, text in SOURCES.items():
        (d / f"{name}.mojo").write_text(text)
        paths.append(d / f"{name}.mojo")
    paths.append(HERE / "engine.mojo")
    res = measure(paths, a.reps, [str(ROOT / "build"), str(HERE)], "shared-lib", unique=True)
    names = [p.stem if p.stem != "engine" else "engine" for p in paths]
    rows = {n: res[str(p)] for n, p in zip(names, paths)}
    for n, r in rows.items():
        print(f"{n:<11} median {r['median']:5.2f} s  min {r['min']:5.2f}  max {r['max']:5.2f}  n={r['n']}")
    empty = rows["empty"]["median"]
    print(f"engine - empty = {rows['engine']['median'] - empty:.2f} s; "
          f"fixed share of an engine build = {empty / rows['engine']['median']:.0%}")
    verdict = "split can reach < 0.5 s" if empty < 0.5 else "split cannot reach < 0.5 s: not implemented"
    print(f"decision: empty = {empty:.2f} s -> {verdict}")
    (OUT / "h6_fixed_cost.json").write_text(json.dumps({"rows": rows, "decision": verdict}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
