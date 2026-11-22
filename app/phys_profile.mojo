"""Profiling entry: n resting boxes (app/bench.mojo's scene), a few warm-up ticks, then `ticks` measured ticks.
    build/phys_profile <n> <ticks> [iters substeps [warm-up ticks [par]]]   (run under valgrind --tool=callgrind for a per-function breakdown)"""
from app.bench import _build
from std.sys import argv
from std.time import perf_counter_ns


def main() raises:
    var args = argv()
    var n = Int(args[1]) if len(args) > 1 else 200
    var ticks = Int(args[2]) if len(args) > 2 else 20
    var w = _build(n)
    if len(args) > 4:
        w.set_solver(Int(args[3]), Int(args[4]))
    if len(args) > 6 and args[6] == "par":
        w.cfg.parallel = True
    var warm = Int(args[5]) if len(args) > 5 else 3
    for _ in range(warm):
        w.physics_tick()
    var t0 = perf_counter_ns()
    for _ in range(ticks):
        w.physics_tick()
    var t1 = perf_counter_ns()
    print("n", n, "ticks", ticks, "iters", w.cfg.iters, "substeps", w.cfg.substeps, "parallel", w.cfg.parallel, "ms_per_tick", Float64(t1 - t0) / 1e6 / Float64(ticks), "hash", w.hash())
