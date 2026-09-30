# tier: integration
"""Seam parity: EVERY dim-3-capable `BroadPhase` backend, plugged into
`ContactScene6[QuatBody6, BP]`, must reproduce the brute nested-loop
reference bit-for-bit (spec docs/design/17.0e-collider-set.md, audit finding F2).

`collision.contact_gen.collect_bp_pairs` is what makes this true regardless
of a backend's own internal order (`bp_sap.mojo`'s docstring: "order is not
part of the contract"): it canonicalises every candidate pair to `a < b` and
sorts ascending, the exact sequence the nested double loop visits, so the
Gauss-Seidel solve -- which IS order-dependent -- sees an identical schedule
no matter which backend produced the candidates.

`test_solver_broadphase.mojo` already gates the single default backend
(`BVHBroadPhase[3]`, `ContactScene6`'s default `BP`) against a mixed scene,
joints, restitution and a fast/speculative mover; this file is the seam
MATRIX -- brute, BVH, DBVH, SAP, spatial hash grid, octree -- each against
the ordinary/mixed scenes plus the extreme cases the spec calls out."""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from collision.broadphase import BroadPhase, BruteForce
from collision.bp_bvh import BVHBroadPhase
from collision.bp_dbvh import DbvhBroadPhase
from collision.bp_sap import SapBroadPhase
from collision.bp_hashgrid import SpatialHashBroadPhase
from collision.bp_tree import OctreeBroadPhase

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


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


def _same[BPA: BroadPhase, BPB: BroadPhase](
    a: ContactScene6[QuatBody6, BPA], b: ContactScene6[QuatBody6, BPB]
) -> Bool:
    """Bit-for-bit body-state comparison, independent of which `BroadPhase`
    each scene's type carries -- only `Body6`/sleep state is compared."""
    if len(a.bset.bodies) != len(b.bset.bodies):
        return False
    for i in range(len(a.bset.bodies)):
        var dp = a.bset.bodies[i].pos - b.bset.bodies[i].pos
        var dv = a.bset.bodies[i].vel - b.bset.bodies[i].vel
        var dw = a.bset.bodies[i].omega - b.bset.bodies[i].omega
        if (
            dp[0] != 0 or dp[1] != 0 or dp[2] != 0
            or dv[0] != 0 or dv[1] != 0 or dv[2] != 0
            or dw[0] != 0 or dw[1] != 0 or dw[2] != 0
            or a.bset.bodies[i].q.x != b.bset.bodies[i].q.x
            or a.bset.bodies[i].q.y != b.bset.bodies[i].q.y
            or a.bset.bodies[i].q.z != b.bset.bodies[i].q.z
            or a.bset.bodies[i].q.w != b.bset.bodies[i].q.w
            or a.bset.sleeping[i] != b.bset.sleeping[i]
        ):
            return False
    return True


# --------------------------------------------------------------- scenarios

def _setup_stack[BP: BroadPhase](mut sc: ContactScene6[QuatBody6, BP]):
    """(a) box stack: persistent contacts + warm start + sleeping."""
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 20, 1, 20)),
        Vec3(20, 1, 20, 0), True,
    )
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    for i in range(6):
        _ = sc.add(
            QuatBody6.at_rest(Vec3(0, 0.3 + 0.52 * Real(i), 0, 0), bi),
            Vec3(0.25, 0.25, 0.25, 0), False,
        )


def _setup_mixed[BP: BroadPhase](mut sc: ContactScene6[QuatBody6, BP]) raises:
    """(b) trimesh floor + hull + spheres + capsules, spread out so the
    accelerated backends actually prune non-neighbours."""
    var v = List[Real](capacity=12)
    v.append(-20.0); v.append(0.0); v.append(-20.0)
    v.append(-20.0); v.append(0.0); v.append(20.0)
    v.append(20.0); v.append(0.0); v.append(20.0)
    v.append(20.0); v.append(0.0); v.append(-20.0)
    var idx = List[Int](capacity=6)
    idx.append(0); idx.append(1); idx.append(2)
    idx.append(0); idx.append(2); idx.append(3)
    _ = sc.add_trimesh(
        QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 20, 1, 20)), v^, idx^
    )
    _ = sc.add_hull(
        QuatBody6.at_rest(Vec3(-6, 3, 0, 0), Inertia3.box(1, 0.3, 0.3, 0.3)),
        _box_verts(0.3), False,
    )
    var ball = sc.add_sphere(
        QuatBody6.at_rest(Vec3(0, 3, 0, 0), Inertia3.sphere(1, 0.3)), 0.3, False
    ).index()
    sc.set_restitution(ball, 0.4)
    _ = sc.add_capsule(
        QuatBody6.at_rest(Vec3(6, 3, 0, 0), Inertia3.capsule(1, 0.25, 0.3)),
        0.25, 0.3, False,
    )
    _ = sc.add_sphere(
        QuatBody6.at_rest(Vec3(-3, 4, 3, 0), Inertia3.sphere(1, 0.25)), 0.25, False
    )
    _ = sc.add_capsule(
        QuatBody6.at_rest(Vec3(3, 4, -3, 0), Inertia3.capsule(1, 0.2, 0.25)),
        0.2, 0.25, False,
    )


