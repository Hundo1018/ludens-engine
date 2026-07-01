"""PRNG contract parity: every generator must be reproducible from a seed, give
distinct streams for distinct seeds, emit f32 in [0,1), and be coarsely uniform.
The same generic harness runs over all three implementations.
"""

from harness.runner import Suite
from scheduler.rng import Rng, XorShift64, Pcg32, SplitMix64, range_i


def check_rng[R: Rng](mut s: Suite, tag: String):
    # reproducibility: same seed -> identical stream
    var a = R.seeded(12345)
    var b = R.seeded(12345)
    var same = True
    for _ in range(64):
        if a.next_u64() != b.next_u64():
            same = False
    s.check(same, tag + " reproducible")

    # distinct seeds -> different stream (overwhelmingly likely)
    var c = R.seeded(1)
    var d = R.seeded(2)
    var diff = False
    for _ in range(8):
        if c.next_u64() != d.next_u64():
            diff = True
    s.check(diff, tag + " seeds differ")

    # f32 in [0,1) + coarse uniformity over 10 buckets
    var e = R.seeded(99)
    var buckets = List[Int]()
    for _ in range(10):
        buckets.append(0)
    var in_range = True
    var samples = 10000
    for _ in range(samples):
        var f = e.next_f32()
        if f < 0.0 or f >= 1.0:
            in_range = False
        var bi = Int(f * 10.0)
        if bi < 0:
            bi = 0
        if bi > 9:
            bi = 9
        buckets[bi] += 1
    s.check(in_range, tag + " f32 in [0,1)")
    var uniform = True
    for i in range(10):
        if buckets[i] < 500 or buckets[i] > 1500:
            uniform = False
    s.check(uniform, tag + " coarse uniform")

    # range_i stays in [lo, hi)
    var g = R.seeded(7)
    var bounded = True
    for _ in range(2000):
        var v = range_i(g, 5, 15)
        if v < 5 or v >= 15:
            bounded = False
    s.check(bounded, tag + " range_i bounds")


def main() raises:
    var s = Suite("rng")
    check_rng[XorShift64](s, "xorshift")
    check_rng[Pcg32](s, "pcg32")
    check_rng[SplitMix64](s, "splitmix64")
    s.finish()
