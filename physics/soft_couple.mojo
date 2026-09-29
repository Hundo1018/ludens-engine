"""Soft-body substep and its two-way coupling with rigid bodies (audit F11,
cluster 12): XPBD lattice predict / edge solve / velocity finalize, and the
particle-vs-collider pushout with sweep, Coulomb friction and the equal-and-
opposite impulse into dynamic bodies. Free functions over the soft bodies, a
`BodySet` view and the `ColliderSet`, composed by `ContactScene6`.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot
from collision.collider_set import (
    ColliderSet,
    SHAPE_BOX,
    SHAPE_HULL,
    SHAPE_TRIMESH,
    SHAPE_HEIGHTFIELD,
)
from .rigid6 import Body6
from .body_set import BodySet
from .softbody import SoftBody


def soft_fric[B: Body6](
    bset: BodySet[B], b: Int, x0: Vec3, pv: Vec3, nw: Vec3, nrm: Vec3,
    h: Real, mu: Real,
) -> Vec3:
    """Position-level Coulomb friction for a particle contact: clamp the
    tangential slide (relative to the body's contact-point motion) to
    mu times the normal correction — static grip inside the cone,
    sliding on it. Folded into the target point so the coupling impulse
    carries the tangential reaction automatically."""
    var nl = sqrt(max(dot(nrm, nrm), Real(1e-18)))
    var n = nrm * (1 / nl)
    var dn = abs(dot(nw - x0, n))
    var vb = bset.bodies[b].velocity_at(nw)
    var slide = (x0 - pv) - vb * h
    var st = slide - n * dot(slide, n)
    var stl = sqrt(max(dot(st, st), Real(1e-18)))
    if stl <= Real(1e-9):
        return nw
    var corr = stl
    if mu * dn < corr:
        corr = mu * dn
    return nw - st * (corr / stl)


def softbody_pass[B: Body6](
    mut softs: List[SoftBody],
    mut bset: BodySet[B],
    colliders: ColliderSet,
    h: Real,
    gravity: Vec3,
    iters: Int,
    ccd: Bool,
):
    """One XPBD substep for every soft body: predict, solve the lattice
    distance constraints, collide particles against every box (pushing
    the equivalent impulse back into dynamic bodies), derive velocities.

    With `ccd` a particle that ends the substep OUTSIDE a box is also
    swept: its pre-substep-to-current segment (in the box's current local
    frame — first-order relative motion) is slab-tested against the
    inflated box, and a crossing snaps it back to the entry face. Slow
    paths never trigger the sweep, so ccd=False results are unchanged."""
    for s in range(len(softs)):
        var np = len(softs[s].pts)
        var alpha_h = softs[s].alpha / (h * h)
        var r = softs[s].radius
        var damp = softs[s].damp
        var smu = softs[s].mu
        # predict (store the pre-step position in v temporarily? no —
        # keep explicit: prev list rebuilt per substep)
        var prev = List[Real](capacity=np * 3)
        for i in range(np):
            var p = softs[s].pts[i]
            prev.append(p.x[0])
            prev.append(p.x[1])
            prev.append(p.x[2])
            p.v = p.v + gravity * h
            p.x = p.x + p.v * h
            softs[s].pts[i] = p
        for e in range(len(softs[s].edges)):
            var ed = softs[s].edges[e]
            ed.lam = 0
            softs[s].edges[e] = ed
        # XPBD Gauss-Seidel over the lattice edges
        for _ in range(iters):
            for e in range(len(softs[s].edges)):
                var ed = softs[s].edges[e]
                var pa = softs[s].pts[ed.a]
                var pb = softs[s].pts[ed.b]
                var d = pa.x - pb.x
                var l = sqrt(max(dot(d, d), Real(1e-12)))
                var cc = l - ed.rest
                var wsum = pa.w + pb.w
                if wsum <= 0:
                    continue
                var dl = (-cc - alpha_h * ed.lam) / (wsum + alpha_h)
                ed.lam += dl
                var corr = d * (dl / l)
                pa.x = pa.x + corr * pa.w
                pb.x = pb.x - corr * pb.w
                softs[s].pts[ed.a] = pa
                softs[s].pts[ed.b] = pb
                softs[s].edges[e] = ed
        # particle vs every collider (bodies default to boxes in this
        # scene; hull/trimesh/heightfield route through `ColliderSet`
        # below, sphere/capsule keep their own exact closed forms here).
        for i in range(np):
            var p = softs[s].pts[i]
            for b in range(len(bset.bodies)):
                var kind = colliders.shape[b]
                if (
                    kind == SHAPE_HULL
                    or kind == SHAPE_TRIMESH
                    or kind == SHAPE_HEIGHTFIELD
                ):
                    # Point-vs-shape closest point through the collider
                    # registry (17.0f / F4b): a hull's SAT over its own
                    # faces, a mesh's triangle candidates + closest point
                    # on triangle -- see `ColliderSet.soft_particle_contact`.
                    # These three kinds do not get the `ccd` sweep the
                    # box/sphere/capsule paths below have; a fast particle
                    # can still tunnel through one within a substep. That
                    # is the same conservative scope limit `_ccd_advance`
                    # documents for rigid bodies against these kinds.
                    var res = colliders.soft_particle_contact(
                        b, bset.pose3(b), p.x, r
                    )
                    if res[0]:
                        var nw3 = res[1]
                        if smu > 0:
                            nw3 = soft_fric(bset,
                                b, p.x,
                                Vec3(
                                    prev[i * 3], prev[i * 3 + 1],
                                    prev[i * 3 + 2], 0,
                                ),
                                nw3, res[2], h, smu,
                            )
                        var dx3 = nw3 - p.x
                        p.x = nw3
                        # audit E3: a pinned particle (p.w == 0, infinite
                        # mass) would make 1/p.w = inf here -- skip the
                        # reaction impulse for it, same as any other
                        # infinite-mass coupling (the pushout above
                        # already moved the particle; only the equal-
                        # and-opposite push into the RIGID body needs
                        # a finite particle mass to compute).
                        if bset.is_dynamic(b) and p.w != 0:
                            var j3 = dx3 * (-(1 / p.w) / h)
                            bset.bodies[b].apply_impulse(j3, nw3)
                            if bset.sleeping[b]:
                                bset.sleeping[b] = False
                                bset.sleep_timer[b] = 0
                    continue
                if kind != SHAPE_BOX:
                    # sphere / capsule: radial pushout from the closest
                    # interior point (capsule = sphere at the closest
                    # point of its world axis segment); same impulse
                    # coupling as the box path below
                    var hh2 = colliders.half[b]
                    var rad = hh2[0]
                    var cen = bset.bodies[b].position()
                    if colliders.shape[b] == 2:
                        var axw = bset.bodies[b].act(
                            Vec3(0, hh2[1], 0, 0)
                        ) - cen
                        var tt = dot(p.x - cen, axw) / max(
                            dot(axw, axw), Real(1e-12)
                        )
                        if tt > 1:
                            tt = 1
                        if tt < -1:
                            tt = -1
                        cen = cen + axw * tt
                    var rr = rad + r
                    var dvec = p.x - cen
                    var d2 = dot(dvec, dvec)
                    var nw2 = p.x
                    var hit = False
                    if ccd:
                        # swept segment vs the inflated sphere
                        # (quadratic, earliest root in [0,1]) — and it
                        # OUTRANKS the radial pushout, which would eject
                        # a particle that crossed the midplane within
                        # one substep out the FAR side (same trap as the
                        # box path). Capsule: the sphere sits at the
                        # closest axis point of the CURRENT position —
                        # first-order, same spirit as the box sweep.
                        var pv2 = Vec3(
                            prev[i * 3],
                            prev[i * 3 + 1],
                            prev[i * 3 + 2],
                            0,
                        )
                        var s0 = pv2 + bset.bodies[
                            b
                        ].linear_velocity() * h
                        var seg = p.x - s0
                        var oc = s0 - cen
                        var cc2 = dot(oc, oc) - rr * rr
                        if dot(seg, seg) > r * r and cc2 > 0:
                            var aa = dot(seg, seg)
                            var bb2 = 2 * dot(oc, seg)
                            var disc = bb2 * bb2 - 4 * aa * cc2
                            if disc >= 0:
                                var tq = (-bb2 - sqrt(disc)) / (2 * aa)
                                if tq >= 0 and tq <= 1:
                                    var entry = s0 + seg * tq
                                    var ed = entry - cen
                                    var el = sqrt(
                                        max(dot(ed, ed), Real(1e-12))
                                    )
                                    nw2 = cen + ed * (rr / el)
                                    hit = True
                    if not hit and d2 < rr * rr:
                        var dist = sqrt(max(d2, Real(1e-12)))
                        nw2 = cen + dvec * (rr / dist)
                        hit = True
                    if hit and smu > 0:
                        nw2 = soft_fric(bset,
                            b,
                            p.x,
                            Vec3(
                                prev[i * 3],
                                prev[i * 3 + 1],
                                prev[i * 3 + 2],
                                0,
                            ),
                            nw2,
                            (nw2 - cen) * (1 / rr),
                            h,
                            smu,
                        )
                    if hit:
                        var dx2 = nw2 - p.x
                        p.x = nw2
                        if bset.is_dynamic(b) and p.w != 0:  # E3
                            var j2 = dx2 * (-(1 / p.w) / h)
                            bset.bodies[b].apply_impulse(j2, nw2)
                            if bset.sleeping[b]:
                                bset.sleeping[b] = False
                                bset.sleep_timer[b] = 0
                    continue
                var lp = bset.bodies[b].to_local(p.x)
                var hh = colliders.half[b]
                var pen = Real(1e30)
                var ax = -1
                var inside = True
                comptime for k in range(3):
                    var pk = (hh[k] + r) - abs(lp[k])
                    if pk <= 0:
                        inside = False
                    elif pk < pen:
                        pen = pk
                        ax = k
                var sgn = Real(0)
                var swept = False
                if ccd:
                    # Swept clamp, and it OUTRANKS the discrete pushout:
                    # a fast particle that crossed the box's midplane
                    # within one substep would be ejected out the FAR
                    # face by min-penetration — the entry face from the
                    # sweep is the truth. RELATIVE motion: shifting the
                    # particle's start by the box's own substep
                    # displacement (+v·h, exact for integrate_pose) lets
                    # one segment in the box's current frame carry both
                    # motions; the box's rotation change is ignored
                    # (first-order sweep). Gated on |dv| > r so slow
                    # scenes keep the discrete path bit-identically.
                    var pv = Vec3(
                        prev[i * 3], prev[i * 3 + 1], prev[i * 3 + 2]
                    , 0)
                    var lp0 = bset.bodies[b].to_local(
                        pv + bset.bodies[b].linear_velocity() * h
                    )
                    var dv = lp - lp0
                    if dot(dv, dv) > r * r:
                        # t_in >= 0 (not > 0): a particle clamped ONTO
                        # the face last substep re-enters with t_in == 0
                        var t_in = Real(-1e30)
                        var t_out = Real(1)
                        var ax_in = -1
                        var miss = False
                        for k in range(3):
                            var he = hh[k] + r
                            if abs(dv[k]) < Real(1e-12):
                                if abs(lp0[k]) > he:
                                    miss = True
                            else:
                                var t1 = (-he - lp0[k]) / dv[k]
                                var t2 = (he - lp0[k]) / dv[k]
                                if t1 > t2:
                                    var tmp = t1
                                    t1 = t2
                                    t2 = tmp
                                if t1 > t_in:
                                    t_in = t1
                                    ax_in = k
                                if t2 < t_out:
                                    t_out = t2
                        if (
                            not miss
                            and ax_in >= 0
                            and t_in >= 0
                            and t_in <= t_out
                            and t_in <= 1
                        ):
                            ax = ax_in
                            # entry side comes from the START point:
                            # after crossing the midplane lp[ax] is
                            # already on the far side
                            sgn = Real(1) if lp0[ax] >= 0 else Real(-1)
                            swept = True
                if not swept:
                    if inside and ax >= 0:
                        sgn = Real(1) if lp[ax] >= 0 else Real(-1)
                    else:
                        continue
                lp[ax] = sgn * (hh[ax] + r)
                var nw = bset.bodies[b].act(lp)
                if smu > 0:
                    # world face normal from a unit local offset
                    var lpo = lp
                    lpo[ax] = sgn * (hh[ax] + r + 1)
                    nw = soft_fric(bset,
                        b,
                        p.x,
                        Vec3(
                            prev[i * 3], prev[i * 3 + 1], prev[i * 3 + 2]
                        , 0),
                        nw,
                        bset.bodies[b].act(lpo) - nw,
                        h,
                        smu,
                    )
                var dx = nw - p.x
                p.x = nw
                if bset.is_dynamic(b) and p.w != 0:  # E3: pinned particle
                    # equal-and-opposite impulse into the dynamic body
                    var j = dx * (-(1 / p.w) / h)
                    bset.bodies[b].apply_impulse(j, nw)
                    if bset.sleeping[b]:
                        bset.sleeping[b] = False
                        bset.sleep_timer[b] = 0
            softs[s].pts[i] = p
        # velocities from positions
        for i in range(np):
            var p = softs[s].pts[i]
            var pv = Vec3(prev[i * 3], prev[i * 3 + 1], prev[i * 3 + 2], 0)
            p.v = (p.x - pv) * (damp / h)
            softs[s].pts[i] = p
