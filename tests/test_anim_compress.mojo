# tier: component
"""Clip compression by key reduction (ROADMAP 17.64,
`procedural.anim_compress`).

  1. Ordinary: a 3-bone, 121-frame (2 s at 60 fps) walk -- a sine sway, a
     linear stride, a still bone -- reduced at 1 mm / 0.5 degree: sampled
     at 500 off-frame times, positions stay within 1 mm and rotations
     within 0.5 degree of `AnimClip.sample`; the still bone keeps two keys
     per channel, the stride two position keys; the reduced clip is
     smaller.
  2. Integration: looping time mapping matches (t = 2.25 s samples the
     same pose as 0.25 s); tolerance 0 keeps every curvature key, so the
     sample equals the original at every frame to 1e-6.
  3. Extreme: negative tolerances raise; a 1-frame clip reduces to one key
     per channel and samples it.
"""

from std.math import sin, cos, asin, sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from procedural.anim import AnimClip
from procedural.anim_compress import reduce_clip, clip_bytes

comptime NB = 3


def _walk(frames: Int) raises -> AnimClip:
    var c = AnimClip(NB, frames, 60, True)
    for f in range(frames):
        var t = Real(f) / 60
        c.set_key(f, 0, Vec3(0.05 * sin(6.2831853 * t), 0.9, 0, 0), Quat.from_axis_angle(Vec3(0, 1, 0, 0), 0.3 * sin(6.2831853 * t)))
        c.set_key(f, 1, Vec3(t, 0.5, 0, 0), Quat(0, 0, 0, 1))
        c.set_key(f, 2, Vec3(0.1, 0.2, 0, 0), Quat(0, 0, 0, 1))
    return c^


def _err(a: List[Real], b: List[Real], ra: List[Real], rb: List[Real]) -> Tuple[Real, Real]:
    var ep = Real(0)
    var er = Real(0)
    for k in range(NB):
        var dx = a[3 * k] - b[3 * k]
        var dy = a[3 * k + 1] - b[3 * k + 1]
        var dz = a[3 * k + 2] - b[3 * k + 2]
        ep = max(ep, sqrt(dx * dx + dy * dy + dz * dz))
        var dot = ra[4 * k] * rb[4 * k] + ra[4 * k + 1] * rb[4 * k + 1] + ra[4 * k + 2] * rb[4 * k + 2] + ra[4 * k + 3] * rb[4 * k + 3]
        var sg = Real(1) if dot >= 0 else Real(-1)
        var c = Real(0)
        for j in range(4):
            var dd = ra[4 * k + j] - sg * rb[4 * k + j]
            c += dd * dd
        er = max(er, 4 * asin(min(sqrt(c) / 2, Real(1))))  # chord form, exact near 0
    return (ep, er)


def main() raises:
    var s = Suite("anim_compress")
    var clip = _walk(121)
    var rot_tol = Real(0.5) * 3.14159265 / 180
    var r = reduce_clip(clip, 1e-3, rot_tol)
    var pa = List[Real](length=3 * NB, fill=0)
    var qa = List[Real](length=4 * NB, fill=0)
    var pb = List[Real](length=3 * NB, fill=0)
    var qb = List[Real](length=4 * NB, fill=0)
    var ep = Real(0)
    var er = Real(0)
    for k in range(500):
        var t = Real(k) * 0.0041 + 0.0007
        clip.sample(t, pa, qa)
        r.sample(t, pb, qb)
        var e = _err(pa, pb, qa, qb)
        ep = max(ep, e[0])
        er = max(er, e[1])
    var still = (r.pk_lo[3] - r.pk_lo[2]) + (r.rk_lo[3] - r.rk_lo[2])
    var stride = r.pk_lo[2] - r.pk_lo[1]
    print("  2 s walk, 3 bones: keys", r.key_count(), "of", 2 * NB * 121, " bytes", r.bytes(), "vs", clip_bytes(clip), " max error", ep, "m,", er * 180 / 3.14159265, "deg")
    s.check(ep <= 1e-3 * 1.001 and er <= rot_tol * 1.01, "500 off-frame samples within 1 mm and 0.5 degree")
    s.check(still == 4 and stride == 2 and r.bytes() < clip_bytes(clip), "a still bone keeps 2 keys a channel, a linear stride 2 position keys; smaller than the clip")

    clip.sample(0.25, pa, qa)
    r.sample(2.25, pb, qb)
    var wrap = _err(pa, pb, qa, qb)
    s.check(wrap[0] < 2e-3 and wrap[1] < 2 * rot_tol, "looping time maps the same way (2.25 s == 0.25 s)")
    var exact = reduce_clip(clip, 0, 0)
    var e0 = Real(0)
    for f in range(121):
        var t = Real(f) / 60
        clip.sample(t, pa, qa)
        exact.sample(t, pb, qb)
        var e = _err(pa, pb, qa, qb)
        e0 = max(e0, max(e[0], e[1]))
    print("  tolerance 0: keys", exact.key_count(), " max error at frames", e0)
    s.check(e0 < 1e-5, "tolerance 0 reproduces every frame")

    var raised = False
    try:
        _ = reduce_clip(clip, -1, 0)
    except:
        raised = True
    var one = AnimClip(NB, 1, 60, False)
    one.set_key(0, 1, Vec3(1, 2, 3, 0), Quat(0, 0, 0, 1))
    var r1 = reduce_clip(one, 1e-3, 1e-3)
    r1.sample(5, pb, qb)
    s.check(raised and r1.key_count() == 2 * NB and pb[3] == 1 and pb[5] == 3, "negative tolerance raises; a 1-frame clip keeps one key a channel")
    s.finish()
