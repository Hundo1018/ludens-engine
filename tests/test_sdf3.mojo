"""3D SDF fields and contact.

Two things are checked separately because they fail for different reasons.

The FIELD must be a true signed distance: value zero on the surface, negative
inside, and a unit gradient. Unit gradient is the one worth asserting — a
field that is merely the right sign but wrongly scaled still classifies points
correctly and then makes the contact descent take wrong-sized steps, which
shows up as slow or failed convergence rather than as a wrong answer.

The CONTACT must agree with the analytic pair where one exists. Sphere-sphere
has a closed form, so an SDF sphere against an SDF sphere is checkable against
it exactly; that is the calibration. CSG shapes have no closed form, so they
are checked on properties instead — a box with a sphere bitten out of it must
report no contact for a probe sitting in the bite.
"""

from std.math import sqrt
from harness.runner import Suite
from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real, Vec3, length, normalize
from geometry.sdf3 import (
    Sdf3, sdf_contact, OP_SUBTRACT, OP_UNION, OP_INTERSECT,
)


def main() raises:
    var s = Suite("sdf3")
    var rng = SplitMix64.seeded(131)

    # ---- 1. the field is a true distance ----
    var sph = Sdf3.sphere(Vec3(0.3, -0.2, 0.5), 1.4)
    var bx = Sdf3.box(Vec3(-0.5, 0.1, 0.2), Vec3(0.8, 1.1, 0.6))
    var cap = Sdf3.capsule(Vec3(0.0, 0.0, 0.0), 0.5, 0.9)
    var pl = Sdf3.plane(Vec3(0.2, 1.0, -0.1), 0.4)

    var worst_sph = Real(0)
    for _ in range(300):
        var p = Vec3(
            Real(rng.next_f32()) * 8 - 4,
            Real(rng.next_f32()) * 8 - 4,
            Real(rng.next_f32()) * 8 - 4,
        )
        var want = length(p - Vec3(0.3, -0.2, 0.5)) - 1.4
        var e = abs(sph.distance(p) - want)
        if e > worst_sph:
            worst_sph = e
    s.check(worst_sph < 1e-4, "sphere field == analytic distance")

    # gradient must be UNIT for every primitive (away from the medial axis)
    var worst_grad = Real(0)
    for _ in range(200):
        var p = Vec3(
            Real(rng.next_f32()) * 6 - 3,
            Real(rng.next_f32()) * 6 - 3,
            Real(rng.next_f32()) * 6 - 3,
        )
        for k in range(4):
            var f = sph
            if k == 1:
                f = bx
            elif k == 2:
                f = cap
            elif k == 3:
                f = pl
            if abs(f.distance(p)) < 0.05:
                continue  # skip the surface band, where CD is noisiest
            var e = abs(length(f.gradient(p)) - 1.0)
            if e > worst_grad:
                worst_grad = e
    print("  worst |grad| - 1:", worst_grad)
    s.check(worst_grad < 1e-2, "every primitive has a unit gradient")

    # a box's outside distance is exact; inside it is the (negative) max face
    var bpt = Vec3(-0.5, 0.1, 0.2) + Vec3(2.8, 0, 0)  # 2.0 outside the +x face
    s.check(abs(bx.distance(bpt) - 2.0) < 1e-4, "box exterior distance exact")
    s.check(bx.distance(Vec3(-0.5, 0.1, 0.2)) < 0, "box centre is inside")

    # ---- 2. contact calibrated against the analytic sphere pair ----
    var worst_depth = Real(0)
    var agree = 0
    var total = 0
    for _ in range(120):
        var ca = Vec3(
            Real(rng.next_f32()) * 2 - 1,
            Real(rng.next_f32()) * 2 - 1,
            Real(rng.next_f32()) * 2 - 1,
        )
        var cb = ca + Vec3(
            Real(rng.next_f32()) * 3 - 1.5,
            Real(rng.next_f32()) * 3 - 1.5,
            Real(rng.next_f32()) * 3 - 1.5,
        )
        var ra = Real(rng.next_f32()) * 0.6 + 0.4
        var rb = Real(rng.next_f32()) * 0.6 + 0.4
        var d = length(cb - ca)
        var want_hit = d < ra + rb
        var want_depth = (ra + rb - d) if want_hit else Real(0)
        if abs(d - (ra + rb)) < 0.02:
            continue  # skip the touching boundary
        total += 1
        var c = sdf_contact(
            Sdf3.sphere(ca, ra), Sdf3.sphere(cb, rb), (ca + cb) * 0.5
        )
        if c.hit == want_hit:
            agree += 1
        if want_hit:
            var e = abs(c.depth - want_depth)
            if e > worst_depth:
                worst_depth = e
    print("  sphere-pair: hit agreement", agree, "/", total,
          " worst depth error", worst_depth)
    s.eqi(agree, total, "SDF contact classifies exactly like the analytic pair")
    s.check(worst_depth < 5e-2, "SDF penetration depth matches the analytic one")

    # ---- 3. CSG: a box with a sphere bitten out ----
    #      The bite is real geometry, so a probe inside it must NOT be inside
    #      the shape — the property that separates a CSG field from its base.
    var bitten = Sdf3.box(Vec3(0, 0, 0), Vec3(1, 1, 1)).combined(
        OP_SUBTRACT, Sdf3.sphere(Vec3(1, 0, 0), 0.7)
    )
    s.check(bitten.distance(Vec3(0, 0, 0)) < 0, "the box body is still solid")
    s.check(
        bitten.distance(Vec3(0.95, 0, 0)) > 0,
        "a point inside the bite is OUTSIDE the shape",
    )
    s.check(
        bitten.distance(Vec3(-0.9, 0, 0)) < 0,
        "the far side of the box is unaffected by the bite",
    )

    # a probe sphere sitting in the bite must not report contact
    var probe = Sdf3.sphere(Vec3(1.05, 0, 0), 0.15)
    var cb2 = sdf_contact(bitten, probe, Vec3(1.0, 0, 0))
    s.check(not cb2.hit, "a sphere resting in the bite does not collide")
    var probe2 = Sdf3.sphere(Vec3(-0.9, 0, 0), 0.3)
    var cb3 = sdf_contact(bitten, probe2, Vec3(-0.9, 0, 0))
    s.check(cb3.hit, "a sphere buried in the solid side does collide")

    s.finish()
