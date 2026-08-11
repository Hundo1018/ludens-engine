"""Static level geometry in the production solver (architecture law v3).

A level is not a convex body, so until `collision/trimesh.mojo` there was no way
to express one at all. Two midphases answer the same question — which triangles
could this body touch — and the interesting checks are the ones that hold them
to the same answer.

ORDINARY    a crate on a flat mesh floor rests at its half-height, matching the
            solid-box floor it replaces; a crate on a 20-degree ramp is held by
            the RAMP's normal, which is the thing a triangle contributes and a
            box's own face normals cannot supply.
INTEGRATION heightfield and triangle soup describing the SAME surface produce
            the same resting height; box, sphere and hull all rest on one mesh;
            the broadphase seam stays bit-identical; a serialize round-trip
            keeps stepping identically, which is what proves the per-triangle
            warm-start key survives it.
EXTREME     an empty mesh, a zero-area triangle, a body far above the surface,
            a query entirely outside a heightfield's grid, and a valley where
            one crate rests on several triangles at once.

Vertex lists are FLAT (x, y, z per vertex): a `List[Vec3]` loses its tail
elements when passed between functions on this nightly, and `collision/hull.mojo`
carries the reduced probe.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length, dot
from geometry.aabb import AABB
from collision.trimesh import TriMesh, HeightField
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.serialize import scene_to_string, scene_from_string

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)


def _quad(y0: Real, y1: Real, ext: Real) -> List[Real]:
    """A 2x2 quad spanning [-ext, ext] in x and z, with height `y0` at z = -ext
    ramping to `y1` at z = +ext. `y0 == y1` gives a flat floor."""
    var v = List[Real](capacity=12)
    v.append(-ext); v.append(y0); v.append(-ext)
    v.append(-ext); v.append(y1); v.append(ext)
    v.append(ext); v.append(y1); v.append(ext)
    v.append(ext); v.append(y0); v.append(-ext)
    return v^


def _quad_idx() -> List[Int]:
    """CCW seen from +y, so both triangles face up."""
    var i = List[Int](capacity=6)
    i.append(0); i.append(1); i.append(2)
    i.append(0); i.append(2); i.append(3)
    return i^


def _floor_body() -> QuatBody6:
    return QuatBody6.at_rest(Vec3(0, 0, 0), Inertia3.box(1, 30, 1, 30))


def _crate(y: Real, x: Real = 0) -> QuatBody6:
    return QuatBody6.at_rest(Vec3(x, y, 0), Inertia3.box(2, 0.25, 0.25, 0.25))


# ---------------------------------------------------------------- ORDINARY
def case_flat_mesh(use_bp: Bool) -> List[Real]:
    """A crate dropped on a flat triangle floor. Returns [rest y, speed]."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add_trimesh(_floor_body(), _quad(0, 0, 30), _quad_idx())
    var b = sc.add(_crate(0.6), Vec3(0.25, 0.25, 0.25), False)
    for _ in range(240):
        sc.step_soft(DT, G, broadphase=use_bp)
    var out = List[Real](capacity=2)
    out.append(sc.bodies[b].position()[1])
    out.append(length(sc.bodies[b].vel))
    return out^


