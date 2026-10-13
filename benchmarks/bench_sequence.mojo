"""ROADMAP 17.68: sequence evaluation, random seek vs playback cursor.

32 Vec3 tracks and 32 quaternion tracks with K keys each, played for 600
frames at 60 Hz over a 10 s sequence. A seek finds each track's segment by
binary search; the cursor walks from the last segment. Both return the same
values bit for bit (`test_camera_seq`). Nanoseconds per frame for all 64
tracks, and the spring arm's update against an empty scene and one wall.
"""

from std.time import perf_counter_ns
from std.benchmark import keep
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from procedural.sequence import Sequence, SeqCursor
from gameplay.camera_rig import SpringArm


def _seq(keys: Int) raises -> Sequence:
    var s = Sequence(10)
    for _ in range(32):
        var v = s.add_vec3_track()
        var q = s.add_quat_track()
        for i in range(keys):
            var t = Real(i) * 10 / Real(keys - 1)
            s.key_vec3(v, t, Vec3(t, Real(i % 5), 0, 0))
            s.key_quat(q, t, Quat.from_axis_angle(Vec3(0, 1, 0, 0), t))
    return s^


def main() raises:
    print("### Sequences and camera rig (17.68)\n")
    print("| keys per track | seek ns / frame | cursor ns / frame |")
    print("|---:|---:|---:|")
    for keys in [8, 128, 2048]:
        var s = _seq(keys)
        var acc = Real(0)
        var t0 = Int(perf_counter_ns())
        for f in range(600):
            var t = Real(f) / 60
            for k in range(32):
                acc += s.vec3(k, t)[0] + s.quat(k, t).w
        var t1 = Int(perf_counter_ns())
        var c = SeqCursor(s)
        var ev = List[Int]()
        for _ in range(600):
            c.advance(s, 1.0 / 60.0, ev)
            for k in range(32):
                acc += c.vec3(s, k)[0] + c.quat(s, k).w
        var t2 = Int(perf_counter_ns())
        keep(acc)
        print("|", keys, "|", (t1 - t0) // 600, "|", (t2 - t1) // 600, "|")
    print("")
    print("| spring arm scene | ns / update |")
    print("|---|---:|")
    for walls in [0, 1]:
        var sc = ContactScene6[QuatBody6]()
        if walls == 1:
            _ = sc.add(QuatBody6.at_rest(Vec3(0, 0, 2.5, 0), Inertia3.box(1, 3, 3, 0.5)), Vec3(3, 3, 0.5, 0), True)
        var arm = SpringArm(5, 0.2)
        var t3 = Int(perf_counter_ns())
        for k in range(1000):
            arm.aim(Real(k) * 0.01, 0.3)
            _ = arm.update(sc, Vec3(0, 1, 0, 0), 1.0 / 60.0)
        print("| empty" if walls == 0 else "| one wall", "|", (Int(perf_counter_ns()) - t3) // 1000, "|")
    print("")
