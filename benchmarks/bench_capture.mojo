"""ROADMAP 17.80: cost and size of a physics capture.

N boxes in columns of 1-4 on a floor, 60 steps timed after 30 settling
steps (60 more when sleep is allowed, so the piles are asleep), keyframe
every 60 frames. Version 1 writes every frame in full, version 2 (the
default) only what changed since the previous frame. Columns: step time,
`Capture.record` time per frame, mean bytes per non-key frame, keyframe
bytes, `CaptureReader.frame` decode time (version 2 replays from the last
keyframe, so frame k costs k - key frames), and the version 2 frame size
with a region covering about a tenth of the floor.
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


def _scene(n: Int, mut side_out: Int, sleep: Bool) -> ContactScene6[QuatBody6]:
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
            if not sleep:
                try:
                    sc.set_can_sleep(id, False)
                except:
                    pass
            k += 1
        col += 1
    return sc^


def _mean_frame(cap: Capture) -> Int:
    var t = 0
    var c = 0
    for k in range(len(cap.frames)):
        if k % cap.key_every != 0:
            t += len(cap.frames[k])
            c += 1
    return t // max(c, 1)


def main() raises:
    print("### Physics capture (17.80): full frames (v1) vs deltas (v2)\n")
    print("| N | piles | step us | record us v1 / v2 | frame bytes v1 / v2 | keyframe bytes | decode us v1 / v2 | region frame bytes |")
    print("|---:|---|---:|---|---|---:|---|---:|")
    for n in [64, 1024]:
        for sleep in [False, True]:
            var side = 0
            var sc = _scene(n, side, sleep)
            var cfg = SolverConfig()
            cfg.broadphase = True
            for _ in range(90 if sleep else 30):
                sc.step(DT, G, cfg)
            var c1 = Capture(60, False)
            var c2 = Capture(60)
            var reg = Capture(60)
            var half = Real(side) * 0.275 * 0.32
            reg.set_region(AABB[3](Vec3(-half, -0.1, -half, 0), Vec3(half, 5, half, 0)))
            var ts = 0
            var t1s = 0
            var t2s = 0
            for _ in range(60):
                var t0 = Int(perf_counter_ns())
                sc.step(DT, G, cfg)
                var t1 = Int(perf_counter_ns())
                c1.record(sc)
                var t2 = Int(perf_counter_ns())
                c2.record(sc)
                var t3 = Int(perf_counter_ns())
                reg.record(sc)
                ts += t1 - t0
                t1s += t2 - t1
                t2s += t3 - t2
            var r1 = CaptureReader(c1.to_bytes())
            var r2 = CaptureReader(c2.to_bytes())
            var t4 = Int(perf_counter_ns())
            for k in range(60):
                _ = r1.frame(k)
            var t5 = Int(perf_counter_ns())
            for k in range(60):
                _ = r2.frame(k)
            var t6 = Int(perf_counter_ns())
            print("|", n, "|", "asleep" if sleep else "awake", "|", ts // 60000, "|", t1s // 60000, "/", t2s // 60000, "|", _mean_frame(c1), "/", _mean_frame(c2), "|", len(c2.keys[0]), "|", (t5 - t4) // 60000, "/", (t6 - t5) // 60000, "|", _mean_frame(reg), "|")
    print("")