def case_box_floor() -> Real:
    """The same crate on a solid box floor — the reference the mesh must match."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 30, 1, 30)),
        Vec3(30, 1, 30), True,
    )
    var b = sc.add(_crate(0.6), Vec3(0.25, 0.25, 0.25), False)
    for _ in range(240):
        sc.step_soft(DT, G)
    return sc.bodies[b].position()[1]


def case_ramp() -> List[Real]:
    """A crate on a slope rising 0.36 per unit (about 20 degrees).

    The check is on the contact NORMAL, read back as the height the crate holds
    above the surface directly beneath it. A box's own face normals are axis
    aligned; only the triangle's normal describes the slope, so if the triangle
    did not contribute its face the crate would be resolved along +y and end up
    penetrating the ramp. Returns [y, y - surface(z), |vel|]."""
    var ext = Real(10)
    var sc = ContactScene6[QuatBody6]()
    # rises from y = -3.6 at z = -10 to y = +3.6 at z = +10
    _ = sc.add_trimesh(_floor_body(), _quad(-3.6, 3.6, ext), _quad_idx())
    var b = sc.add(
        QuatBody6.at_rest(Vec3(0, 0.6, 0), Inertia3.box(2, 0.25, 0.25, 0.25)),
        Vec3(0.25, 0.25, 0.25), False,
    )
    for _ in range(200):
        sc.step_soft(DT, G)
    var p = sc.bodies[b].position()
    var surface = p[2] * (Real(7.2) / (2 * ext))  # height of the ramp under it
    var out = List[Real](capacity=3)
    out.append(p[1])
    out.append(p[1] - surface)
    out.append(length(sc.bodies[b].vel))
    return out^


# ------------------------------------------------------------- INTEGRATION
def case_field_vs_mesh(as_field: Bool) -> Real:
    """The SAME surface through the two midphases: a 5x5 heightfield with a
    dip in the middle, and the explicit soup `to_trimesh` derives from it."""
    var hs = List[Real](capacity=25)
    for iz in range(5):
        for ix in range(5):
            var d = (ix - 2) * (ix - 2) + (iz - 2) * (iz - 2)
            hs.append(Real(d) * 0.25)  # a bowl, lowest at the centre
    var f = HeightField(hs, 5, 5, 4.0, -8.0, -8.0)
    var sc = ContactScene6[QuatBody6]()
    if as_field:
        var hs2 = List[Real](capacity=25)
        for i in range(len(f.h)):
            hs2.append(f.h[i])
        _ = sc.add_heightfield(_floor_body(), hs2^, 5, 5, 4.0, -8.0, -8.0)
    else:
        var m = f.to_trimesh()
        var vv = List[Real](capacity=len(m.v))
        for i in range(len(m.v)):
            vv.append(m.v[i])
        var ii = List[Int](capacity=len(m.idx))
        for i in range(len(m.idx)):
            ii.append(m.idx[i])
        _ = sc.add_trimesh(_floor_body(), vv^, ii^)
    var b = sc.add(_crate(1.2), Vec3(0.25, 0.25, 0.25), False)
    for _ in range(300):
        sc.step_soft(DT, G)
    return sc.bodies[b].position()[1]


def case_mixed_on_mesh() -> List[Real]:
    """Box, sphere and convex hull resting on one triangle floor."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add_trimesh(_floor_body(), _quad(0, 0, 30), _quad_idx())
    var bx = sc.add(_crate(0.6, -1), Vec3(0.25, 0.25, 0.25), False)
    var sp = sc.add_sphere(
        QuatBody6.at_rest(Vec3(0, 0.6, 0), Inertia3.sphere(2, 0.25)), 0.25, False
    )
    var hv = List[Real](capacity=24)
    for sx in range(2):
        for sy in range(2):
            for sz in range(2):
                hv.append(0.25 * (Real(1) if sx == 1 else Real(-1)))
                hv.append(0.25 * (Real(1) if sy == 1 else Real(-1)))
                hv.append(0.25 * (Real(1) if sz == 1 else Real(-1)))
    var hl = sc.add_hull(_crate(0.6, 1), hv^, False)
    for _ in range(240):
        sc.step_soft(DT, G)
    var out = List[Real](capacity=3)
    out.append(sc.bodies[bx].position()[1])
    out.append(sc.bodies[sp].position()[1])
    out.append(sc.bodies[hl].position()[1])
    return out^


