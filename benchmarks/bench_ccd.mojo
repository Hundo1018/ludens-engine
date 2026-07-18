"""CCD stage cost: speculative (inflated manifold) vs swept/TOI linear cast.

The two tunnelling defenses price differently per pair (parity + guarantees in
`test_ccd6`): the speculative stage pays an inflated `box_box_manifold` (full
15-axis SAT + face clipping on fattened boxes) for every nearby pair, while the
swept stage pays a `swept_box_toi` (15-axis interval sweep, no clipping) only
for pairs whose relative travel can jump a feature. Same deterministic
high-speed scene for both rows — bullet-grade displacements (2-4 box lengths
per step) against rotated targets.
Run with: `mojo run -I build benchmarks/bench_ccd.mojo`.
"""

from std.math import sqrt, sin, cos
from std.benchmark import keep
from geometry.vec import Real, Vec3, dot
from collision.manifold import Axes3, box_box_manifold
from collision.toi import swept_box_toi
from harness.bench import BenchTable, now


struct Rng(Movable):
    """A tiny LCG so scenes are deterministic across variants."""

    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next_f(mut self) -> Real:
        self.state = self.state * 6364136223846793005 + 1442695040888963407
        return Real(Float64((self.state >> 16) % 1_000_000) / 1_000_000.0)


def _axes(theta: Real, phi: Real) -> Axes3:
    """Orthonormal box axes from two rotation angles (Rz then Rx tilt)."""
    var ct = cos(theta)
    var st = sin(theta)
    var cp = cos(phi)
    var sp = sin(phi)
    var a = Axes3(fill=Vec3(0, 0, 0))
    a[0] = Vec3(ct, st, 0)
    a[1] = Vec3(-st * cp, ct * cp, sp)
    a[2] = Vec3(st * sp, -ct * sp, cp)
    return a


@fieldwise_init
struct _Cast(Copyable, ImplicitlyCopyable, Movable):
    """One high-speed candidate pair (struct-wrapped: bare List[SIMD3] hazard)."""

    var ca: Vec3
    var axa: Axes3
    var ha: Vec3
    var cb: Vec3
    var axb: Axes3
    var hb: Vec3
    var disp: Vec3  # per-step displacement of b relative to a


def _scene(n: Int) -> List[_Cast]:
    var rng = Rng(0xCCD)
    var casts = List[_Cast]()
    for _ in range(n):
        var axa = _axes(rng.next_f() * 6.28, rng.next_f() * 3.14)
        var axb = _axes(rng.next_f() * 6.28, rng.next_f() * 3.14)
        var ca = Vec3(rng.next_f(), rng.next_f(), rng.next_f())
        # target sits 1-3 units up-range along x, slight lateral scatter
        var cb = ca + Vec3(
            1.0 + 2.0 * rng.next_f(),
            (rng.next_f() - 0.5) * 0.8,
            (rng.next_f() - 0.5) * 0.8,
        )
        # bullet-grade approach: 2-4 units per step back toward a
        var disp = Vec3(
            -(2.0 + 2.0 * rng.next_f()),
            (rng.next_f() - 0.5) * 0.4,
            (rng.next_f() - 0.5) * 0.4,
        )
        casts.append(_Cast(
            ca, axa, Vec3(0.3, 0.3, 0.3), cb, axb, Vec3(0.1, 0.1, 0.1), disp
        ))
    return casts^


def main() raises:
    comptime N = 20000
    comptime SPEC_BASE: Real = 0.02
    var table = BenchTable("CCD stages (high-speed pairs, per pair)")
    var casts = _scene(N)

    # Speculative stage: inflate both boxes by the travel-scaled margin, run
    # the full contact manifold, subtract the margin back from the depths —
    # exactly what `_collect_pairs(spec_dt > 0)` pays per candidate pair.
    var hits_spec = 0
    var t0 = now()
    for k in range(len(casts)):
        var c = casts[k]
        var margin = SPEC_BASE + sqrt(dot(c.disp, c.disp))
        var infl = Vec3(margin * 0.5, margin * 0.5, margin * 0.5)
        var m = box_box_manifold(
            c.ca, c.axa, c.ha + infl, c.cb, c.axb, c.hb + infl
        )
        if m.hit:
            for p in range(m.count):
                m.depths[p] -= margin
            hits_spec += 1
    keep(hits_spec)
    var t1 = now()
    table.add(
        "speculative manifold hits=" + String(hits_spec), N, "pair", t1 - t0, N
    )

    # Swept stage: exact 15-axis interval cast along the displacement.
    var hits_toi = 0
    var t_sum = Real(0)
    t0 = now()
    for k in range(len(casts)):
        var c = casts[k]
        var r = swept_box_toi(c.ca, c.axa, c.ha, c.cb, c.axb, c.hb, c.disp)
        if r.hit:
            hits_toi += 1
            t_sum += r.t
    keep(hits_toi)
    keep(t_sum)
    t1 = now()
    table.add("swept toi cast hits=" + String(hits_toi), N, "pair", t1 - t0, N)

    table.print_report()
