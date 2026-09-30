"""W1 cross-check, native side: the op sequence of
tests/differential/sparse_set.test.mjs on dev's `ecs.SparseSet`, run natively.

    native_oracle <seed> <steps> [fixed_size=64]
    -> digest=<hex> len=<n>

Per step: key = floor(u / 2^32 * fixed), add if u / 2^32 < 0.6 else remove,
with u from mulberry32 (tests/differential/lib/rng.mjs, same float64
arithmetic). After each step the digest folds in len and every dense key
(FNV-1a over 32-bit words). tests/differential/digest.mjs computes the same
digest from a wasm module; native_vs_wasm.py compares the two.
"""
from std.sys import argv
from ecs.sparse_set import SparseSet


struct Mulberry32:
    var a: UInt32

    def __init__(out self, seed: UInt32):
        self.a = seed

    def next(mut self) -> Float64:
        self.a = self.a + 0x6D2B79F5
        var a = self.a
        var t = (a ^ (a >> 15)) * (1 | a)
        t = (t + ((t ^ (t >> 7)) * (61 | t))) ^ t
        return Float64(t ^ (t >> 14)) / 4294967296.0


def fnv(h: UInt32, v: UInt32) -> UInt32:
    return (h ^ v) * 16777619


def main() raises:
    var args = argv()
    var seed = UInt32(atol(String(args[1])))
    var steps = atol(String(args[2]))
    var fixed = atol(String(args[3])) if len(args) > 3 else 64
    var rnd = Mulberry32(seed)
    var s = SparseSet[Int32]()
    var h: UInt32 = 2166136261
    for _ in range(steps):
        var key = Int(rnd.next() * Float64(fixed))
        if rnd.next() < 0.6:
            if key >= 0 and key < fixed:
                s.add(key, Int32(key))
        else:
            s.remove(key)
        h = fnv(h, UInt32(len(s)))
        for i in range(len(s)):
            h = fnv(h, UInt32(s.key_at(i)))
    print("digest=", hex(h), " len=", len(s), sep="")
