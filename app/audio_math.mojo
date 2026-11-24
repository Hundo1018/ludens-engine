"""Arithmetic the audio path needs, written with + - * / and comparisons only, so every platform gives the same bits.

`exp` / `pow` / `log` in a libm may differ in the last bit between native and wasm64; the mixer's output is compared byte
for byte, so gains come from `db_to_gain` below, not from `pow`. `Rng` is an integer generator: the same seed gives the
same sequence everywhere, which is what lets a replay choose the same clip and pitch."""

comptime LOG2_10_OVER_20: Float64 = 0.16609640474436813  # log2(10) / 20: 2 ** (db * this) = 10 ** (db / 20)


def exp2_f64(x: Float64) -> Float64:
    """2 ** x for -60 <= x <= 60 from a Taylor series of e ** (f ln 2), f in [0, 1); no libm call."""
    var n = Int(x)
    if Float64(n) > x:
        n -= 1  # floor
    var f = x - Float64(n)
    var t = f * 0.6931471805599453
    var term = Float64(1.0)
    var sum = Float64(1.0)
    for k in range(1, 18):
        term = term * t / Float64(k)
        sum += term
    var scale = Float64(1.0)
    if n >= 0:
        for _ in range(n):
            scale *= 2.0
    else:
        for _ in range(-n):
            scale *= 0.5
    return sum * scale


def db_to_gain(db: Float32) -> Float32:
    """10 ** (db / 20). -100 dB and below is exactly 0 (silence)."""
    if db <= -100.0:
        return 0.0
    return Float32(exp2_f64(Float64(db) * LOG2_10_OVER_20))


struct Rng(Copyable, Movable):
    """xorshift64*: 64-bit state, integer only. Seed 0 is replaced by a fixed non-zero state."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed if seed != 0 else UInt64(0x9E3779B97F4A7C15)

    def next_u64(mut self) -> UInt64:
        var x = self.state
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        self.state = x
        return x * UInt64(0x2545F4914F6CDD1D)

    def next_unit(mut self) -> Float32:
        """A value in [0, 1) with 24 random bits (exactly representable in Float32)."""
        return Float32(Float64(self.next_u64() >> 40) / 16777216.0)

    def range(mut self, lo: Float32, hi: Float32) -> Float32:
        return lo + (hi - lo) * self.next_unit()

    def below(mut self, n: Int) -> Int:
        """An integer in [0, n)."""
        if n <= 1:
            return 0
        return Int(self.next_u64() >> 33) % n