def case_roundtrip() raises -> List[Real]:
    """Step, save, load, step both — the loaded scene must track the original.

    This is what gates the per-triangle warm-start key through serialization:
    mesh contacts share an (a, b) pair and are told apart only by triangle
    index, so dropping that field would still round-trip a valid scene, just
    one whose contacts inherit each other's impulses. Returns [orig y, loaded y].
    """
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add_trimesh(_floor_body(), _quad(0, 0, 30), _quad_idx())
    var b = sc.add(_crate(0.6), Vec3(0.25, 0.25, 0.25), False)
    for _ in range(60):
        sc.step_soft(DT, G)
    var blob = scene_to_string(sc)
    var sc2 = scene_from_string(blob)
    for _ in range(120):
        sc.step_soft(DT, G)
        sc2.step_soft(DT, G)
    var out = List[Real](capacity=2)
    out.append(sc.bodies[b].position()[1])
    out.append(sc2.bodies[b].position()[1])
    return out^


# ---------------------------------------------------------------- EXTREME
def case_empty_mesh() -> Real:
    """No triangles at all: the crate must fall, not crash or stick."""
    var v = List[Real]()
    var i = List[Int]()
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add_trimesh(_floor_body(), v^, i^)
    var b = sc.add(_crate(0.6), Vec3(0.25, 0.25, 0.25), False)
    for _ in range(60):
        sc.step_soft(DT, G)
    return sc.bodies[b].position()[1]


def case_degenerate_tri() -> Real:
    """A mesh whose only triangles have zero area. They have no normal, so they
    must be skipped rather than producing a garbage axis."""
    var v = List[Real](capacity=12)
    v.append(-1.0); v.append(0.0); v.append(0.0)
    v.append(1.0); v.append(0.0); v.append(0.0)
    v.append(2.0); v.append(0.0); v.append(0.0)  # collinear with the first two
    v.append(-1.0); v.append(0.0); v.append(0.0)
    var i = List[Int](capacity=6)
    i.append(0); i.append(1); i.append(2)
    i.append(0); i.append(1); i.append(3)
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add_trimesh(_floor_body(), v^, i^)
    var b = sc.add(_crate(0.6), Vec3(0.25, 0.25, 0.25), False)
    for _ in range(60):
        sc.step_soft(DT, G)
    return sc.bodies[b].position()[1]


def case_far_above() -> Real:
    """A body high above the surface: the midphase must report nothing, and the
    body must fall freely. Returns the count of candidate triangles."""
    var v = _quad(0, 0, 30)
    var i = _quad_idx()
    var m = TriMesh(v, i)
    var out = List[Int]()
    m.candidates(AABB[3](Vec3(-1, 50, -1), Vec3(1, 52, 1)), out)
    return Real(len(out))


def case_outside_field() -> List[Real]:
    """Heightfield queries wholly outside the grid, and one straddling its edge.
    Returns [outside count, straddling count, total triangles]."""
    var hs = List[Real](capacity=16)
    for _ in range(16):
        hs.append(0.0)
    var f = HeightField(hs, 4, 4, 1.0, 0.0, 0.0)  # covers x, z in [0, 3]
    var a = List[Int]()
    f.candidates(AABB[3](Vec3(-50, -1, -50), Vec3(-40, 1, -40)), a)
    var b = List[Int]()
    f.candidates(AABB[3](Vec3(-1, -1, -1), Vec3(0.5, 1, 0.5)), b)
    var out = List[Real](capacity=3)
    out.append(Real(len(a)))
    out.append(Real(len(b)))
    out.append(Real(f.ntri()))
    return out^


def case_valley() -> List[Real]:
    """A crate dropped into a V, resting across the seam of two slopes. It
    touches more than one triangle at once, which is the case a single manifold
    per pair cannot represent. Returns [y, |vel|, |tilt|]."""
    var ext = Real(6)
    var v = List[Real](capacity=18)
    v.append(-ext); v.append(3.0); v.append(-ext)   # 0
    v.append(-ext); v.append(0.0); v.append(0.0)    # 1  valley floor
    v.append(-ext); v.append(3.0); v.append(ext)    # 2
    v.append(ext); v.append(3.0); v.append(-ext)    # 3
    v.append(ext); v.append(0.0); v.append(0.0)     # 4
    v.append(ext); v.append(3.0); v.append(ext)     # 5
    var i = List[Int](capacity=12)
    i.append(0); i.append(1); i.append(4)
    i.append(0); i.append(4); i.append(3)
    i.append(1); i.append(2); i.append(5)
    i.append(1); i.append(5); i.append(4)
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add_trimesh(_floor_body(), v^, i^)
    var b = sc.add(_crate(2.0), Vec3(0.25, 0.25, 0.25), False)
    for _ in range(400):
        sc.step_soft(DT, G)
    # rotation only: `act` transforms a point, so subtract the origin
    var up = sc.bodies[b].act(Vec3(0, 1, 0)) - sc.bodies[b].position()
    var out = List[Real](capacity=3)
    out.append(sc.bodies[b].position()[1])
    out.append(length(sc.bodies[b].vel))
    out.append(abs(up[1]))
    return out^


