"""Pose interpolation seam (ROADMAP 17.7): cost per interpolated pose.

LerpNlerp (position lerp + quaternion nlerp), DqNlerp (dual-quaternion nlerp)
and MotorGeodesic (PGA motor log/exp) over N random pose pairs at a sweep of
alphas -- the per-frame cost of drawing N moving bodies between ticks. The
geodesic is the only one exact for screw motion; this table is its price.

Run: pixi run mojo run -I build benchmarks/bench_interpolation.mojo
"""

from std.benchmark import keep
from std.math import sin, cos
from harness.bench import BenchTable, now
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from gameplay.interpolation import PoseQT, PoseInterpolator, LerpNlerp, DqNlerp, MotorGeodesic


def _pairs(n: Int) -> Tuple[List[PoseQT], List[PoseQT]]:
    var a = List[PoseQT]()
    var b = List[PoseQT]()
    for k in range(n):
        var t = Real(k) * 0.37
        a.append(PoseQT(Vec3(sin(t), cos(t), t * 0.01, 0), Quat.from_axis_angle(Vec3(1, 0.3, 0, 0), t)))
        b.append(PoseQT(Vec3(cos(t), sin(t) + 0.1, 1, 0), Quat.from_axis_angle(Vec3(0, 1, 0.2, 0), t * 0.5 + 0.4)))
    return (a^, b^)


def _run[I: PoseInterpolator](mut table: BenchTable, name: String, n: Int):
    var pr = _pairs(n)
    var pa = pr[0].copy()
    var pb = pr[1].copy()
    var acc = Real(0)
    var reps = 8
    var t0 = now()
    for r in range(reps):
        var alpha = Real(r + 1) / Real(reps + 1)
        for k in range(n):
            acc += I.blend(pa[k], pb[k], alpha).p[0]
    table.add(name, n, "pose", now() - t0, n * reps)
    keep(acc)


def main():
    var table = BenchTable("Pose interpolation (17.7): cost per interpolated pose")
    for n in [256, 4096]:
        _run[LerpNlerp](table, "LerpNlerp", n)
        _run[DqNlerp](table, "DqNlerp", n)
        _run[MotorGeodesic](table, "MotorGeodesic", n)
    table.print_report()
