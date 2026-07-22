from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6, Joint6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0)


def _mixed() -> ContactScene6[QuatBody6]:
    """Every path the broadphase must reproduce: box towers (persistent
    contacts + warm start), a ball-joint pendulum, a bouncy sphere
    (restitution + shape), a static capsule, all shapes, spread out so the
    BVH actually prunes non-neighbours."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 40, 1, 40)),
        Vec3(40, 1, 40),
        True,
    )
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    for t in range(5):
        var x = Real(t) * 5 - 10
        for i in range(3):
            _ = sc.add(
                QuatBody6.at_rest(Vec3(x, 0.3 + 0.52 * Real(i), 0), bi),
                Vec3(0.25, 0.25, 0.25),
                False,
            )
    var anchor = sc.add(
        QuatBody6.at_rest(Vec3(14, 2, 0), Inertia3.box(1, 0.05, 0.05, 0.05)),
        Vec3(0.05, 0.05, 0.05),
        True,
    )
    var bob = sc.add(
        QuatBody6.at_rest(Vec3(14, 1, 0), Inertia3.box(1, 0.15, 0.15, 0.15)),
        Vec3(0.15, 0.15, 0.15),
        False,
    )
    _ = sc.add_joint(Joint6.ball(anchor, bob, Vec3(0, 0, 0), Vec3(0, 1, 0)))
    sc.bodies[bob].vel = Vec3(0.3, 0, 0)
    var ball = sc.add_sphere(
        QuatBody6.at_rest(Vec3(-14, 1.3, 0), Inertia3.sphere(2, 0.3)), 0.3, False
    )
    sc.set_restitution(ball, 0.7)
    _ = sc.add_capsule(
        QuatBody6.at_rest(Vec3(-16, -0.45, 0), Inertia3.capsule(1, 0.3, 0.4)),
        0.3,
        0.4,
        True,
    )
    return sc^


def _same(a: ContactScene6[QuatBody6], b: ContactScene6[QuatBody6]) -> Bool:
    for i in range(len(a.bodies)):
        var dp = a.bodies[i].pos - b.bodies[i].pos
        var dv = a.bodies[i].vel - b.bodies[i].vel
        var dw = a.bodies[i].omega - b.bodies[i].omega
        if (
            dp[0] != 0 or dp[1] != 0 or dp[2] != 0
            or dv[0] != 0 or dv[1] != 0 or dv[2] != 0
            or dw[0] != 0 or dw[1] != 0 or dw[2] != 0
            or a.bodies[i].q.x != b.bodies[i].q.x
            or a.bodies[i].q.w != b.bodies[i].q.w
            or a.sleeping[i] != b.sleeping[i]
        ):
            print("  mismatch body", i)
            return False
    return True


def main() raises:
    var s = Suite("solver_broadphase")

    # 1. Bit-identical: the BVH candidate set is a conservative superset of
    #    the hitting pairs, fed in the same (i,j) order -> every body's
    #    pos/rot/vel/sleep must match the O(n^2) path exactly, for 400
    #    frames through settling, warm-starting, joints and restitution.
    var brute = _mixed()
    var bp = _mixed()
    var ok = True
    for f in range(400):
        brute.step_soft(DT, G)
        bp.step_soft(DT, G, broadphase=True)
        if not _same(brute, bp):
            print("  diverged at frame", f)
            ok = False
            break
    s.check(ok, "broadphase == brute force (bit-identical, 400 frames)")

    # 2. It really pruned: pair count matches (same contacts found).
    print("  brute cache pairs:", len(brute.cache), " bp cache pairs:", len(bp.cache))
    s.check(len(brute.cache) == len(bp.cache), "same contact pair count")

    # 3. Physics sanity on the broadphase path: towers stand.
    var stand = True
    for t in range(5):
        for i in range(3):
            var idx = 1 + t * 3 + i
            var y = Float64(bp.bodies[idx].pos[1])
            if abs(y - (0.25 + 0.5 * Float64(i))) > 0.03:
                stand = False
    s.check(stand, "all five towers stand under the broadphase solver")

    # 4. Fast mover: a speculative-margin case must also be captured by the
    #    fat AABB (r_i scales with |v|). Drop a fast box onto the ground.
    var fb = ContactScene6[QuatBody6]()
    _ = fb.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10),
        True,
    )
    var faller = fb.add(
        QuatBody6.at_rest(Vec3(0, 3, 0), Inertia3.box(1, 0.25, 0.25, 0.25)),
        Vec3(0.25, 0.25, 0.25),
        False,
    )
    fb.bodies[faller].vel = Vec3(0, -30, 0)
    var fb2 = ContactScene6[QuatBody6]()
    _ = fb2.add(
        QuatBody6.at_rest(Vec3(0, -1, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10),
        True,
    )
    var faller2 = fb2.add(
        QuatBody6.at_rest(Vec3(0, 3, 0), Inertia3.box(1, 0.25, 0.25, 0.25)),
        Vec3(0.25, 0.25, 0.25),
        False,
    )
    fb2.bodies[faller2].vel = Vec3(0, -30, 0)
    var fok = True
    for _ in range(120):
        fb.step_soft(DT, G, ccd=True)
        fb2.step_soft(DT, G, ccd=True, broadphase=True)
        if not _same(fb, fb2):
            fok = False
            break
    print("  fast faller y:", Float64(fb2.bodies[faller2].pos[1]))
    s.check(fok, "fast mover (speculative margin) bit-identical under bp")

    s.finish()
