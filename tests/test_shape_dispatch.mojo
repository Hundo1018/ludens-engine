# tier: integration
"""Shape-pair dispatch bugs from architecture audit 2026-09-27 (F3, F4;
hotspots E8-E11), fixed as part of 17.0f. Each section below reproduces one
bug and `main()` asserts the CORRECT behaviour the matching fix must
produce; sections are added and fixed one at a time (TDD -- see the 17.0f
spec), so an early run of this file legitimately fails every section that
is not fixed yet.

F3   off-centre static mesh geometry: `ColliderSet` used to fatten a
     trimesh/heightfield's broadphase AABB around the OWNING BODY's pose
     even though a level's vertices are world-space and its body pose is
     documented as ignored -- a mesh whose true bounds sit away from the
     body position was wrongly culled under `broadphase=True` while the
     brute reference (which never consults the fat AABB) still found it.
F4a  sensor vs static mesh fell into `pair_manifold`'s capsule-capsule
     catch-all instead of the triangle-candidate path everything else uses.
F4b  soft-body particles treated every hull/trimesh/heightfield collider as
     a sphere of radius `half.x` at the body's position.
F4c  `step_soft(ccd=True)`'s rigid-body sweep ignored `should_collide` and
     sensors, and swept hull/trimesh/heightfield colliders as their
     (wrongly centred, see F3) conservative box.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from collision.contact_events import EV_BEGAN, EV_ENDED
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.softbody import SoftBody

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime NO_G = Vec3(0, 0, 0, 0)


def _box_verts(h: Real) -> List[Real]:
    """Flat (x, y, z per vertex) box hull -- see tests/test_hull.mojo's copy
    for why flat, not `List[Vec3]`."""
    var v = List[Real](capacity=24)
    for sx in range(2):
        for sy in range(2):
            for sz in range(2):
                v.append(h * (Real(1) if sx == 1 else Real(-1)))
                v.append(h * (Real(1) if sy == 1 else Real(-1)))
                v.append(h * (Real(1) if sz == 1 else Real(-1)))
    return v^


def _crate(x: Real, y: Real, z: Real = 0) -> QuatBody6:
    return QuatBody6.at_rest(Vec3(x, y, z, 0), Inertia3.box(2, 0.25, 0.25, 0.25))


def _quad_idx() -> List[Int]:
    """CCW seen from +y, so both triangles face up."""
    var i = List[Int](capacity=6)
    i.append(0); i.append(1); i.append(2)
    i.append(0); i.append(2); i.append(3)
    return i^


# ==================================================================== F3

def _offcentre_heights(n: Int) -> List[Real]:
    var hs = List[Real](capacity=n * n)
    for _ in range(n * n):
        hs.append(0.0)
    return hs^


def case_f3_heightfield(broadphase: Bool) -> List[Real]:
    """A box dropped onto a flat heightfield whose grid sits at x, z in
    [10, 30] -- nowhere near the origin, while the owning body is added at
    the origin (the pose the docs say a static mesh must ignore). Returns
    [rest y, |vel|]."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add_heightfield(
        QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 30, 1, 30)),
        _offcentre_heights(5), 5, 5, 5.0, 10.0, 10.0,
    )
    var b = sc.add(_crate(20, 2, 20), Vec3(0.25, 0.25, 0.25, 0), False)
    for _ in range(200):
        sc.step_soft(DT, G, broadphase=broadphase)
    var out = List[Real](capacity=2)
    out.append(sc.bodies[b].position()[1])
    out.append(length(sc.bodies[b].vel))
    return out^


def _offcentre_quad() -> List[Real]:
    """A flat quad spanning x, z in [10, 30], y = 0, world space."""
    var v = List[Real](capacity=12)
    v.append(10.0); v.append(0.0); v.append(10.0)
    v.append(10.0); v.append(0.0); v.append(30.0)
    v.append(30.0); v.append(0.0); v.append(30.0)
    v.append(30.0); v.append(0.0); v.append(10.0)
    return v^


