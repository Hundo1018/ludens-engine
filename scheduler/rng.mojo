"""Seeded, reproducible PRNGs — a swap seam over generator algorithms.

`Rng` is the contract; `XorShift64`, `Pcg32` and `SplitMix64` are interchangeable
implementations chosen at instantiation (`R.seeded(seed)`), exactly like a storage
backend or a scheduler. Determinism is the point: the same seed always replays the
same stream, which is what reproducible simulation and replay/rollback need.

`SplitMix64` doubles as the canonical seeder — the other generators expand a single
user seed through it so even a `0` seed yields a well-distributed initial state.
`next_f32` draws from the top 24 bits to land uniformly in `[0, 1)` without bias.
"""

from geometry.vec import Vec2, Vec3, normalize


trait Rng(Defaultable, Movable, ImplicitlyDeletable):
    @staticmethod
    def seeded(seed: UInt64) -> Self: ...
    def next_u64(mut self) -> UInt64: ...
    def next_f32(mut self) -> Float32: ...


def _bits_to_f32(u: UInt64) -> Float32:
    """Top 24 bits of `u`, scaled into [0, 1)."""
    var bits = UInt32((u >> 40) & 0xFFFFFF)
    return Float32(bits) * Float32(1.0 / 16777216.0)


@fieldwise_init
struct SplitMix64(Rng):
    var state: UInt64

    def __init__(out self):
        self.state = 0

    @staticmethod
    def seeded(seed: UInt64) -> Self:
        return Self(seed)

    def next_u64(mut self) -> UInt64:
        self.state += 0x9E3779B97F4A7C15
        var z = self.state
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) * 0x94D049BB133111EB
        return z ^ (z >> 31)

    def next_f32(mut self) -> Float32:
        return _bits_to_f32(self.next_u64())


@fieldwise_init
struct XorShift64(Rng):
    var state: UInt64

    def __init__(out self):
        self.state = 0x2545F4914F6CDD1D

    @staticmethod
    def seeded(seed: UInt64) -> Self:
        var sm = SplitMix64(seed)
        var s = sm.next_u64()
        if s == 0:
            s = 0x2545F4914F6CDD1D  # xorshift state must be non-zero
        return Self(s)

    def next_u64(mut self) -> UInt64:
        var x = self.state
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        self.state = x
        return x * 0x2545F4914F6CDD1D  # xorshift64*

    def next_f32(mut self) -> Float32:
        return _bits_to_f32(self.next_u64())


@fieldwise_init
struct Pcg32(Rng):
    var state: UInt64
    var inc: UInt64

    def __init__(out self):
        self.state = 0x853C49E6748FEA9B
        self.inc = 0xDA3E39CB94B95BDB

    @staticmethod
    def seeded(seed: UInt64) -> Self:
        var sm = SplitMix64(seed)
        var s0 = sm.next_u64()
        var s1 = sm.next_u64()
        var p = Self(0, (s1 << 1) | 1)  # increment must be odd
        _ = p.next_u32()
        p.state += s0
        _ = p.next_u32()
        return p^

    def next_u32(mut self) -> UInt32:
        var old = self.state
        self.state = old * 6364136223846793005 + self.inc
        var xorshifted = UInt32(((old >> 18) ^ old) >> 27)
        var rot = UInt32(old >> 59)
        return (xorshifted >> rot) | (xorshifted << ((32 - rot) & 31))

    def next_u64(mut self) -> UInt64:
        var hi = UInt64(self.next_u32())
        var lo = UInt64(self.next_u32())
        return (hi << 32) | lo

    def next_f32(mut self) -> Float32:
        return Float32(self.next_u32() >> 8) * Float32(1.0 / 16777216.0)


# --- generic sampling helpers (work over any Rng) ---------------------------

def range_i[R: Rng](mut r: R, lo: Int, hi: Int) -> Int:
    """Uniform integer in [lo, hi)."""
    if hi <= lo:
        return lo
    var span = UInt64(hi - lo)
    return lo + Int(r.next_u64() % span)


def range_f[R: Rng](mut r: R, lo: Float32, hi: Float32) -> Float32:
    """Uniform float in [lo, hi)."""
    return lo + (hi - lo) * r.next_f32()


def unit_vec2[R: Rng](mut r: R) -> Vec2:
    return normalize(Vec2(range_f(r, -1, 1), range_f(r, -1, 1)))


def unit_vec3[R: Rng](mut r: R) -> Vec3:
    return normalize(Vec3(range_f(r, -1, 1), range_f(r, -1, 1), range_f(r, -1, 1)))
