"""Second-stage continuous collision (audit F11, cluster 11): swept-box TOI
pose advance, a free function over a `BodySet` view and the `ColliderSet`
(for shape kinds, filters and sensors), composed by `ContactScene6`.
"""

from geometry.vec import Real, Vec3, dot
from collision.collider_set import (
    ColliderSet,
    SHAPE_HULL,
    SHAPE_TRIMESH,
    SHAPE_HEIGHTFIELD,
)
from collision.toi import swept_box_toi
from .rigid6 import Body6
from .body_set import BodySet


def ccd_advance[B: Body6](
    mut bset: BodySet[B], colliders: ColliderSet, h: Real
):
    """Swept/TOI pose advance (second-stage CCD, Jolt LinearCast
    direction): a body whose relative travel this substep could jump the
    thinnest feature of a pair linear-casts its box along the substep
    displacement (`swept_box_toi`) and advances only to the time of
    impact, minus a hair of back-off — the speculative solver then removes
    the approach velocity with the pair already AT the surface, so the
    midplane can never be crossed. Slow bodies take the plain pose step,
    bit-identical to the non-CCD path (zero-regression guarantee). Clamp
    fractions are decided against the substep-start snapshot before any
    pose moves, so mutually-approaching fast pairs resolve symmetrically
    (the relative displacement already contains both velocities).

    Sphere/capsule still use their conservative `half` box (a superset of
    the real shape centred correctly on the body, so the sweep can only
    clamp too early, never wrongly): that is unchanged. Hull, trimesh
    and heightfield have no exact box TOI at all -- a hull's box is not
    its shape, and a static mesh's `half` is not even centred on the
    body (F3), so sweeping either as a box can freeze a body far from
    its real surface. Rather than build a per-kind sweep for three kinds
    that already get a discrete/speculative contact every substep, this
    sweep just skips any pair touching one of them (the conservative
    option the spec allows): CCD there falls back to whatever the
    ordinary contact path already provides, with the residual tunnelling
    risk that implies for genuinely fast movers against those three
    kinds specifically -- no worse than before CCD existed for them.
    `should_collide`/sensors are consulted too, so a filtered or sensor
    pair is never clamped here regardless of shape (17.0f / F4c)."""
    var n = len(bset.bodies)
    var frac = List[Real]()
    for _ in range(n):
        frac.append(1)
    for i in range(n):
        if bset.inactive(i):
            continue
        var ki = colliders.shape[i]
        if ki == SHAPE_HULL or ki == SHAPE_TRIMESH or ki == SHAPE_HEIGHTFIELD:
            continue  # no exact box TOI for this kind (see docstring)
        var vi = bset.bodies[i].linear_velocity()
        if dot(vi, vi) * h * h < 1e-12:
            continue
        for j in range(n):
            if j == i:
                continue
            if not colliders.should_collide(i, j):
                continue
            if colliders.is_sensor(i) or colliders.is_sensor(j):
                continue
            if not bset.is_dynamic(i) and not bset.is_dynamic(j):
                # ROADMAP 17.24: static-kinematic and kinematic-kinematic
                # pairs produce no DISCRETE contact either (`_collect_pairs`)
                # -- CCD must agree, or a kinematic body moving toward a
                # static wall would get TOI-clamped by a "contact" that
                # otherwise never exists (spec: "no contact, no NaN").
                continue
            var kj = colliders.shape[j]
            if kj == SHAPE_HULL or kj == SHAPE_TRIMESH or kj == SHAPE_HEIGHTFIELD:
                continue
            var vj = Vec3(0, 0, 0, 0)
            if not bset.inactive(j):
                vj = bset.bodies[j].linear_velocity()
            var rel = (vi - vj) * h
            var ha = colliders.half[i]
            var hb = colliders.half[j]
            var thin = min(
                min(ha[0], min(ha[1], ha[2])),
                min(hb[0], min(hb[1], hb[2])),
            )
            if dot(rel, rel) <= (thin * 0.5) * (thin * 0.5):
                continue  # cannot jump the pair's thinnest feature
            var r = swept_box_toi(
                bset.bodies[j].position(),
                bset.axes(j),
                hb,
                bset.bodies[i].position(),
                bset.axes(i),
                ha,
                rel,
            )
            if r.hit and r.t < frac[i]:
                frac[i] = r.t
    for i in range(n):
        if bset.inactive(i):
            continue
        var f = frac[i]
        if f < 1:
            f = max(f - Real(0.01), 0)
        bset.bodies[i].integrate_pose(h * f)
