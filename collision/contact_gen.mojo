"""Contact generation over the `BroadPhase` seam (audit cluster 7, finding F2).

Two responsibilities, both narrowphase-shaped and both collision's (not
physics's) job:

  * candidate-pair enumeration through a `BroadPhase` instance -- rebuild it
    from this frame's fat AABBs, read its pairs, and reduce them to the exact
    canonical order the reference nested double loop visits pairs in
    (`i < j`, ascending), because that is what makes any backend swapped in
    bit-identical to the brute reference (`collect_bp_pairs`);
  * the per-pair / per-triangle narrowphase test against a `ColliderSet`,
    producing raw contact geometry (`try_pair`, `try_mesh_pair`).

What stays in physics: matching a new contact against last frame's
warm-start cache and preparing body-frame anchors / approach-speed prep for
restitution, because both need a `Body6` (`to_local`, `velocity_at`). This
module returns geometry only -- one manifold per touched feature, plus which
pairs were sensor overlaps -- so 17.13 scene queries and the 17.1 character
controller can call it without ever importing physics.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot
from geometry.aabb import AABB
from .collider_set import ColliderSet, Pose3, SHAPE_TRIMESH, SPEC_BASE
from .broadphase import BroadPhase, BoxProxy, Pair
from .manifold import ContactManifold
from .hull import hull_manifold


@fieldwise_init
struct RawContact(Copyable, ImplicitlyCopyable, Movable):
    """One manifold from the narrowphase: pair `(a, b)`, sub-feature `feat`
    (0 for shape-vs-shape, a triangle index for mesh contact), and the
    manifold itself -- geometry only, no accumulators, no anchors."""

    var a: Int
    var b: Int
    var feat: Int
    var m: ContactManifold[3]


def collect_bp_pairs[BP: BroadPhase](
    mut bp: BP, boxes: List[AABB[BP.dim]], statics: List[Bool], mut out: List[Pair]
) raises:
    """Rebuild `bp` from `boxes` (proxy == index into `boxes`, i.e. the body
    index), read its candidate pairs, and reduce them to the canonical order
    the nested double loop below would visit: each pair canonicalised to
    `a < b` (a `BroadPhase` backend is free to emit either order -- see
    `bp_sap.mojo`'s docstring), static-static pairs dropped, sorted ascending
    by `(a, b)`. This is the ONLY thing that makes swapping in any backend
    bit-identical to the brute reference: the Gauss-Seidel solve is order-
    dependent, so the pair sequence has to match exactly, not just the set."""
    var items = List[BoxProxy[BP.dim]]()
    for i in range(len(boxes)):
        items.append(BoxProxy[BP.dim](i, boxes[i]))
    bp.rebuild(items)
    var raw = List[Pair]()
    bp.pairs(raw)
    var keys = List[Int]()
    for c in range(len(raw)):
        var lo = min(raw[c].a, raw[c].b)
        var hi = max(raw[c].a, raw[c].b)
        if statics[lo] and statics[hi]:
            continue
        keys.append((lo << 32) | hi)
    sort(keys)
    for c in range(len(keys)):
        out.append(Pair(keys[c] >> 32, keys[c] & 0xFFFFFFFF))


def speculative_margin(vel_a: Vec3, vel_b: Vec3, spec_dt: Real) -> Real:
    """The per-pair speculative margin (0 outside CCD): `SPEC_BASE` plus how
    far the pair could close together this step."""
    if spec_dt <= 0:
        return 0
    return SPEC_BASE + (sqrt(dot(vel_a, vel_a)) + sqrt(dot(vel_b, vel_b))) * spec_dt


def try_mesh_pair(
    colliders: ColliderSet, i: Int, j: Int,
    pose_i: Pose3, pose_j: Pose3, margin: Real, mut out: List[RawContact],
):
    """Contact against static level geometry.

    Unlike every other pair, this emits MORE THAN ONE manifold: a crate
    landing in a valley rests on several triangles, and collapsing them into
    one contact would pick a single normal for a surface that has two. Each
    triangle therefore becomes its own `RawContact`, keyed by triangle index
    so physics's warm-start cache stays per-triangle across frames."""
    var a = i  # the dynamic body
    var b = j  # the static mesh
    var pa = pose_i.copy()
    if colliders.shape[i] >= SHAPE_TRIMESH:
        a = j
        b = i
        pa = pose_j.copy()
    if colliders.shape[a] >= SHAPE_TRIMESH:
        return  # mesh vs mesh: two static bodies, nothing to resolve

    # The speculative margin is split half-and-half between the two shapes
    # everywhere else, and the full margin is subtracted from the depth
    # afterwards. A triangle has no thickness to inflate, so the dynamic body
    # carries the WHOLE margin here (see `physics.solver6`'s original note:
    # inflating it by half instead leaves the body resting margin/2 too deep).
    var mr = margin
    var wide = Vec3(margin, margin, margin, 0)

    var box = colliders.fat_aabb(a, pa, Vec3(0, 0, 0, 0), 0)
    var lo = box.min - wide
    var hi = box.max + wide
    var tris = List[Int]()
    colliders.mesh_candidates(b, AABB[3](lo, hi), tris)
    if len(tris) == 0:
        return

    # a HULL body is not inflated (see `hull_manifold`): the whole margin goes
    # to the narrowphase as its speculative distance instead
    var a_is_hull = colliders.hull_is_bent_by_inflation(a)
    var zero = Vec3(0, 0, 0, 0)
    var spec = margin if a_is_hull else Real(0)
    var poly_a = colliders.as_hull(a, pa, zero if a_is_hull else wide, Real(0) if a_is_hull else mr)
    var faces_a = colliders.hull_faces(a, pa, zero if a_is_hull else wide, Real(0) if a_is_hull else mr)
    for c in range(len(tris)):
        var t = tris[c]
        var tf = colliders.mesh_tri_faces(b, t)
        if len(tf) < 3:
            continue  # degenerate triangle: no normal, no contact
        var m = hull_manifold(poly_a, colliders.mesh_tri(b, t), faces_a, tf, spec)
        if not m.hit:
            continue
        if spec > 0:
            for k in range(m.count):
                m.depths[k] += spec
        if margin > 0:
            for k in range(m.count):
                m.depths[k] -= margin
        out.append(RawContact(a, b, t, m))


def try_pair(
    colliders: ColliderSet, i: Int, j: Int,
    pose_i: Pose3, pose_j: Pose3, vel_i: Vec3, vel_j: Vec3, spec_dt: Real,
    mut out: List[RawContact], mut sensors: List[RawContact],
):
    """The per-pair body of the candidate enumeration: filtering, mesh vs
    non-mesh dispatch, sensor short-circuit, speculative manifold. Extracted
    so both the brute loop and the broadphase enumeration in physics feed the
    IDENTICAL logic (parity).

    The MESH check runs first, before the sensor short-circuit (17.0f / F4a):
    a sensor overlapping a static mesh/heightfield goes through the same
    triangle-candidate path (`try_mesh_pair`) as a solid body, just with zero
    margin and its raw contacts routed to `sensors` instead of `out` (no
    impulse, matching `set_sensor`'s contract) -- rather than reaching
    `pair_manifold` directly and falling into its capsule-capsule catch-all,
    which used to report overlap against the mesh's conservative bounding
    capsule instead of its real triangles."""
    if not colliders.should_collide(i, j):
        return
    var margin = speculative_margin(vel_i, vel_j, spec_dt)
    var infl = Vec3(margin * 0.5, margin * 0.5, margin * 0.5, 0)
    var is_sensor_pair = colliders.is_sensor(i) or colliders.is_sensor(j)

    if colliders.shape[i] >= SHAPE_TRIMESH or colliders.shape[j] >= SHAPE_TRIMESH:
        if is_sensor_pair:
            # No speculative margin, same reasoning as the non-mesh sensor
            # branch below: a trigger fires on actual overlap, not early.
            try_mesh_pair(colliders, i, j, pose_i, pose_j, 0, sensors)
        else:
            try_mesh_pair(colliders, i, j, pose_i, pose_j, margin, out)
        return

    if is_sensor_pair:
        # No speculative margin: a trigger should fire when the shapes
        # actually overlap, not a margin early, and there is no impulse for
        # the margin to smooth out anyway.
        var sm = colliders.pair_manifold(i, j, pose_i, pose_j, 0, Vec3(0, 0, 0, 0))
        if sm.hit:
            sensors.append(RawContact(i, j, 0, sm))
        return

    var m = colliders.pair_manifold(i, j, pose_i, pose_j, margin * 0.5, infl)
    if m.hit and margin > 0:
        for k in range(m.count):
            m.depths[k] -= margin
    if m.hit:
        out.append(RawContact(i, j, 0, m))
