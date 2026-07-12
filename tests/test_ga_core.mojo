"""GA core identities (G1): property tests over random multivectors.

The same `Multivector[p,q,r]` code is exercised under two signatures — 2D PGA
Cl(2,0,1) and 3D PGA Cl(3,0,1) — proving the signature-generic product tables.
Randomness comes from the engine's `Rng` seam (SplitMix64, fixed seed) so runs
are reproducible.
"""

from harness.runner import Suite
from scheduler.rng import SplitMix64, Rng
from geometry.multivector import Multivector, PGA2, PGA3
from geometry.vec import Real


def _rand_mv[
    p: Int, q: Int, r: Int
](mut rng: SplitMix64) -> Multivector[p, q, r]:
    var out = Multivector[p, q, r]()
    comptime for i in range(Multivector[p, q, r].BLADES):
        out.c[i] = Real(rng.next_f32() * 2.0 - 1.0)
    return out^


def check_algebra[p: Int, q: Int, r: Int](mut s: Suite, tag: String):
    comptime MV = Multivector[p, q, r]
    var rng = SplitMix64.seeded(42)

    # --- product laws on random multivectors ---
    for _ in range(8):
        var a = _rand_mv[p, q, r](rng)
        var b = _rand_mv[p, q, r](rng)
        var cc = _rand_mv[p, q, r](rng)
        s.check((a * b * cc).approx_eq(a * (b * cc)), tag + ": gp associative")
        s.check(
            (a * (b + cc)).approx_eq(a * b + a * cc), tag + ": gp distributes"
        )
        s.check(
            (a * b).reverse().approx_eq(b.reverse() * a.reverse()),
            tag + ": reverse anti-automorphism",
        )
        s.check(
            a.wedge(b.wedge(cc)).approx_eq(a.wedge(b).wedge(cc)),
            tag + ": wedge associative",
        )
        # grade decomposition sums back to the original
        var sum = MV()
        for k in range(MV.DIM + 1):
            sum = sum + a.grade(k)
        s.check(sum.approx_eq(a), tag + ": grade decomposition")

    # --- vector-level identities ---
    for i in range(MV.DIM):
        var v = MV.basis(1 << i)
        s.check(v.wedge(v).approx_eq(MV()), tag + ": v∧v = 0")
        for j in range(MV.DIM):
            if i == j:
                continue
            var w = MV.basis(1 << j)
            s.check(
                v.wedge(w).approx_eq(w.wedge(v).scaled(-1)),
                tag + ": wedge antisymmetric",
            )

    # --- metric: first p vectors square +1, the r trailing ones to 0 ---
    for i in range(MV.DIM):
        var v = MV.basis(1 << i)
        var sq = (v * v).scalar_part()
        if i < p:
            s.almost(Float64(sq), 1.0, tag + ": e+^2 = +1")
        elif i >= p + q:
            s.almost(Float64(sq), 0.0, tag + ": e0^2 = 0 (degenerate)")

    # --- dual: every blade satisfies e_A ∧ rc(e_A) = I ---
    var pss = MV.basis(MV.PSS)
    for m in range(MV.BLADES):
        var blade = MV.basis(m)
        s.check(
            blade.wedge(blade.right_complement()).approx_eq(pss),
            tag + ": e∧rc(e) = I",
        )


def main() raises:
    var s = Suite("ga_core")
    check_algebra[2, 0, 1](s, "PGA2")
    check_algebra[3, 0, 1](s, "PGA3")

    # spot identity: e1 ⌋ (e1∧e2) = e2 in PGA3
    var e1 = PGA3.basis(0b0001)
    var e2 = PGA3.basis(0b0010)
    s.check(
        e1.lcont(e1.wedge(e2)).approx_eq(e2), "lcont: e1 ⌋ e12 = e2"
    )
    s.finish()