def _setup_overlap[BP: BroadPhase](mut sc: ContactScene6[QuatBody6, BP]):
    """(c) all bodies overlapping at one point: every fat AABB touches every
    other, and the exact-zero separation stresses the manifold code an
    accelerated broadphase might traverse in a different order than brute."""
    for _ in range(6):
        _ = sc.add_sphere(
            QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.sphere(1, 0.3)), 0.3, False
        )


def _case_stack[BP: BroadPhase](steps: Int) -> Bool:
    var refsc = ContactScene6[QuatBody6]()
    _setup_stack(refsc)
    var bpsc = ContactScene6[QuatBody6, BP]()
    _setup_stack(bpsc)
    for _ in range(steps):
        refsc.step_soft(DT, G, broadphase=False)
        bpsc.step_soft(DT, G, broadphase=True)
        if not _same(refsc, bpsc):
            return False
    return True


def _case_mixed[BP: BroadPhase](steps: Int) raises -> Bool:
    var refsc = ContactScene6[QuatBody6]()
    _setup_mixed(refsc)
    var bpsc = ContactScene6[QuatBody6, BP]()
    _setup_mixed(bpsc)
    for _ in range(steps):
        refsc.step_soft(DT, G, broadphase=False)
        bpsc.step_soft(DT, G, broadphase=True)
        if not _same(refsc, bpsc):
            return False
    return True


def _case_empty[BP: BroadPhase](steps: Int) -> Bool:
    """0 bodies: both enumeration paths must handle an empty scene."""
    var refsc = ContactScene6[QuatBody6]()
    var bpsc = ContactScene6[QuatBody6, BP]()
    for _ in range(steps):
        refsc.step_soft(DT, G, broadphase=False)
        bpsc.step_soft(DT, G, broadphase=True)
        if not _same(refsc, bpsc):
            return False
    return True


def _case_single[BP: BroadPhase](steps: Int) -> Bool:
    """1 body: no pair is possible either way -- a degenerate n<2 case for
    the broadphase rebuild/query path."""
    var refsc = ContactScene6[QuatBody6]()
    _ = refsc.add(
        QuatBody6.at_rest(Vec3(0, 5, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)),
        Vec3(0.25, 0.25, 0.25, 0), False,
    )
    var bpsc = ContactScene6[QuatBody6, BP]()
    _ = bpsc.add(
        QuatBody6.at_rest(Vec3(0, 5, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)),
        Vec3(0.25, 0.25, 0.25, 0), False,
    )
    for _ in range(steps):
        refsc.step_soft(DT, G, broadphase=False)
        bpsc.step_soft(DT, G, broadphase=True)
        if not _same(refsc, bpsc):
            return False
    return True


def _case_overlap[BP: BroadPhase](steps: Int) -> Bool:
    var refsc = ContactScene6[QuatBody6]()
    _setup_overlap(refsc)
    var bpsc = ContactScene6[QuatBody6, BP]()
    _setup_overlap(bpsc)
    for _ in range(steps):
        refsc.step_soft(DT, G, broadphase=False)
        bpsc.step_soft(DT, G, broadphase=True)
        if not _same(refsc, bpsc):
            return False
    return True


def _case_teleport[BP: BroadPhase](steps: Int, at: Int) -> Bool:
    """A body teleports mid-run, breaking whatever temporal coherence an
    incremental backend (DBVH) relies on -- its contact set must change
    completely in one step, identically on both seams."""
    var refsc = ContactScene6[QuatBody6]()
    _setup_stack(refsc)
    var bpsc = ContactScene6[QuatBody6, BP]()
    _setup_stack(bpsc)
    for f in range(steps):
        refsc.step_soft(DT, G, broadphase=False)
        bpsc.step_soft(DT, G, broadphase=True)
        if f == at:
            refsc.bset.bodies[1].pos = Vec3(50, 50, 50, 0)
            refsc.bset.sleeping[1] = False
            refsc.bset.sleep_timer[1] = 0
            bpsc.bset.bodies[1].pos = Vec3(50, 50, 50, 0)
            bpsc.bset.sleeping[1] = False
            bpsc.bset.sleep_timer[1] = 0
        if not _same(refsc, bpsc):
            return False
    return True


def _check_backend[BP: BroadPhase](mut s: Suite, name: String) raises:
    s.check(_case_stack[BP](200), name + ": box stack (200 steps)")
    s.check(_case_mixed[BP](200), name + ": trimesh + hull + sphere + capsule (200 steps)")
    s.check(_case_empty[BP](20), name + ": 0 bodies")
    s.check(_case_single[BP](60), name + ": 1 body")
    s.check(_case_overlap[BP](120), name + ": all bodies overlapping at one point")
    s.check(_case_teleport[BP](150, 60), name + ": teleport mid-run")


def main() raises:
    var s = Suite("solver_bp_seam")

    _check_backend[BruteForce[3]](s, "brute")
    _check_backend[BVHBroadPhase[3]](s, "bvh")
    _check_backend[DbvhBroadPhase[3]](s, "dbvh")
    _check_backend[SapBroadPhase[3]](s, "sap")
    _check_backend[SpatialHashBroadPhase[3]](s, "hashgrid")
    _check_backend[OctreeBroadPhase](s, "octree")

    s.finish()
