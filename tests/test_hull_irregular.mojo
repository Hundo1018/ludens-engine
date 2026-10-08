# tier: integration
"""Irregular hulls in the production solver (ROADMAP 17.5 groundwork).

Fracture fragments are convex hulls of arbitrary shape, and until now only
boxes and a regular tetrahedron had ever been dropped on a floor. Irregular
hulls sank through it. The cause was the speculative margin: `as_hull` inflated
a hull by pushing each vertex out along its own octant, which keeps a BOX's
faces flat but bends every other hull's, so only one vertex of a sloped face
still counted as lying on it; the contact patch collapsed to a single point that
hopped from frame to frame and the hull rocked and sank. Hulls are no longer
inflated: `hull_manifold` takes the margin and produces the speculative contact
(negative depth) itself.

  ordinary     a right triangular prism dropped apex-down topples onto a face
               and rests; a sphere-like 14-vertex hull rests.
  integration  jittered cubes (no face is exactly flat) from several angles come
               to rest above the floor; irregular hulls fall asleep.
  extreme      speculative contact at the manifold level: hulls a gap apart
               produce a contact with negative depth only inside the margin and
               only along a face axis; margin 0 is exactly the old behaviour.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.gjk import ConvexPoly
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from collision.hull import HullShape, hull_manifold

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _lowest(sc: ContactScene6[QuatBody6], b: Int, v: List[Real]) -> Float64:
    var wl = 1e9
    for i in range(len(v) // 3):
        var w = sc.bset.bodies[b].act(Vec3(v[3 * i], v[3 * i + 1], v[3 * i + 2], 0))
        wl = min(wl, Float64(w[1]))
    return wl


def _drop(v: List[Real], y0: Real, frames: Int) raises -> List[Float64]:
    """Drop a hull on a floor; [lowest world vertex y, asleep]."""
    var vc = v.copy()
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 30, 1, 30)),
        Vec3(30, 1, 30, 0), True,
    )
    var b = sc.add_hull(
        QuatBody6.at_rest(Vec3(0, y0, 0, 0), Inertia3.box(5, 0.25, 0.25, 0.25)), v.copy(), False
    ).index()
    for _ in range(frames):
        sc.step_soft(DT, G)
    var out = List[Float64](capacity=2)
    out.append(_lowest(sc, b, vc))
    out.append(1.0 if sc.bset.sleeping[b] else 0.0)
    return out^


def _prism() -> List[Real]:
    var v = List[Real]()
    for q in [
        -0.25, 0.16666666666666666, 0.25, -0.25, 0.16666666666666666, -0.25,
        0.125, -0.33333333333333337, -0.25, 0.125, 0.16666666666666666, -0.25,
        0.125, 0.16666666666666666, 0.25, 0.125, -0.33333333333333337, 0.25,
    ]:
        v.append(Real(q))
    return v^


def _jittered_cube(seed: Int, jit: Float64) -> List[Real]:
    var rng = UInt64(seed * 7919 + 13)
    var v = List[Real]()
    for k in range(8):
        for a in range(3):
            rng = rng * 6364136223846793005 + 1442695040888963407
            var r = Float64((rng >> 33) % 2001) / 1000.0 - 1.0
            var base = 0.25 if ((k >> a) & 1) == 1 else -0.25
            v.append(Real(base + jit * r))
    return v^


def _ball(seed: Int) -> List[Real]:
    var rng = UInt64(seed * 7919 + 13)
    var v = List[Real]()
    for _ in range(14):
        while True:
            rng = rng * 6364136223846793005 + 1442695040888963407
            var x = Float64((rng >> 33) % 2001) / 1000.0 - 1.0
            rng = rng * 6364136223846793005 + 1442695040888963407
            var y = Float64((rng >> 33) % 2001) / 1000.0 - 1.0
            rng = rng * 6364136223846793005 + 1442695040888963407
            var z = Float64((rng >> 33) % 2001) / 1000.0 - 1.0
            var l = (x * x + y * y + z * z) ** 0.5
            if l > 0.3 and l < 1.0:
                v.append(Real(0.3 * x / l))
                v.append(Real(0.3 * y / l))
                v.append(Real(0.3 * z / l))
                break
    return v^


def main() raises:
    var s = Suite("hull_irregular")

    # ---- ordinary --------------------------------------------------------
    var pr = _drop(_prism(), 0.9, 300)
    print("  prism apex-down: lowest vertex", pr[0], "asleep", pr[1])
    s.check(pr[0] > -0.02, "a triangular prism dropped apex-down does not sink")
    s.check(pr[1] > 0.5, "...and falls asleep")
    var rested = 0
    var slept = 0
    for seed in range(6):
        var r = _drop(_ball(seed), 0.8, 300)
        if r[0] > -0.02:
            rested += 1
        if r[1] > 0.5:
            slept += 1
    print("  14-vertex balls: rested", rested, "of 6, asleep", slept)
    s.check(rested >= 5, "sphere-like irregular hulls rest above the floor (>= 5 of 6)")

    # ---- integration -----------------------------------------------------
    var ok = 0
    var asleep = 0
    for seed in range(8):
        var r = _drop(_jittered_cube(seed, 0.03), 0.6, 360)
        if r[0] > -0.02:
            ok += 1
        if r[1] > 0.5:
            asleep += 1
    print("  jittered cubes: rested", ok, "of 8, asleep", asleep)
    s.check(ok >= 7, "jittered cubes rest above the floor (>= 7 of 8; was 3 of 8)")
    s.check(asleep >= 5, "and most fall asleep")

    # ---- extreme: speculative contact at the manifold ---------------------
    var a = _jittered_cube(1, 0.0)  # a clean cube, +-0.25
    var fa = HullShape(a.copy())
    var ex = Vec3(1, 0, 0, 0)
    var ey = Vec3(0, 1, 0, 0)
    var ez = Vec3(0, 0, 1, 0)
    var zero = Vec3(0, 0, 0, 0)
    var na = fa.world_normals(ex, ey, ez)
    var pa = fa.world(zero, ex, ey, ez)
    # upper cube, 1 cm above the lower one's top face (0.25): gap = 0.01
    var pb = fa.world(Vec3(0, 0.51, 0, 0), ex, ey, ez)
    var none = hull_manifold(pa, pb, na, na)
    s.check(not none.hit, "margin 0: a gap is a miss (the old behaviour)")
    var near = hull_manifold(pa, pb, na, na, 0.02)
    s.check(near.hit and near.count == 4, "margin 0.02: a 1 cm gap is a speculative 4-point contact")
    s.almost(Float64(near.depths[0]), -0.01, "...at depth -gap", 1e-5)
    s.almost(Float64(near.normal[1]), 1.0, "...normal a -> b", 1e-6)
    var far = fa.world(Vec3(0, 0.56, 0, 0), ex, ey, ez)
    s.check(not hull_manifold(pa, far, na, na, 0.02).hit, "a 6 cm gap is beyond a 2 cm margin")
    var over = fa.world(Vec3(0, 0.45, 0, 0), ex, ey, ez)
    var m0 = hull_manifold(pa, over, na, na)
    var m2 = hull_manifold(pa, over, na, na, 0.02)
    s.check(m0.hit and m2.hit and m0.count == m2.count, "a real overlap is unchanged by a margin")
    s.almost(Float64(m0.depths[0]), 0.05, "...depth 0.05", 1e-5)
    s.almost(Float64(m2.depths[0]), 0.05, "...also with a margin", 1e-5)
    s.finish()
