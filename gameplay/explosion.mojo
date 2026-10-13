"""Explosions (ROADMAP 17.71).

`explode(scene, center, radius, impulse, samples)` pushes every dynamic
body overlapping the blast sphere:

  * line of sight: rays from the centre to `samples` points of the body
    (its centre, and with 9 the eight corners of its box pulled 20 % in); a
    point counts as exposed when the first thing the ray hits is the body
    itself. The exposed fraction scales the impulse, so a crate behind a
    wall is not pushed;
  * falloff: linear in centre distance, 1 at the centre, 0 at `radius`;
  * the impulse is applied at the mean of the exposed points along the
    direction from the centre to it, so a half-hidden body also spins
    (`fields.FIELD_RADIAL` applies at the centre of mass: no torque);
  * sleeping bodies are woken (`apply_impulse(..., wake=True)`).

A body whose centre coincides with the blast centre (closer than 1e-9 m) is
pushed straight up instead of along an undefined direction.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, length
from collision.world_query import QueryFilter
from collision.broadphase import BroadPhase
from physics.rigid6 import Body6
from physics.solver6 import ContactScene6


@fieldwise_init
struct BlastReport(Copyable, Movable):
    var bodies: List[Int]
    var exposure: List[Real]
    var impulse: List[Vec3]


def explode[B: Body6, BP: BroadPhase](
    mut sc: ContactScene6[B, BP], center: Vec3, radius: Real, impulse: Real,
    samples: Int = 9, filter: QueryFilter = QueryFilter.all(),
) raises -> BlastReport:
    var rep = BlastReport(List[Int](), List[Real](), List[Vec3]())
    if not (radius > 0) or not (impulse > 0):
        return rep^
    var near = sc.overlap_sphere(center, radius, filter)
    for i in near:
        if not sc.bset.is_dynamic(i):
            continue
        var c = sc.bset.bodies[i].act(Vec3(0, 0, 0, 0))
        var h = sc.colliders.half[i] * 0.8
        var pts = List[Vec3]()
        pts.append(c)
        if samples >= 9:
            for k in range(8):
                pts.append(sc.bset.bodies[i].act(Vec3(h[0] if k & 1 else -h[0], h[1] if k & 2 else -h[1], h[2] if k & 4 else -h[2], 0)))
        var seen = 0
        var sum = Vec3(0, 0, 0, 0)
        for p in pts:
            var d = p - center
            var l = length(d)
            if l < 1e-9:
                seen += 1
                sum = sum + p
                continue
            var hit = sc.ray_cast(center, d / l, l, filter)
            if not hit.hit or hit.body == i:
                seen += 1
                sum = sum + p
        if seen == 0:
            continue
        var at = sum / Real(seen)
        var dc = length(c - center)
        var fall = max(Real(0), 1 - dc / radius)
        var dir = at - center
        var dl = length(dir)
        dir = dir / dl if dl >= 1e-9 else Vec3(0, 1, 0, 0)
        var frac = Real(seen) / Real(len(pts))
        var j = dir * (impulse * fall * frac)
        sc.apply_impulse(sc.bset.id_of(i), j, at, True)
        rep.bodies.append(i)
        rep.exposure.append(frac)
        rep.impulse.append(j)
    return rep^
