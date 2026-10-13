"""ROADMAP 17.80: cost and size of a physics capture.

N awake boxes in columns of 1-4 on a floor, 60 steps after 30 settling
steps. Columns: step time, `Capture.record` time per frame (keyframe every
60 frames, so one keyframe in the timed window), bytes per frame without
the keyframe, keyframe bytes, `CaptureReader.frame` decode time, and the
frame size with a region covering about a tenth of the floor.
"""

from std.time import perf_counter_ns
from geometry.vec import Real, Vec3
from geometry.aabb import AABB
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.capture import Capture, CaptureReader

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _scene(n: Int, mut side_out: Int) -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var side = 1
    while side * side * 5 < n * 2:
        side += 1
    side_out = side
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 80, 0.5, 80)), Vec3(80, 0.5, 80, 0), True)
    var k = 0
    var col = 0
    while k < n:
        var h = 1 + (col * 7) % 4
        for l in range(h):
            if k >= n:
                break
            var x = Real(col % side) * 0.55 - Real(side) * 0.275
            var z = Real(col // side) * 0.55 - Real(side) * 0.275
            var id = sc.add(QuatBody6.at_rest(Vec3(x, 0.25 + 0.52 * Real(l), z, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
            try:
                sc.set_can_sleep(id, False)
            except:
                pass
            k += 1
        col += 1
    return sc^


def main() raises:
    print("### Physics capture (17.80)\n")
    print("| N | step us | record us | frame bytes | keyframe bytes | decode us | region frame bytes |")
    print("|---:|---:|---:|---:|---:|---:|---:|")
    for n in [64, 1024]:
        var side = 0
        var sc = _scene(n, side)
        var cfg = SolverConfig()
        cfg.broadphase = True
        for _ in range(30):
            sc.step(DT, G, cfg)
        var cap = Capture(60)
        var reg = Capture(60)
        var half = Real(side) * 0.275 * 0.32
        reg.set_region(AABB[3](Vec3(-half, -0.1, -half, 0), Vec3(half, 5, half, 0)))
        var ts = 0
        var tr = 0
        for _ in range(60):
            var t0 = Int(perf_counter_ns())
            sc.step(DT, G, cfg)
            var t1 = Int(perf_counter_ns())
            cap.record(sc)
            var t2 = Int(perf_counter_ns())
            reg.record(sc)
            ts += t1 - t0
            tr += t2 - t1
        var rd = CaptureReader(cap.to_bytes())
        var t3 = Int(perf_counter_ns())
        for k in range(60):
            _ = rd.frame(k)
        var td = (Int(perf_counter_ns()) - t3) // 60
        print("|", n, "|", ts // 60000, "|", tr // 60000, "|", len(cap.frames[1]), "|", len(cap.keys[0]), "|", td // 1000, "|", len(reg.frames[1]), "|")
    print("")
