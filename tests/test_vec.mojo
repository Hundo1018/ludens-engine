# tier: unit
from harness.runner import Suite
from geometry.vec import Vec2, Vec3, dot, length, length_sq, normalize, lane_min, lane_max


def main() raises:
    var s = Suite("vec")

    var a = Vec2(3, 4)
    s.almost(Float64(length_sq(a)), 25.0, "len_sq 3-4")
    s.almost(Float64(length(a)), 5.0, "length 3-4-5")
    s.almost(Float64(dot(Vec2(1, 0), Vec2(0, 1))), 0.0, "perp dot")
    s.almost(Float64(dot(Vec2(2, 3), Vec2(4, 5))), 23.0, "dot 2x3 . 4x5")

    # width-3: manual reduction must NOT drop the 3rd lane (1+4+4 = 9 -> 3)
    var b = Vec3(1, 2, 2, 0)
    s.almost(Float64(length(b)), 3.0, "vec3 length width-3")
    s.almost(Float64(length_sq(Vec3(2, 3, 6, 0))), 49.0, "vec3 len_sq")

    var n = normalize(Vec2(0, 8))
    s.almost(Float64(n[1]), 1.0, "normalize y")
    s.almost(Float64(length(n)), 1.0, "normalized length")

    var mn = lane_min(Vec3(1, 5, 3, 0), Vec3(4, 2, 9, 0))
    s.almost(Float64(mn[0]), 1.0, "lane_min x")
    s.almost(Float64(mn[1]), 2.0, "lane_min y")
    var mx = lane_max(Vec3(1, 5, 3, 0), Vec3(4, 2, 9, 0))
    s.almost(Float64(mx[2]), 9.0, "lane_max z")

    # ---- the padding invariant ----
    # Vec3 is four lanes with lane 3 pinned to zero, and `dot` reduces over
    # every lane, so a non-zero pad lane would corrupt every dot product,
    # length and normalisation in the engine. This gate is why that cannot
    # regress silently: a Vec3 built or derived any of these ways must have a
    # zero pad lane. Getting it wrong is not a small error -- an unpadded
    # construction left lane 3 uninitialised and produced a GJK that looped
    # forever, two solver crashes, and a comptime heap exhaustion.
    var pa = Vec3(1, 2, 3, 0)
    var pb = Vec3(-4, 5, -6, 0)
    var pad_ok = True
    if (pa + pb)[3] != 0: pad_ok = False
    if (pa - pb)[3] != 0: pad_ok = False
    if (pa * 3.5)[3] != 0: pad_ok = False
    if (pa / 2.0)[3] != 0: pad_ok = False
    if (-pa)[3] != 0: pad_ok = False
    if normalize(pa)[3] != 0: pad_ok = False
    if lane_min(pa, pb)[3] != 0: pad_ok = False
    if lane_max(pa, pb)[3] != 0: pad_ok = False
    if Vec3(0)[3] != 0: pad_ok = False
    s.check(pad_ok, "every Vec3 op keeps the pad lane at zero")
    s.check(
        abs(Float64(dot(pa, pb) - (-4.0 + 10.0 - 18.0))) < 1e-5,
        "dot ignores the pad lane because the pad lane is zero",
    )

    s.finish()
