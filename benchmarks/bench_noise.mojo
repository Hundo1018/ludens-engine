"""Noise family throughput: ns per sample for each primitive.

Scalar samples over a grid (the deterministic hash is the whole cost — no
table lookups). fBm is ~octaves× its base, Worley pays the 27-cell search.
Run: mojo run -I build benchmarks/bench_noise.mojo
"""

from std.time import perf_counter_ns
from std.benchmark import keep
from harness.bench import BenchTable
from geometry.vec import Real
from procedural.noise import value3, perlin3, perlin2, worley3, fbm3, fbm2

comptime SIDE = 256


def _perlin3() -> Int:
    var t0 = Int(perf_counter_ns())
    var acc = Real(0)
    for i in range(SIDE):
        for j in range(SIDE):
            acc += perlin3(Real(i) * 0.1, Real(j) * 0.1, 0.5, 1)
    keep(acc)
    return Int(perf_counter_ns()) - t0


def _value3() -> Int:
    var t0 = Int(perf_counter_ns())
    var acc = Real(0)
    for i in range(SIDE):
        for j in range(SIDE):
            acc += value3(Real(i) * 0.1, Real(j) * 0.1, 0.5, 1)
    keep(acc)
    return Int(perf_counter_ns()) - t0


def _worley3() -> Int:
    var t0 = Int(perf_counter_ns())
    var acc = Real(0)
    for i in range(SIDE):
        for j in range(SIDE):
            acc += worley3(Real(i) * 0.1, Real(j) * 0.1, 0.5, 1)
    keep(acc)
    return Int(perf_counter_ns()) - t0


def _fbm3() -> Int:
    var t0 = Int(perf_counter_ns())
    var acc = Real(0)
    for i in range(SIDE):
        for j in range(SIDE):
            acc += fbm3(Real(i) * 0.1, Real(j) * 0.1, 0.5, 1)
    keep(acc)
    return Int(perf_counter_ns()) - t0


def _perlin2() -> Int:
    var t0 = Int(perf_counter_ns())
    var acc = Real(0)
    for i in range(SIDE):
        for j in range(SIDE):
            acc += perlin2(Real(i) * 0.1, Real(j) * 0.1, 1)
    keep(acc)
    return Int(perf_counter_ns()) - t0


def _fbm2() -> Int:
    var t0 = Int(perf_counter_ns())
    var acc = Real(0)
    for i in range(SIDE):
        for j in range(SIDE):
            acc += fbm2(Real(i) * 0.1, Real(j) * 0.1, 1)
    keep(acc)
    return Int(perf_counter_ns()) - t0


def main() raises:
    var t = BenchTable("noise family: ns per sample")
    var n = SIDE * SIDE
    t.add("perlin2", n, "sample", _perlin2(), n)
    t.add("perlin3", n, "sample", _perlin3(), n)
    t.add("value3", n, "sample", _value3(), n)
    t.add("worley3", n, "sample", _worley3(), n)
    t.add("fbm2 (5 oct)", n, "sample", _fbm2(), n)
    t.add("fbm3 (5 oct)", n, "sample", _fbm3(), n)
    t.print_report()
