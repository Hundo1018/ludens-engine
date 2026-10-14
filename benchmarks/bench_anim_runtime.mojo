"""ROADMAP 17.64: fade vs inertialized transitions, swept over the share of
characters that are mid-transition.

100 characters with 32 bones each, two looping clips. A share of them
(0 / 50 / 100 %) is held inside a very long transition; the rest play one
clip. A fading character samples two clips and blends them; an
inertializing one samples one clip and adds a decaying offset. Nanoseconds
per character tick, and per bone.

Second table: one clip of the same skeleton, uniform keys (`AnimClip`) vs
key-reduced at 1 mm / 0.5 degree (`reduce_clip`): bytes, keys and ns per
sample (10000 samples at scattered times).
"""

from std.time import perf_counter_ns
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from procedural.anim import AnimClip
from procedural.anim_events import EventTrack
from procedural.anim_state import AnimGraph, AnimTransition, Cond, COND_GT, TRANS_FADE, TRANS_INERTIAL
from procedural.tween import EASE_LINEAR
from procedural.anim_compress import reduce_clip, clip_bytes

comptime BONES = 32
comptime CHARS = 100


def _clip(phase: Real) raises -> AnimClip:
    var c = AnimClip(BONES, 31, 30, True)
    for f in range(31):
        var u = Real(f) / 30
        for b in range(BONES):
            c.set_key(f, b, Vec3(u + phase, Real(b) * 0.1, 0, 0), Quat.from_axis_angle(Vec3(0, 1, 0, 0), u * 2 + phase + Real(b) * 0.01))
    return c^


def _ns(mode: Int, share: Int, clips: List[AnimClip]) raises -> Int:
    var tracks = List[EventTrack]()
    var gs = List[AnimGraph]()
    for k in range(CHARS):
        var g = AnimGraph(BONES, mode)
        var a = g.add_state(0)
        var b = g.add_state(1)
        var go = g.add_float(0)
        g.add_transition(AnimTransition(a, b, [Cond(COND_GT, go, 0.5)], -1, 1e6, EASE_LINEAR, True))
        gs.append(g^)
    var pos = List[Real](length=3 * BONES, fill=0)
    var rot = List[Real](length=4 * BONES, fill=0)
    var ev = List[Int]()
    for k in range(CHARS):
        gs[k].tick(1.0 / 60.0, clips, tracks, pos, rot, ev)
        if k * 100 < share * CHARS:
            gs[k].floats[0] = 1
        gs[k].tick(1.0 / 60.0, clips, tracks, pos, rot, ev)
    var t0 = Int(perf_counter_ns())
    for _ in range(60):
        for k in range(CHARS):
            gs[k].tick(1.0 / 60.0, clips, tracks, pos, rot, ev)
    return (Int(perf_counter_ns()) - t0) // (60 * CHARS)


def main() raises:
    var clips = List[AnimClip]()
    clips.append(_clip(0))
    clips.append(_clip(0.5))
    print("### Animation transitions (17.64): fade vs inertialization, 100 characters x 32 bones\n")
    print("| in transition | fade ns / character | inertial ns / character | fade ns / bone | inertial ns / bone |")
    print("|---:|---:|---:|---:|---:|")
    for share in [0, 50, 100]:
        var f = _ns(TRANS_FADE, share, clips)
        var i = _ns(TRANS_INERTIAL, share, clips)
        print("|", share, "% |", f, "|", i, "|", f // BONES, "|", i // BONES, "|")
    print("")
    print("### Clip storage: uniform vs key-reduced (17.64)\n")
    print("| clip | keys | bytes | ns per sample |")
    print("|---|---:|---:|---:|")
    var c = _clip(0)
    var r = reduce_clip(c, 1e-3, 0.0087266)
    var pos = List[Real](length=3 * BONES, fill=0)
    var rot = List[Real](length=4 * BONES, fill=0)
    var t0 = Int(perf_counter_ns())
    for k in range(10000):
        c.sample(Real(k) * 0.000731, pos, rot)
    var t1 = Int(perf_counter_ns())
    for k in range(10000):
        r.sample(Real(k) * 0.000731, pos, rot)
    var t2 = Int(perf_counter_ns())
    print("| uniform |", 2 * BONES * c.frames, "|", clip_bytes(c), "|", (t1 - t0) // 10000, "|")
    print("| reduced |", r.key_count(), "|", r.bytes(), "|", (t2 - t1) // 10000, "|")
    print("")
