# tier: integration
"""Unit-scale similarity (ROADMAP 17.75): lengths x 2^k, `UnitScale(2^k)`.

Scale every length in a scene by s = 2^k -- positions, half-extents, radii,
velocities, gravity -- leave mass and time alone, and step with
`UnitScale(s).apply(SolverConfig())`. In float32 multiplying by a power of
two is exact, |s d| = s |d| exactly (sqrt of a power-of-four multiple), and
inertia scales by s^2 exactly, so a solver with no hard-coded absolute
lengths follows the original trajectory times s. Any deviation comes from an
absolute constant that `UnitScale` does not scale -- the deviation list is a
defect list.

Scene: a three-box stack, a rolling sphere and a capsule on a static ground
box, 180 steps of 1/60 s, sleeping on.

  1. Ordinary: s = 1 is bit-identical to the plain config (UnitScale(1) is a
     no-op).
  2. Integration: s = 2^-3, 2^4, 2^7 (an engine in mm-ish and in cm units):
     every body's position / s is bit-identical to the s = 1 run. (Until
     ROADMAP 17.19 the boxes and the capsule drifted by up to 3.1e-5: box
     axes were taken as act(unit) - act(0), rounding against the position,
     and two manifold tolerances were absolute lengths.)
  3. Extreme: s = 2^-7 and 2^10, same; and the control -- the s = 2^7
     scene stepped WITHOUT UnitScale deviates by more than 0.1.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig, UnitScale

comptime DT: Real = 1.0 / 60.0


def _scene(s: Real) -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -0.5 * s, 0, 0), Inertia3.box(1, 20 * s, 0.5 * s, 20 * s)),
        Vec3(20 * s, 0.5 * s, 20 * s, 0),
        True,
    )
    for j in range(3):
        _ = sc.add(
            QuatBody6.at_rest(Vec3(0, (0.25 + 0.5 * Real(j)) * s, 0, 0), Inertia3.box(1, 0.25 * s, 0.25 * s, 0.25 * s)),
            Vec3(0.25 * s, 0.25 * s, 0.25 * s, 0),
            False,
        )
    var b = QuatBody6.at_rest(Vec3(3 * s, 0.5 * s, 0, 0), Inertia3.sphere(1, 0.5 * s))
    b.vel = Vec3(2 * s, 0, 0, 0)
    _ = sc.add_sphere(b^, 0.5 * s, False)
    var c = QuatBody6.at_rest(Vec3(-3 * s, 0.3 * s, 0, 0), Inertia3.capsule(1, 0.3 * s, 0.6 * s))
    c.vel = Vec3(0, 0, 1 * s, 0)
    _ = sc.add_capsule(c^, 0.3 * s, 0.6 * s, False)
    return sc^


def _run(s: Real, cfg: SolverConfig) -> List[Vec3]:
    var sc = _scene(s)
    for _ in range(180):
        sc.step(DT, Vec3(0, -9.8 * s, 0, 0), cfg)
    var out = List[Vec3]()
    for i in range(len(sc.bset.bodies)):
        out.append(sc.bset.bodies[i].position() / s)
    return out^


def _worst(a: List[Vec3], b: List[Vec3]) -> Float64:
    var w = Float64(0)
    for i in range(len(a)):
        for k in range(3):
            w = max(w, Float64(abs(a[i][k] - b[i][k])))
    return w


def main() raises:
    var s = Suite("unit_scale")
    var base = SolverConfig()
    var ref1 = _run(1, base)

    var one = _run(1, UnitScale(1).apply(base))
    s.check(_worst(ref1, one) == 0, "UnitScale(1) is bit-identical to the plain config")

    for k in [-7, -3, 4, 7, 10]:
        var sc = Real(1)
        if k > 0:
            for _ in range(k):
                sc *= 2
        else:
            for _ in range(-k):
                sc /= 2
        var got = _run(sc, UnitScale(sc).apply(base))
        var w = _worst(ref1, got)
        var line = String("  s = 2^") + String(k) + ": per body |pos/s - pos_1|:"
        for i in range(len(ref1)):
            var wi = Float64(0)
            for c in range(3):
                wi = max(wi, Float64(abs(ref1[i][c] - got[i][c])))
            line += " " + String(wi)
        print(line)
        var sphere_exact = True
        for c in range(3):
            if ref1[4][c] != got[4][c]:
                sphere_exact = False
        s.check(sphere_exact, "s = 2^" + String(k) + ": sphere trajectory / s bit-identical to s = 1")
        s.check(w == 0, "s = 2^" + String(k) + ": every body's trajectory / s bit-identical to s = 1")

    # The control: the same scaled scene WITHOUT UnitScale must deviate,
    # otherwise the test cannot tell a scaled tolerance from an unused one.
    var unscaled = _run(128, base)
    var wu = _worst(ref1, unscaled)
    print("  s = 2^7 without UnitScale: worst |pos/s - pos_1| =", wu)
    s.check(wu > 0.1, "control: s = 2^7 with unscaled tolerances deviates by > 0.1")
    s.finish()