def main() raises:
    var s = Suite("trimesh")

    # ---- ORDINARY ----
    var fm = case_flat_mesh(False)
    var bf = case_box_floor()
    print("  flat mesh rest y", fm[0], " box-floor reference", bf, " speed", fm[1])
    s.check(abs(Float64(fm[0]) - 0.25) < 0.02, "a crate rests at its half-height")
    s.check(
        abs(Float64(fm[0] - bf)) < 0.01,
        "a triangle floor holds the crate where a solid box floor does",
    )
    s.check(Float64(fm[1]) < 0.05, "the crate settles on the mesh")

    var fb = case_flat_mesh(True)
    s.check(fb[0] == fm[0], "broadphase on/off is bit-identical with a mesh present")

    var rp = case_ramp()
    print("  ramp: y", rp[0], " above surface", rp[1], " speed", rp[2])
    s.check(
        Float64(rp[1]) > 0.15,
        "the crate stays above the ramp: the TRIANGLE's normal is in play",
    )
    s.check(Float64(rp[1]) < 0.45, "and does not float above it")

    # ---- INTEGRATION ----
    var yf = case_field_vs_mesh(True)
    var ym = case_field_vs_mesh(False)
    print("  bowl rest y — heightfield", yf, " triangle soup", ym)
    s.check(
        abs(Float64(yf - ym)) < 0.02,
        "the two midphases agree on the same surface",
    )

    var mx = case_mixed_on_mesh()
    print("  on mesh — box", mx[0], " sphere", mx[1], " hull", mx[2])
    var mixed_ok = True
    for k in range(3):
        if abs(Float64(mx[k]) - 0.25) > 0.05:
            mixed_ok = False
    s.check(mixed_ok, "box, sphere and hull all rest on the mesh")

    var rt = case_roundtrip()
    print("  round trip — original", rt[0], " loaded", rt[1])
    s.check(
        abs(Float64(rt[0] - rt[1])) < 1e-5,
        "a serialize round trip keeps mesh contacts stepping identically",
    )

    # ---- EXTREME ----
    var em = case_empty_mesh()
    print("  empty mesh, crate after 1s:", em)
    s.check(Float64(em) < 0.0, "an empty mesh stops nothing")

    var dg = case_degenerate_tri()
    print("  zero-area mesh, crate after 1s:", dg)
    s.check(Float64(dg) < 0.0, "zero-area triangles are skipped, not resolved")

    s.check(case_far_above() == 0, "a body far above the mesh has no candidates")

    var of = case_outside_field()
    print("  heightfield candidates — outside", of[0], " straddling", of[1])
    s.check(of[0] == 0, "a query outside the grid returns nothing")
    s.check(of[1] > 0 and of[1] <= of[2], "a straddling query is clamped, not wrapped")

    var vl = case_valley()
    print("  valley — y", vl[0], " speed", vl[1], " up.y", vl[2])
    s.check(Float64(vl[0]) > 0.0, "the crate stays out of the valley floor")
    s.check(Float64(vl[0]) < 1.0, "and settles into it rather than perching")
    s.check(Float64(vl[1]) < 0.1, "multi-triangle contact settles")
    s.check(Float64(vl[2]) > 0.9, "and does not tumble")

    s.finish()
