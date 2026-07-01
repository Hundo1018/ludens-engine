"""PRNG throughput: xorshift64* vs PCG32 vs SplitMix64.

The same draw loop run through each interchangeable generator, for both raw
`next_u64` and `next_f32`. Shows the classic tradeoff — xorshift/splitmix are a
couple of ops; PCG does more work (a 64-bit LCG step + output permutation) for
better statistical quality. Run: `mojo run -I build benchmarks/bench_rng.mojo`.
"""

from std.benchmark import keep
from harness.bench import BenchTable, now
from scheduler.rng import Rng, XorShift64, Pcg32, SplitMix64


def bench_u64[R: Rng](mut table: BenchTable, variant: String, n: Int):
    var r = R.seeded(0xABCDEF)
    var acc = UInt64(0)
    var t0 = now()
    for _ in range(n):
        acc ^= r.next_u64()
    var t1 = now()
    keep(Int(acc))
    table.add(variant, n, "next_u64", t1 - t0, n)


def bench_f32[R: Rng](mut table: BenchTable, variant: String, n: Int):
    var r = R.seeded(0xABCDEF)
    var acc = Float32(0)
    var t0 = now()
    for _ in range(n):
        acc += r.next_f32()
    var t1 = now()
    keep(acc)
    table.add(variant, n, "next_f32", t1 - t0, n)


def main() raises:
    var table = BenchTable("PRNG throughput — xorshift vs pcg vs splitmix")
    var N = 2000000
    bench_u64[XorShift64](table, "xorshift", N)
    bench_u64[Pcg32](table, "pcg32", N)
    bench_u64[SplitMix64](table, "splitmix64", N)
    bench_f32[XorShift64](table, "xorshift", N)
    bench_f32[Pcg32](table, "pcg32", N)
    bench_f32[SplitMix64](table, "splitmix64", N)
    table.print_report()
