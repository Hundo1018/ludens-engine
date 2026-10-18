"""How often a contact loses its warm start (ROADMAP 17.19 todo:
warm-start feature-ID stability).

`make_contact` carries last step's accumulated impulses over only when the
cache has a manifold with the same (a, b, feat) AND the same point count.
This counts, per scene, over 300 steps, the manifolds that had a cached
manifold for the same body pair but did not match: `count` (point count
changed) and `feat` (feature id changed), against all manifolds seen.

Run: `pixi run mojo run -I build experiments/exp_warm_match.mojo`.
"""

from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3, Pose6
from physics.solver6 import ContactScene6
from physics.contact6 import ContactConstraint

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def tally(mut sc: ContactScene6[QuatBody6], steps: Int) -> Tuple[Int, Int, Int]:
    var seen = 0
    var count_miss = 0
    var feat_miss = 0
    for _ in range(steps):
        var old = sc.cache.copy()
        sc.step_soft(DT, G)
        for ref pr in sc.cache:
            seen += 1
            var same_pair = False
            var exact = False
            var feat_ok = False
            for ref o in old:
                if o.a == pr.a and o.b == pr.b:
                    same_pair = True
                    if o.feat == pr.feat:
                        feat_ok = True
                        if o.m.count == pr.m.count:
                            exact = True
            if same_pair and not exact:
                if feat_ok:
                    count_miss += 1
                else:
                    feat_miss += 1
    return (seen, count_miss, feat_miss)


def report(name: String, r: Tuple[Int, Int, Int]):
    print(name, " manifolds", r[0], " lost to point count", r[1], " lost to feature id", r[2])


def floor(mut sc: ContactScene6[QuatBody6]):
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)


def main() raises:
    var a = ContactScene6[QuatBody6]()
    floor(a)
    for k in range(6):
        _ = a.add(QuatBody6.at_rest(Vec3(0, 0.25 + 0.5 * Real(k), 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    report("6-box stack at rest     ", tally(a, 300))

    var b = ContactScene6[QuatBody6]()
    floor(b)
    var bx = QuatBody6.at_rest(Vec3(0, 0.6, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25))
    bx.set_pose(Pose6(Vec3(0, 0.6, 0, 0), Quat.from_axis_angle(Vec3(0.3, 0, 1, 0), 0.5)))
    bx.set_velocity(Vec3(2, 0, 0, 0), Vec3(0, 0, -4, 0))
    _ = b.add(bx^, Vec3(0.25, 0.25, 0.25, 0), False)
    report("tumbling box           ", tally(b, 300))

    var c = ContactScene6[QuatBody6]()
    _ = c.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    for k in range(3):
        var t = QuatBody6.at_rest(Vec3(Real(k) * 0.9, 0.3, 0, 0), Inertia3.box(1, 0.2, 0.3, 0.4))
        t.set_velocity(Vec3(1.5, 0, 0.5, 0), Vec3(0, 0, 0, 0))
        _ = c.add(t^, Vec3(0.2, 0.3, 0.4, 0), False)
    report("3 boxes sliding        ", tally(c, 300))

    var d = ContactScene6[QuatBody6]()
    var hs = List[Real]()
    for _ in range(41 * 41):
        hs.append(0)
    _ = d.add_heightfield(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), hs^, 41, 41, 0.5, -10, -10)
    for k in range(3):
        var t = QuatBody6.at_rest(Vec3(Real(k) * 1.2 - 5, 0.3, 0, 0), Inertia3.box(1, 0.4, 0.3, 0.4))
        t.set_velocity(Vec3(3, 0, 0.7, 0), Vec3(0, 0, 0, 0))
        _ = d.add(t^, Vec3(0.4, 0.3, 0.4, 0), False)
    report("3 boxes sliding, flat heightfield", tally(d, 300))
    var e = ContactScene6[QuatBody6]()
    var hs2 = List[Real]()
    for _ in range(41 * 41):
        hs2.append(0)
    _ = e.add_heightfield(QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 1, 1, 1)), hs2^, 41, 41, 0.5, -10, -10)
    for k in range(3):
        _ = e.add(QuatBody6.at_rest(Vec3(Real(k) * 1.2 - 5, 0.3, 0.1, 0), Inertia3.box(1, 0.4, 0.3, 0.4)), Vec3(0.4, 0.3, 0.4, 0), False)
    report("3 boxes resting, flat heightfield", tally(e, 300))
