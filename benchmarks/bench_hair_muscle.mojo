"""Hair strands and Hill muscles (ROADMAP 17.57).

STRANDS. `StrandSet.step` per particle per step for 1000 strands x 16
particles (Follow-The-Leader + bending), without colliders and with a head
sphere plus two shoulder capsules (the push-out loop runs per particle per
collider).

MUSCLE. `ActuatorBank.apply` per actuator for 64 muscles: plain
`Actuator.muscle` against the same muscles with Hill curves
(force-length exp, force-velocity, passive exp): the cost of the curves.

Run with: `mojo run -I build benchmarks/bench_hair_muscle.mojo`.
"""

from std.benchmark import keep
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import Pose6
from physics.strand import StrandSet, StrandSphere, StrandCapsule
from physics.actuator import Actuator, ActuatorBank, HillParams
from physics.muscle_tendon import MuscleTendon
from physics.muscle_ad import ArmParams, arm_rollout
from geometry.field import RealF, RevReal, Tape, rev_seed
from harness.bench import BenchTable, now


def make_hair(colliders: Bool, curl: Real = 0) raises -> StrandSet:
    var hs = StrandSet(0.2)
    if colliders:
        hs.spheres.append(StrandSphere(Vec3(0, 1.7, 0, 0), 0.1))
        hs.capsules.append(StrandCapsule(Vec3(0, 1.45, 0, 0), Vec3(0.2, 1.45, 0, 0), 0.06))
        hs.capsules.append(StrandCapsule(Vec3(0, 1.45, 0, 0), Vec3(-0.2, 1.45, 0, 0), 0.06))
    var b = Pose6(Vec3(0, 1.7, 0, 0), Quat.from_axis_angle(Vec3(0, 1, 0, 0), 0))
    for k in range(1000):
        var a = Real(k) * 0.0063
        var d = Quat.from_axis_angle(Vec3(0, 1, 0, 0), a).rotate(Vec3(1, 0.3, 0, 0))
        if curl != 0:
            _ = hs.add_curl(0, b, d * 0.1, d, Vec3(0, 1, 0, 0), curl, 16, 0.02)
        else:
            _ = hs.add(0, b, d * 0.1, d, 16, 0.02)
    return hs^


def bench_hair(mut t: BenchTable, colliders: Bool, steps: Int, curl: Real = 0) raises:
    var hs = make_hair(colliders, curl)
    var bones: List[Pose6] = [Pose6(Vec3(0, 1.7, 0, 0), Quat.from_axis_angle(Vec3(0, 1, 0, 0), 0))]
    var t0 = now()
    for k in range(steps):
        bones[0] = Pose6(Vec3(0, 1.7, 0, 0), Quat.from_axis_angle(Vec3(0, 1, 0, 0), Real(k) * 0.01))
        hs.step(1.0 / 60.0, Vec3(0, -9.8, 0, 0), bones)
    var t1 = now()
    keep(hs.tip(0)[0])
    t.add("strands 1000 x 16" + (" + sphere + 2 capsules" if colliders else "") + (", curled rest shape" if curl != 0 else ""), len(hs.x), "particle-step", t1 - t0, steps * len(hs.x))


def bench_muscle(mut t: BenchTable, hill: Bool, reps: Int):
    var bank = ActuatorBank()
    for j in range(64):
        if hill:
            _ = bank.add_hill(Actuator.muscle(j, 100, 0.02, 0.04), HillParams.thelen(0.04, 0.1, 0.2, 0.32))
        else:
            _ = bank.add(Actuator.muscle(j, 100, 0.02, 0.04))
        bank.ctrl[j] = 0.7
    var q = List[Real](length=64, fill=0.3)
    var qd = List[Real](length=64, fill=0.5)
    var tau = List[Real](length=64, fill=0)
    var t0 = now()
    for _ in range(reps):
        bank.apply(q, qd, 1.0 / 480.0, tau)
    var t1 = now()
    keep(tau[3])
    t.add("hill curves (fl, fv, fp)" if hill else "plain Actuator.muscle", 64, "actuator", t1 - t0, reps * 64)


def tendon_row(mut t: BenchTable, eps0: Real) raises:
    var h = HillParams.thelen(0.04, 0.1, 0.2, 0.32, 10)
    var units = List[MuscleTendon]()
    for _ in range(64):
        var u = MuscleTendon(h, 100.0, 0.2, eps0)
        u.equilibrate(0, 0.31)
        units.append(u^)
    var reps = 2000
    var acc = Real(0)
    var t0 = now()
    for k in range(reps):
        for i in range(64):
            acc += units[i].step(Real(k % 2), 0.31, 0, 1.0 / 2000.0)
    var t1 = now()
    keep(acc)
    t.add("MuscleTendon " + ("rigid tendon" if eps0 == 0 else "compliant tendon (eps0 0.04)"), 64, "unit-step", t1 - t0, reps * 64)


def ad_rows(mut t: BenchTable):
    var p = ArmParams(HillParams.thelen(0.04, 0.1, 0.2, 0.32, 10), HillParams.thelen(0.04, 0.1, 0.2, 0.30, 10), 200.0, 0.05, 0.5, 0.04, 1.0 / 240.0, 144)
    var reps = 200
    var acc = Real(0)
    var t0 = now()
    for _ in range(reps):
        var u = List[RealF]()
        for _ in range(6):
            u.append(RealF(0.3))
        acc += arm_rollout(p, u, 0).v
    var t1 = now()
    t.add("0.6 s reach rollout (RealF)", 6, "rollout", t1 - t0, reps)
    t0 = now()
    for _ in range(reps):
        var tp = Tape()
        var u = List[RevReal]()
        for _ in range(6):
            u.append(rev_seed(tp, 0.3))
        var q = arm_rollout(p, u, 0)
        acc += tp.grad(q.idx)[u[0].idx]
    t1 = now()
    keep(acc)
    t.add("same + gradient w.r.t. 6 controls (RevReal, 1 sweep)", 6, "rollout", t1 - t0, reps)


def main() raises:
    var t = BenchTable("Hair strands: Follow-The-Leader with bending (17.57)")
    bench_hair(t, False, 60)
    bench_hair(t, True, 60)
    bench_hair(t, False, 60, 0.3)
    t.print_report()
    var m = BenchTable("Muscle: plain activation vs Hill curves (17.57)")
    bench_muscle(m, False, 20000)
    bench_muscle(m, True, 20000)
    tendon_row(m, 0)
    tendon_row(m, 0.04)
    ad_rows(m)
    m.print_report()