def case_f3_trimesh(broadphase: Bool) -> List[Real]:
    """Same off-centre-surface story, explicit triangle soup this time."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add_trimesh(
        QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 30, 1, 30)),
        _offcentre_quad(), _quad_idx(),
    )
    var b = sc.add(_crate(20, 2, 20), Vec3(0.25, 0.25, 0.25, 0), False)
    for _ in range(200):
        sc.step_soft(DT, G, broadphase=broadphase)
    var out = List[Real](capacity=2)
    out.append(sc.bodies[b].position()[1])
    out.append(length(sc.bodies[b].vel))
    return out^


# ==================================================================== F4a

def _flat_quad(ext: Real) -> List[Real]:
    """A flat quad spanning [-ext, ext] in x and z, y = 0."""
    var v = List[Real](capacity=12)
    v.append(-ext); v.append(0.0); v.append(-ext)
    v.append(-ext); v.append(0.0); v.append(ext)
    v.append(ext); v.append(0.0); v.append(ext)
    v.append(ext); v.append(0.0); v.append(-ext)
    return v^


def case_f4a_sensor_mesh(sensor_y: Real) -> List[Real]:
    """A dynamic sensor box held at `sensor_y` above a flat trimesh floor
    spanning [-30, 30]. Nothing moves (no gravity), so the contact set is
    constant: `began` should fire exactly once at step 0 and never again
    when the sensor genuinely overlaps the floor, and never at all when it
    sits well clear of it (even though it is still within the mesh's local
    `half`-extent bounding radius the old capsule-capsule catch-all used).
    Returns [began, stay, ended] event counts summed over 10 steps."""
    var sc = ContactScene6[QuatBody6]()
    sc.events_on = True
    _ = sc.add_trimesh(
        QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 30, 1, 30)),
        _flat_quad(30), _quad_idx(),
    )
    var sens = sc.add(
        QuatBody6.at_rest(Vec3(0, sensor_y, 0, 0), Inertia3.box(1, 0.3, 0.3, 0.3)),
        Vec3(0.3, 0.3, 0.3, 0), False,
    )
    sc.set_sensor(sens, True)
    var began = 0
    var stay = 0
    var ended = 0
    for _ in range(10):
        sc.step_soft(DT, NO_G)
        for e in range(len(sc.events)):
            if sc.events[e].kind == EV_BEGAN:
                began += 1
            elif sc.events[e].kind == EV_ENDED:
                ended += 1
            else:
                stay += 1
    var out = List[Real](capacity=3)
    out.append(Real(began))
    out.append(Real(stay))
    out.append(Real(ended))
    return out^


# ==================================================================== F4b

def _box_verts3(hx: Real, hy: Real, hz: Real) -> List[Real]:
    """Flat (x, y, z per vertex) box hull with independent half-extents per
    axis -- unlike `_box_verts`, a CUBE hull would coincidentally still look
    like a sphere of radius `half.x` from directly above, hiding the bug."""
    var v = List[Real](capacity=24)
    for sx in range(2):
        for sy in range(2):
            for sz in range(2):
                v.append(hx * (Real(1) if sx == 1 else Real(-1)))
                v.append(hy * (Real(1) if sy == 1 else Real(-1)))
                v.append(hz * (Real(1) if sz == 1 else Real(-1)))
    return v^


def case_f4b_hull_platform() -> List[Real]:
    """A soft lattice dropped onto a wide, thin static hull platform (half
    (2, 0.2, 2)). The old 'sphere of radius half.x at the body position'
    substitution put the surface at y = +2 (half.x) instead of the
    platform's real top at y = 0.2 -- floating on an invisible sphere.
    Returns [bottom y after settling, max particle speed]."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add_hull(
        QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 2, 0.2, 2)),
        _box_verts3(2.0, 0.2, 2.0), True,
    )
    var sb = SoftBody.box_lattice(
        Vec3(0, 1.5, 0, 0), Vec3(0.2, 0.2, 0.2, 0), 3, 1.0, 1e-4
    )
    _ = sc.add_soft(sb^)
    for _ in range(240):
        sc.step_soft(DT, G)
    var out = List[Real](capacity=2)
    out.append(sc.softs[0].bottom_y())
    out.append(sc.softs[0].max_speed())
    return out^


