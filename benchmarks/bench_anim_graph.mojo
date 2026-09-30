"""Animation graph nodes: cost per evaluated pose (ROADMAP 17.6).

Scale axis is bones x blend nodes. Rows: a 1-D space between two clips, a
2-D gradient-band space over five clips, and a full locomotion graph (2-D
space, then an aim layer on a third of the bones, then an additive) --
each under the DLB and the GEODESIC blend. DLB is the default; GEODESIC is
the constant-speed screw path and the price of that is what the rows show.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from std.math import sin, cos
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from procedural.anim import AnimClip, BLEND_DLB, BLEND_GEODESIC
from procedural.anim_graph import (
    Pose, sample_phase, BlendSpace1D, BlendSpace2D, layer, make_additive, apply_additive,
)

comptime ITERS = 200


def _clip(bones: Int, k: Int) raises -> AnimClip:
    var c = AnimClip(bones, 16, 30)
    for f in range(16):
        for b in range(bones):
            var a = Real(0.05) * Real((b + k + f) % 7)
            c.set_key(f, b, Vec3(Real(k) * 0.1, Real(b) * 0.2, 0, 0), Quat(0, sin(a), 0, cos(a)))
    return c^


def _rows(mut t: BenchTable, bones: Int, mode: Int, tag: String) raises:
    var clips = List[AnimClip]()
    for k in range(5):
        clips.append(_clip(bones, k))
    var s1 = BlendSpace1D()
    s1.add(0, 0)
    s1.add(1, 1)
    var s2 = BlendSpace2D()
    s2.add(0, 0, 0)
    s2.add(1, 0, 1)
    s2.add(0, 1, 2)
    s2.add(-1, 0, 3)
    s2.add(0, -1, 4)
    var mask = List[Real](length=bones, fill=0)
    for b in range(bones // 3):
        mask[b] = 1
    var aim = sample_phase(clips[2], 0.2)
    var delta = make_additive(sample_phase(clips[3], 0.5), sample_phase(clips[0], 0))

    var t0 = Int(perf_counter_ns())
    for i in range(ITERS):
        var p = s1.evaluate(clips, 0.4, Real(i % 10) * 0.1, mode)
        keep(p.pos[0])
    t.add("1-D, 2 clips " + tag, bones, "pose", Int(perf_counter_ns()) - t0, ITERS)

    var t1 = Int(perf_counter_ns())
    for i in range(ITERS):
        var p = s2.evaluate(clips, 0.3, 0.4, Real(i % 10) * 0.1, mode)
        keep(p.pos[0])
    t.add("2-D, 5 clips " + tag, bones, "pose", Int(perf_counter_ns()) - t1, ITERS)

    var t2 = Int(perf_counter_ns())
    for i in range(ITERS):
        var p = s2.evaluate(clips, 0.3, 0.4, Real(i % 10) * 0.1, mode)
        var l = layer(p, aim, mask, 0.7, mode)
        var a = apply_additive(l, delta, 0.5)
        keep(a.pos[0])
    t.add("2-D + layer + additive " + tag, bones, "pose", Int(perf_counter_ns()) - t2, ITERS)


def main() raises:
    var t = BenchTable("Animation graph evaluation per pose (bones x nodes; DLB vs geodesic)")
    for bones in [16, 64, 256]:
        _rows(t, bones, BLEND_DLB, "(DLB)")
        _rows(t, bones, BLEND_GEODESIC, "(geodesic)")
    t.print_report()
