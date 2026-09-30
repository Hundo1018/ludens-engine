"""Active ragdoll cost (ROADMAP 17.2): N three-bone legs (animated pelvis,
simulated thigh + shin) stepped with their angular drives, against the same
scene with the drives removed (joints only). The difference is what driving
a ragdoll by an animation costs on top of simulating it.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from std.math import sin, cos
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import QuatBody6
from physics.solver6 import ContactScene6
from physics.joints6 import AngularDrive
from procedural.anim_graph import Pose, to_world
from gameplay.ragdoll import Ragdoll

comptime DT: Real = 1.0 / 60.0
comptime FRAMES = 60


def _qx(deg: Real) -> Quat:
    var h = deg * Real(3.14159265358979 / 360.0)
    return Quat(sin(h), 0, 0, cos(h))


def _parents() -> List[Int]:
    var p = List[Int]()
    p.append(-1)
    p.append(0)
    p.append(1)
    return p^


def _local(x: Real, z: Real) -> Pose:
    var l = Pose(3)
    l.set(0, Vec3(x, 2, z, 0), Quat.identity())
    l.set(1, Vec3(0, -0.1, 0, 0), _qx(30))
    l.set(2, Vec3(0, -0.45, 0, 0), _qx(-40))
    return l^


def _scene(n: Int, mut rds: List[Ragdoll], mut anims: List[Pose]) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var half = List[Vec3]()
    half.append(Vec3(0.15, 0.08, 0.1, 0))
    half.append(Vec3(0.06, 0.2, 0.06, 0))
    half.append(Vec3(0.05, 0.2, 0.05, 0))
    var sim = List[Bool]()
    sim.append(False)
    sim.append(True)
    sim.append(True)
    for k in range(n):
        var off = List[Vec3]()
        off.append(Vec3(0, 0, 0, 0))
        off.append(Vec3(0, -0.225, 0, 0))
        off.append(Vec3(0, -0.225, 0, 0))
        var w = to_world(_local(Real(k % 16) * 1.0, Real(k // 16) * 1.0), _parents())
        rds.append(Ragdoll(sc, w, _parents(), half, off^, sim))
        anims.append(w^)
    return sc^


def _row(mut t: BenchTable, n: Int, drives: Bool) raises:
    var rds = List[Ragdoll]()
    var anims = List[Pose]()
    var sc = _scene(n, rds, anims)
    if not drives:
        sc.drives = List[AngularDrive]()
    var g = Vec3(0, -9.8, 0, 0)
    var t0 = Int(perf_counter_ns())
    for _ in range(FRAMES):
        if drives:
            for k in range(n):
                rds[k].follow(sc, anims[k], DT)
        sc.step_soft(DT, g)
    var d = Int(perf_counter_ns()) - t0
    keep(sc.bset.bodies[1].position()[1])
    t.add("legs with drives" if drives else "legs, joints only", n, "frame", d, FRAMES)


def main() raises:
    var t = BenchTable("Active ragdoll: N three-bone legs per frame, drives vs joints only")
    for n in [1, 16, 128]:
        _row(t, n, True)
        _row(t, n, False)
    t.print_report()