def case_f4b_trimesh_offcentre() -> List[Real]:
    """A soft lattice dropped onto an off-centre trimesh floor (x, z in
    [10, 30], the owning body added at the origin) -- the same false
    'sphere at the body position' substitution, against a mesh whose true
    surface is nowhere near that sphere. Returns [bottom y after settling,
    max particle speed]."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add_trimesh(
        QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 30, 1, 30)),
        _offcentre_quad(), _quad_idx(),
    )
    var sb = SoftBody.box_lattice(
        Vec3(20, 1.5, 20, 0), Vec3(0.2, 0.2, 0.2, 0), 3, 1.0, 1e-4
    )
    _ = sc.add_soft(sb^)
    for _ in range(240):
        sc.step_soft(DT, G)
    var out = List[Real](capacity=2)
    out.append(sc.softs[0].bottom_y())
    out.append(sc.softs[0].max_speed())
    return out^


# ==================================================================== F4c

def case_f4c_sensor_passthrough() -> Real:
    """A fast body fired straight through a sensor volume under
    `ccd=True`. The rigid-body TOI sweep must not clamp it at the sensor --
    only the far static wall behind it should stop it. Returns the body's
    final x (it must have crossed the sensor's x = 0 plane)."""
    var sc = ContactScene6[QuatBody6]()
    var sens = sc.add(
        QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 0.3, 2, 2)),
        Vec3(0.3, 2, 2, 0), True,
    )
    sc.set_sensor(sens, True)
    var bullet = QuatBody6.at_rest(Vec3(-2.5, 0, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1))
    bullet.vel = Vec3(50, 0, 0, 0)
    var b = sc.add(bullet, Vec3(0.1, 0.1, 0.1, 0), False)
    for _ in range(10):
        sc.step_soft(DT, NO_G, ccd=True)
    return sc.bodies[b].position()[0]


def case_f4c_filtered_wall() -> Real:
    """A fast body whose mask excludes a wall's category must pass through
    it even under `ccd=True` -- the sweep must consult `should_collide`.
    Returns the body's final x."""
    var sc = ContactScene6[QuatBody6]()
    var wall = sc.add(
        QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 0.3, 2, 2)),
        Vec3(0.3, 2, 2, 0), True,
    )
    sc.set_filter(wall, 2, 0xFFFFFFFF)
    var bullet = QuatBody6.at_rest(Vec3(-2.5, 0, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1))
    bullet.vel = Vec3(50, 0, 0, 0)
    var b = sc.add(bullet, Vec3(0.1, 0.1, 0.1, 0), False)
    sc.set_filter(b, 1, 1)  # category 1, collides only with category 1
    for _ in range(10):
        sc.step_soft(DT, NO_G, ccd=True)
    return sc.bodies[b].position()[0]


def case_f4c_mesh_bbox() -> Real:
    """A fast-falling body over a large, mostly-flat (y = 0) trimesh floor
    whose bounding box is tall ONLY because of one small spike triangle far
    off in a corner -- the true surface under the falling body is flat at
    y = 0 the whole time. The rigid CCD sweep has no exact TOI for a
    trimesh, so treating the whole fat box (y up to the spike's height) as
    solid would freeze the body far above the real surface; the fix must
    skip the sweep for this kind and let it fall and rest on the ACTUAL
    triangle, at half its own box height. Returns the body's final y."""
    var v = List[Real](capacity=21)
    v.append(-40.0); v.append(0.0); v.append(-40.0)
    v.append(-40.0); v.append(0.0); v.append(40.0)
    v.append(40.0); v.append(0.0); v.append(40.0)
    v.append(40.0); v.append(0.0); v.append(-40.0)
    v.append(35.0); v.append(30.0); v.append(35.0)
    v.append(39.0); v.append(30.0); v.append(35.0)
    v.append(35.0); v.append(30.0); v.append(39.0)
    var idx = List[Int](capacity=9)
    idx.append(0); idx.append(1); idx.append(2)
    idx.append(0); idx.append(2); idx.append(3)
    idx.append(4); idx.append(5); idx.append(6)
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add_trimesh(
        QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 40, 15, 40)),
        v^, idx^,
    )
    var fast = QuatBody6.at_rest(Vec3(-10, 3, 10, 0), Inertia3.box(1, 0.1, 0.1, 0.1))
    fast.vel = Vec3(0, -20, 0, 0)
    var b = sc.add(fast, Vec3(0.1, 0.1, 0.1, 0), False)
    for _ in range(90):
        sc.step_soft(DT, G, ccd=True)
    return sc.bodies[b].position()[1]


