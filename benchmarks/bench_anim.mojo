"""Animation runtime: what a bone costs per frame, and what a blend mode costs.

Sampling is priced apart from blending because they scale differently: sampling
is one interpolation per bone per playing clip, blending is one per bone per
frame regardless of how many clips are involved. A runtime that cross-fades
everything pays the second on every bone; one that mostly plays a single clip
pays it only during transitions.

The three blend modes are the point of the table. They are ordered by what they
guarantee, not by what they cost, and the costs come out in the same order:

  linear    normalised lerp on the quaternion. Cheapest. NOT constant angular
            speed -- `test_anim` measures it landing at 0.283 where constant
            speed puts 0.319, a 11% lag a quarter of the way through a
            150-degree blend. At exactly halfway it coincides with the geodesic,
            which is why a midpoint-only comparison would show no difference.
  dlb       dual-quaternion linear blend on the motor. Handles translation and
            rotation as one object, which is what removes the candy-wrapper
            collapse from skinning.
  geodesic  exp/log on the motor manifold: the actual shortest screw path, and
            the only constant-speed one.

Run with: `mojo run -I build benchmarks/bench_anim.mojo`.
"""

from std.benchmark import keep
from std.math import sin, cos, pi
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from geometry.motor import Motor3
from procedural.anim import (
    AnimClip, AnimPlayer, blend_poses, pose_to_motors,
    BLEND_LINEAR, BLEND_DLB, BLEND_GEODESIC,
)
from harness.bench import BenchTable, now

comptime FRAMES = 240


def flat(n: Int) -> List[Real]:
    var v = List[Real](capacity=n)
    for _ in range(n):
        v.append(0)
    return v^


def quats(bones: Int, spread: Real) -> List[Real]:
    var v = List[Real](capacity=4 * bones)
    for b in range(bones):
        var a = spread * Real(b % 7) / 7.0
        v.append(0)
        v.append(sin(a * 0.5))
        v.append(0)
        v.append(cos(a * 0.5))
    return v^


def clip_of(bones: Int, frames: Int) -> AnimClip:
    var c = AnimClip(bones, frames, 30.0, True)
    for f in range(frames):
        var t = Real(f) / Real(frames - 1)
        for b in range(bones):
            var a = Real(pi) * t * Real((b % 5) + 1) / 5.0
            c.set_key(
                f, b, Vec3(t * Real(b), 0, 0),
                Quat(0, sin(a * 0.5), 0, cos(a * 0.5)),
            )
    return c^


def bench_sample(mut table: BenchTable, bones: Int):
    var c = clip_of(bones, 60)
    var p = flat(3 * bones)
    var r = flat(4 * bones)
    var t0 = now()
    for f in range(FRAMES):
        c.sample(Real(f) / 60.0, p, r)
    keep(p[0])
    var t1 = now()
    table.add("sample", bones, "bone-frame", t1 - t0, FRAMES * bones)


def bench_blend(mut table: BenchTable, bones: Int, mode: Int, label: String):
    var pa = flat(3 * bones)
    var pb = flat(3 * bones)
    var ra = quats(bones, 0.4)
    var rb = quats(bones, 2.6)
    for i in range(3 * bones):
        pb[i] = Real(i) * 0.01
    var op = flat(3 * bones)
    var orr = flat(4 * bones)
    var t0 = now()
    for f in range(FRAMES):
        blend_poses(
            pa, ra, pb, rb, bones, Real(f) / Real(FRAMES), mode, op, orr
        )
    keep(orr[0])
    var t1 = now()
    table.add(label, bones, "bone-frame", t1 - t0, FRAMES * bones)


def bench_player(mut table: BenchTable, bones: Int, fading: Bool):
    var clips = List[AnimClip]()
    clips.append(clip_of(bones, 60))
    clips.append(clip_of(bones, 60))
    var pl = AnimPlayer(bones, BLEND_DLB)
    if fading:
        pl.play(1, 1e9)  # a fade long enough that every frame is mid-blend
    var p = flat(3 * bones)
    var r = flat(4 * bones)
    var t0 = now()
    for _ in range(FRAMES):
        pl.advance(1.0 / 60.0)
        pl.evaluate(clips, p, r)
    keep(p[0])
    var t1 = now()
    table.add(
        "player " + ("cross-fading" if fading else "single clip"),
        bones, "bone-frame", t1 - t0, FRAMES * bones,
    )


def bench_motors(mut table: BenchTable, bones: Int):
    var p = flat(3 * bones)
    var r = quats(bones, 1.2)
    var m = List[Motor3](capacity=bones)
    for _ in range(bones):
        m.append(Motor3.identity())
    var t0 = now()
    for _ in range(FRAMES):
        pose_to_motors(p, r, bones, m)
    keep(m[0].s)
    var t1 = now()
    table.add("pose -> motors", bones, "bone-frame", t1 - t0, FRAMES * bones)


def main() raises:
    var table = BenchTable("Animation runtime (per bone per frame)")
    for k in range(2):
        var bones = 32 if k == 0 else 256
        bench_sample(table, bones)
        bench_blend(table, bones, BLEND_LINEAR, "blend linear")
        bench_blend(table, bones, BLEND_DLB, "blend dlb (motor)")
        bench_blend(table, bones, BLEND_GEODESIC, "blend geodesic (exp/log)")
        bench_motors(table, bones)
        bench_player(table, bones, False)
        bench_player(table, bones, True)
    table.print_report()
