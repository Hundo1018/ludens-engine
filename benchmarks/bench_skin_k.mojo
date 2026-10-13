"""K-influence skinning and morph targets (ROADMAP 17.65).

ns per vertex for DLB (`skin_motor_k`) and LBS (`skin_lbs_k`) at K = 2, 4, 8
over 4096 vertices and 32 bones, next to the existing 2-bone `skin_motor`;
morph `apply` per stored delta with 6 of 60 targets active (each moving 5 %
of the vertices).

Run with: `mojo run -I build benchmarks/bench_skin_k.mojo`.
"""

from std.benchmark import keep
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from geometry.motor import Motor3
from geometry.mat import Mat4
from geometry.skinning import skin_motor, skin_motor_k, skin_lbs_k
from geometry.morph import MorphSet
from harness.bench import BenchTable, now


def main() raises:
    var nv = 4096
    var nb = 32
    var bones = List[Motor3]()
    var mats = List[Mat4]()
    for b in range(nb):
        var m = Motor3.from_quat_translation(Quat.from_axis_angle(Vec3(Real(b % 3), 1, 0.5, 0), Real(b) * 0.1), Vec3(Real(b) * 0.05, 0, 0, 0))
        bones.append(m)
        mats.append(m.to_mat4())
    var rest = List[Vec3]()
    for v in range(nv):
        rest.append(Vec3(Real(v % 17) * 0.1, Real(v % 13) * 0.1, Real(v % 11) * 0.1, 0))
    var out = List[Vec3](length=nv, fill=Vec3(0, 0, 0, 0))
    var reps = 20
    var t = BenchTable("K-influence skinning, 4096 vertices, 32 bones (17.65)")
    var ia = List[Int]()
    var ib = List[Int]()
    var wa = List[Real]()
    for v in range(nv):
        ia.append(v % nb)
        ib.append((v * 7 + 3) % nb)
        wa.append(0.7)
    var t0 = now()
    for _ in range(reps):
        skin_motor(bones, rest, ia, ib, wa, out)
    var t1 = now()
    keep(out[5][0])
    t.add("skin_motor (2 bones, existing)", nv, "vertex", t1 - t0, reps * nv)
    var ks: List[Int] = [2, 4, 8]
    for k in ks:
        var idx = List[Int]()
        var w = List[Real]()
        for v in range(nv):
            for j in range(k):
                idx.append((v * (j + 3) + j) % nb)
                w.append(Real(j + 1))
        var t2 = now()
        for _ in range(reps):
            skin_motor_k(bones, rest, idx, w, k, out)
        var t3 = now()
        for _ in range(reps):
            skin_lbs_k(mats, rest, idx, w, k, out)
        var t4 = now()
        keep(out[7][1])
        t.add("DLB K=" + String(k), nv, "vertex", t3 - t2, reps * nv)
        t.add("LBS K=" + String(k), nv, "vertex", t4 - t3, reps * nv)
    t.print_report()

    var m = BenchTable("Morph targets: 6 of 60 active, 5 % of vertices each (17.65)")
    var ms = MorphSet(nv)
    for tg in range(60):
        var idx = List[Int]()
        var d = List[Vec3]()
        for v in range(0, nv, 20):
            idx.append((v + tg) % nv)
            d.append(Vec3(0.01, Real(tg) * 0.001, 0, 0))
        _ = ms.add_target(idx, d)
    var w = List[Real](length=60, fill=0)
    for tg in range(6):
        w[tg * 10] = 0.5
    var t5 = now()
    for _ in range(200):
        ms.apply(rest, w, out)
    var t6 = now()
    keep(out[3][0])
    m.add("apply (copy base + 6 x 205 deltas)", nv, "vertex", t6 - t5, 200 * nv)
    m.print_report()