# ================================================================ EXTREME

def case_extreme_degenerate_seam(broadphase: Bool) -> List[Real]:
    """An off-centre trimesh floor (same story as F3) with one EXTRA
    degenerate (zero-area, collinear) triangle mixed into the index buffer.
    It must be silently skipped -- no normal, no contact, no crash -- while
    the two real triangles still hold a dropped box up. Returns [rest y,
    |vel|]."""
    var v = _offcentre_quad()
    v.append(20.0); v.append(0.0); v.append(10.0)  # vertex 4: on the segment
    var idx = _quad_idx()  # from vertex 0 (10,0,10) to vertex 3 (30,0,10)
    idx.append(0); idx.append(4); idx.append(3)  # zero-area: collinear
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add_trimesh(
        QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 30, 1, 30)), v^, idx^,
    )
    var b = sc.add(_crate(20, 2, 20), Vec3(0.25, 0.25, 0.25, 0), False)
    for _ in range(200):
        sc.step_soft(DT, G, broadphase=broadphase)
    var out = List[Real](capacity=2)
    out.append(sc.bodies[b].position()[1])
    out.append(length(sc.bodies[b].vel))
    return out^


def case_extreme_edge_rest() -> List[Real]:
    """A box dropped exactly on the shared diagonal seam between a flat
    mesh floor's two triangles -- both triangles' candidate/manifold paths
    fire on the same body every step, and the two contacts must combine
    into one stable rest, not jitter or diverge. Returns [rest y, |vel|]."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add_trimesh(
        QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 30, 1, 30)),
        _flat_quad(30), _quad_idx(),
    )
    var b = sc.add(_crate(0, 2, 0), Vec3(0.25, 0.25, 0.25, 0), False)
    for _ in range(200):
        sc.step_soft(DT, G)
    var out = List[Real](capacity=2)
    out.append(sc.bodies[b].position()[1])
    out.append(length(sc.bodies[b].vel))
    return out^


def main() raises:
    var s = Suite("shape_dispatch")

    # ---- F3 / E10: off-centre static mesh bounds, broadphase vs brute ----
    var hf_brute = case_f3_heightfield(False)
    var hf_bp = case_f3_heightfield(True)
    print("  F3 heightfield off-centre: brute y", hf_brute[0], " bp y", hf_bp[0])
    s.check(
        abs(Float64(hf_brute[0]) - 0.25) < 0.02,
        "F3: brute rests the box on the off-centre heightfield",
    )
    s.check(
        Float64(hf_bp[0]) == Float64(hf_brute[0]),
        "F3: broadphase seam agrees with brute bit-for-bit (heightfield)",
    )
    s.check(
        Float64(hf_bp[0]) > 0.2,
        "F3: broadphase does not let the box fall through the heightfield",
    )

    var tm_brute = case_f3_trimesh(False)
    var tm_bp = case_f3_trimesh(True)
    print("  F3 trimesh off-centre: brute y", tm_brute[0], " bp y", tm_bp[0])
    s.check(
        abs(Float64(tm_brute[0]) - 0.25) < 0.02,
        "F3: brute rests the box on the off-centre trimesh",
    )
    s.check(
        Float64(tm_bp[0]) == Float64(tm_brute[0]),
        "F3: broadphase seam agrees with brute bit-for-bit (trimesh)",
    )
    s.check(
        Float64(tm_bp[0]) > 0.2,
        "F3: broadphase does not let the box fall through the trimesh",
    )

    # ---- F4a / E8: sensor vs static mesh, exhaustive dispatch ----
    var s_over = case_f4a_sensor_mesh(0.1)
    print(
        "  F4a sensor overlapping mesh: began", s_over[0], " stay", s_over[1],
        " ended", s_over[2],
    )
    s.check(
        s_over[0] >= 1,
        "F4a: a sensor genuinely overlapping a trimesh fires at least one"
        " began (one per touched triangle -- it straddles the floor's"
        " diagonal seam here, so both may fire)",
    )
    s.check(
        s_over[2] == 0, "F4a: and never an ended while it stays put"
    )

    var s_clear = case_f4a_sensor_mesh(10.0)
    print(
        "  F4a sensor clear of mesh: began", s_clear[0], " stay", s_clear[1],
        " ended", s_clear[2],
    )
    s.check(
        s_clear[0] == 0,
        "F4a: a sensor well clear of the real surface (but inside the old"
        " capsule-catch-all's fake bounding sphere) fires no events at all",
    )

    # ---- F4b / E9: soft particles vs hull/trimesh, not a fake sphere ----
    var hp = case_f4b_hull_platform()
    print("  F4b hull platform: bottom y", hp[0], " max speed", hp[1])
    s.check(
        Float64(hp[0]) < 0.5,
        "F4b: lattice rests on the hull's real top, not the half.x sphere",
    )
    s.check(Float64(hp[0]) > 0.15, "F4b: and does not fall through the hull")
    s.check(Float64(hp[1]) < 0.1, "F4b: lattice settles on the hull")

    var tp = case_f4b_trimesh_offcentre()
    print("  F4b off-centre trimesh: bottom y", tp[0], " max speed", tp[1])
    s.check(
        Float64(tp[0]) > -0.5,
        "F4b: lattice does not fall through an off-centre trimesh",
    )
    s.check(
        Float64(tp[0]) < 0.5,
        "F4b: and does not float on the old body-position sphere",
    )
    s.check(Float64(tp[1]) < 0.1, "F4b: lattice settles on the trimesh")

    # ---- F4c / E11: rigid CCD sweep vs filters, sensors, static meshes ----
    var sx = case_f4c_sensor_passthrough()
    print("  F4c sensor passthrough: final x", sx)
    s.check(
        Float64(sx) > 0.0,
        "F4c: ccd does not clamp a fast body at a sensor volume",
    )

    var fx = case_f4c_filtered_wall()
    print("  F4c filtered wall: final x", fx)
    s.check(
        Float64(fx) > 0.0,
        "F4c: ccd consults should_collide -- a filtered pair passes through",
    )

    var my = case_f4c_mesh_bbox()
    print("  F4c mesh bbox: final y", my)
    s.check(
        abs(Float64(my) - 0.1) < 0.02,
        "F4c: ccd does not freeze a fast-falling body against a trimesh's"
        " fat bounding box -- it falls and rests on the real, flat surface",
    )

    # ---------------------------------------------------------- EXTREME ----
    var deg_brute = case_extreme_degenerate_seam(False)
    var deg_bp = case_extreme_degenerate_seam(True)
    print(
        "  extreme degenerate triangle: brute y", deg_brute[0], " bp y",
        deg_bp[0],
    )
    s.check(
        abs(Float64(deg_brute[0]) - 0.25) < 0.02,
        "extreme: a degenerate triangle mixed into the mesh does not stop"
        " the real triangles from holding the box up",
    )
    s.check(
        Float64(deg_bp[0]) == Float64(deg_brute[0]),
        "extreme: broadphase agrees with brute even with a degenerate"
        " triangle and an off-centre mesh in play together",
    )

    var edge = case_extreme_edge_rest()
    print("  extreme edge-seam rest: y", edge[0], " speed", edge[1])
    s.check(
        abs(Float64(edge[0]) - 0.25) < 0.02,
        "extreme: a box resting exactly on a mesh's triangle seam settles"
        " at the right height",
    )
    s.check(
        Float64(edge[1]) < 0.05,
        "extreme: and does not jitter between the two triangles' contacts",
    )

    s.finish()
