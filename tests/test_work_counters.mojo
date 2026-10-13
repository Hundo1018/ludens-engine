# tier: integration
"""Workload counters are exact and machine-independent (ROADMAP 17.83).

`diag.counters` NARROWPHASE_PAIRS / CONTACT_MANIFOLDS / CONTACT_POINTS count
work, not failures, so a CI host can assert them exactly where a wall-clock
gate would only see noise. Scene: N spheres (r = 0.4) resting on a static
ground box, spaced 2 m apart so no two spheres touch.

  1. Ordinary: brute-force enumeration hands the narrowphase every pair with a
     dynamic side, N + N(N-1)/2 per step; the broadphase hands it only the N
     sphere-ground pairs. Both find N manifolds of one point each.
  2. Integration (the detector): the brute count grows as N^2 while the
     broadphase count grows as N -- the counter, not a timer, is what exposes
     an O(n^2) enumeration (the F22 class of regression), and it does so with
     an exact number.
  3. Extreme: N = 1 (one pair either way); no dynamic body (zero pairs).
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from diag.counters import NARROWPHASE_PAIRS, CONTACT_MANIFOLDS, CONTACT_POINTS
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0


def _scene(n: Int, dynamic: Bool) -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 500, 0.5, 500)),
        Vec3(500, 0.5, 500, 0),
        True,
    )
    for i in range(n):
        var b = QuatBody6.at_rest(Vec3(Real(2 * i), 0.4, 0, 0), Inertia3.sphere(1, 0.4))
        _ = sc.add_sphere(b^, 0.4, not dynamic)
    return sc^


def _counts(n: Int, bp: Bool, dynamic: Bool = True) -> Tuple[Int, Int, Int]:
    """Counters after exactly one step."""
    var sc = _scene(n, dynamic)
    sc.step_soft(DT, Vec3(0, -9.8, 0, 0), broadphase=bp)
    return (
        Int(sc.counters.get(NARROWPHASE_PAIRS)),
        Int(sc.counters.get(CONTACT_MANIFOLDS)),
        Int(sc.counters.get(CONTACT_POINTS)),
    )


def main() raises:
    var s = Suite("work_counters")

    # ---- 1. exact counts, brute vs broadphase --------------------------
    for n in [4, 16, 64]:
        var brute = _counts(n, False)
        var bp = _counts(n, True)
        print("  N =", n, " brute pairs", brute[0], " bp pairs", bp[0], " manifolds", brute[1], bp[1], " points", brute[2], bp[2])
        s.check(brute[0] == n + n * (n - 1) // 2, "N=" + String(n) + ": brute pairs == N + N(N-1)/2")
        s.check(bp[0] == n, "N=" + String(n) + ": broadphase pairs == N (sphere-ground only)")
        s.check(brute[1] == n and bp[1] == n, "N=" + String(n) + ": N manifolds either way")
        s.check(brute[2] == n and bp[2] == n, "N=" + String(n) + ": one point per sphere manifold")

    # ---- 2. the detector: growth ratio over N x4 -----------------------
    var b16 = _counts(16, False)[0]
    var b64 = _counts(64, False)[0]
    var p16 = _counts(16, True)[0]
    var p64 = _counts(64, True)[0]
    print("  N x4: brute pairs x", Float64(b64) / Float64(b16), " broadphase pairs x", Float64(p64) / Float64(p16))
    s.check(b64 * 10 > b16 * 150, "brute enumeration grows ~N^2 (x15.2 for N x4)")
    s.check(p64 == 4 * p16, "broadphase enumeration grows exactly N (x4)")

    # ---- 3. extremes ---------------------------------------------------
    var one = _counts(1, False)
    s.check(one[0] == 1 and one[1] == 1, "N=1: one pair, one manifold")
    var none = _counts(8, False, False)
    s.check(none[0] == 0 and none[1] == 0, "no dynamic body: zero pairs reach the narrowphase")

    s.finish()
