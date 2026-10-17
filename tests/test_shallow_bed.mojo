# tier: integration
"""Shallow water over a bed, with friction (ROADMAP 17.60,
`ShallowWaterFV.set_bed`, `manning`, `well_balanced`).

  1. Ordinary (well balanced): a lake at rest -- surface 1 m -- over a
     Gaussian bump 0.5 m high on a 40 x 40 grid stays at rest after 2 s:
     surface flat and velocity 0 to 1e-6 (Audusse's hydrostatic
     reconstruction). The naive pointwise slope source on the same lake
     makes spurious currents (printed, > 1e-3 m/s): the case the
     reconstruction exists for.
  2. Integration (friction): a uniform 2 m/s flow in 1 m of water in a
     400 m channel with Manning n = 0.03 decelerates as
     du/dt = -g n^2 u^2 / h^(4/3), u(t) = u0 / (1 + k u0 t): the middle
     cell after 5 s is within 1 % of it (the walls' waves have not
     arrived).
  3. Extreme: a bump that rises above the lake's surface (a dry island)
     keeps the lake at rest and the island dry; mass is conserved.
"""

from std.math import exp, sqrt
from harness.runner import Suite
from geometry.vec import Real
from physics.water import ShallowWaterFV

comptime G: Real = 9.8


def _lake(wb: Bool, peak: Real) raises -> ShallowWaterFV:
    var w = ShallowWaterFV(40, 40, 0.5, 0, 0, 0, G)
    w.well_balanced = wb
    for j in range(40):
        for i in range(40):
            var x = (Real(i) - 19.5) * 0.5
            var z = (Real(j) - 19.5) * 0.5
            var b = peak * exp(-(x * x + z * z) / 9)
            w.set_bed(i, j, b)
            w.h[j * 40 + i] = max(Real(1) - b, Real(0))
    return w^


def _run(mut w: ShallowWaterFV, secs: Real) raises:
    var t = Real(0)
    while t < secs:
        var dt = min(w.max_dt(), secs - t)
        w.step(dt)
        t += dt


def _stir(w: ShallowWaterFV) -> Tuple[Real, Real]:
    """(max |surface - 1| over wet cells, max |u|)."""
    var dev = Real(0)
    var sp = Real(0)
    for k in range(40 * 40):
        if w.h[k] > 1e-6:
            dev = max(dev, abs(w.h[k] + w.zb[k] - 1))
            sp = max(sp, (w.hu[k] * w.hu[k] + w.hv[k] * w.hv[k]) ** 0.5 / w.h[k])
    return (dev, sp)


def main() raises:
    var s = Suite("shallow_bed")
    var wb = _lake(True, 0.5)
    var nv = _lake(False, 0.5)
    _run(wb, 2)
    _run(nv, 2)
    var a = _stir(wb)
    var b = _stir(nv)
    print("  lake over a 0.5 m bump, 2 s: well balanced surface dev", a[0], " max |u|", a[1], ";  naive source", b[0], b[1])
    s.check(a[0] < 1e-6 and a[1] < 1e-6, "well balanced: the lake at rest stays at rest")
    s.check(b[1] > 1e-3, "the naive slope source stirs it (the failure the reconstruction prevents)")

    var ch = ShallowWaterFV(400, 1, 1, 0, 0, 0, G)
    ch.manning = 0.03
    for i in range(400):
        ch.h[i] = 1
        ch.hu[i] = 2
    _run(ch, 5)
    var k = G * 0.03 * 0.03
    var want = 2 / (1 + k * 2 * 5)
    var got = ch.hu[200] / ch.h[200]
    print("  Manning n 0.03, 1 m deep, 2 m/s, after 5 s: middle cell u", got, " analytic", want)
    s.check(abs(got / want - 1) < 0.01, "friction decelerates the flow as Manning's law (1 %)")

    var isl = _lake(True, 1.5)
    var v0 = isl.total_volume()
    _run(isl, 2)
    var c = _stir(isl)
    var dry_top = isl.h[20 * 40 + 20]
    print("  island 1.5 m in a 1 m lake, 2 s: surface dev", c[0], " max |u|", c[1], " island top depth", dry_top, " volume", v0, "->", isl.total_volume())
    s.check(c[1] < 1e-5 and dry_top == 0 and abs(isl.total_volume() / v0 - 1) < 1e-5, "a dry island: still at rest, still dry, mass kept")
    s.finish()
