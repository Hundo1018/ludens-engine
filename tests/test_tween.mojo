# tier: unit  (override: exercises procedural.tween alone; the geometry imports are its value types and the reference geodesic)
"""Easing (17.35): endpoint exactness and in/out symmetry for all 31 curves,
comptime-vs-runtime dispatch agreement, and `Tween[T]` ordinary/extreme
behavior for `Real`, `Vec3` and PGA motors (screw-interpolated via
`geometry.galie.geodesic3`/`geodesic2`, compared BY ACTION on points per
`docs/CATEGORY.md` §3's convention -- `M` and `-M` are the same motion)."""

from harness.runner import Suite
from procedural.tween import (
    Tween,
    ease,
    ease_dyn,
    lerp_real,
    lerp_vec3,
    EASE_LINEAR,
    EASE_QUAD_IN,
    EASE_QUAD_OUT,
    EASE_QUAD_INOUT,
    EASE_BACK_OUT,
    EASE_ELASTIC_OUT,
    EASE_BOUNCE_OUT,
    EASE_COUNT,
)
from geometry.vec import Real, Vec2, Vec3
from geometry.motor import Motor2, Motor3
from geometry.quat import Quat
from geometry.galie import geodesic2, geodesic3


def _endpoints(mut s: Suite):
    comptime for k in range(EASE_COUNT):
        s.almost(Float64(ease[k](0.0)), 0.0, "ease[" + String(k) + "](0)=0", 1e-4)
        s.almost(Float64(ease[k](1.0)), 1.0, "ease[" + String(k) + "](1)=1", 1e-4)


def _symmetry(mut s: Suite):
    # e_out(t) = 1 - e_in(1 - t) for every family, sampled across t.
    comptime for fam in range(10):
        comptime kin = 1 + fam * 3
        comptime kout = 2 + fam * 3
        for i in range(11):
            var t = Real(i) / 10.0
            s.almost(
                Float64(ease[kout](t)),
                Float64(1 - ease[kin](1 - t)),
                "sym fam=" + String(fam) + " t=" + String(i),
                1e-4,
            )


def _dyn_matches_comptime(mut s: Suite):
    comptime for k in range(EASE_COUNT):
        for i in range(5):
            var t = Real(i) / 4.0
            s.almost(
                Float64(ease_dyn(k, t)),
                Float64(ease[k](t)),
                "ease_dyn==ease[" + String(k) + "] t=" + String(i),
                1e-6,
            )


def _tween_real(mut s: Suite):
    var tw = Tween[Real, type_of(lerp_real), EASE_LINEAR](0.0, 10.0, 2.0, lerp_real)
    s.almost(Float64(tw.value_at(0.0)), 0.0, "real linear @0")
    s.almost(Float64(tw.value_at(1.0)), 10.0, "real linear @1")
    s.almost(Float64(tw.value_at(0.5)), 5.0, "real linear @0.5")

    var tq = Tween[Real, type_of(lerp_real), EASE_QUAD_IN](0.0, 4.0, 1.0, lerp_real)
    s.almost(Float64(tq.value_at(0.5)), 1.0, "real quad_in @0.5 = 4*0.25")

    # stateful advance/done
    var stateful = Tween[Real, type_of(lerp_real), EASE_LINEAR](0.0, 1.0, 1.0, lerp_real)
    s.check(not stateful.done(), "fresh tween not done")
    _ = stateful.advance(0.5)
    s.almost(Float64(stateful.u()), 0.5, "u() after half elapsed")
    _ = stateful.advance(0.5)
    s.check(stateful.done(), "done after full duration")


def _tween_vec3(mut s: Suite):
    var tv = Tween[Vec3, type_of(lerp_vec3), EASE_LINEAR](
        Vec3(0, 0, 0, 0), Vec3(10, 20, 30, 0), 1.0, lerp_vec3
    )
    var mid = tv.value_at(0.5)
    s.almost(Float64(mid[0]), 5.0, "vec3 @0.5 x")
    s.almost(Float64(mid[1]), 10.0, "vec3 @0.5 y")
    s.almost(Float64(mid[2]), 15.0, "vec3 @0.5 z")


def _near3(mut s: Suite, a: Vec3, b: Vec3, label: String):
    s.almost(Float64(a[0]), Float64(b[0]), label + " .x", 1e-3)
    s.almost(Float64(a[1]), Float64(b[1]), label + " .y", 1e-3)
    s.almost(Float64(a[2]), Float64(b[2]), label + " .z", 1e-3)


def _tween_motor3(mut s: Suite):
    var qa = Quat.from_axis_angle(Vec3(0, 0, 1, 0), 0.0)
    var qb = Quat.from_axis_angle(Vec3(0, 0, 1, 0), Real(1.5707963))
    var ma = Motor3.from_quat_translation(qa, Vec3(0, 0, 0, 0))
    var mb = Motor3.from_quat_translation(qb, Vec3(10, 0, 0, 0))
    var tm = Tween[Motor3, type_of(geodesic3), EASE_LINEAR](ma, mb, 1.0, geodesic3)

    var p = Vec3(1, 0, 0, 0)
    # endpoints equal the geodesic endpoints BY ACTION, not by coefficient.
    _near3(s, tm.value_at(0.0).apply_point(p), ma.apply_point(p), "motor tween @0")
    _near3(s, tm.value_at(1.0).apply_point(p), mb.apply_point(p), "motor tween @1")
    _near3(
        s,
        tm.value_at(0.5).apply_point(p),
        geodesic3(ma, mb, 0.5).apply_point(p),
        "motor tween @0.5 == raw geodesic",
    )


def _tween_motor2(mut s: Suite):
    var ma = Motor2.from_angle_translation(0.0, Vec2(0, 0))
    var mb = Motor2.from_angle_translation(Real(1.5707963), Vec2(5, 0))
    var tm = Tween[Motor2, type_of(geodesic2), EASE_LINEAR](ma, mb, 1.0, geodesic2)
    var p = Vec2(1, 0)
    var d0 = tm.value_at(0.0).apply_point(p) - ma.apply_point(p)
    var d1 = tm.value_at(1.0).apply_point(p) - mb.apply_point(p)
    s.almost(Float64(d0[0]), 0.0, "motor2 tween @0 x", 1e-3)
    s.almost(Float64(d0[1]), 0.0, "motor2 tween @0 y", 1e-3)
    s.almost(Float64(d1[0]), 0.0, "motor2 tween @1 x", 1e-3)
    s.almost(Float64(d1[1]), 0.0, "motor2 tween @1 y", 1e-3)


def _extreme(mut s: Suite):
    # zero-duration tween: done immediately, value is `end`.
    var tz = Tween[Real, type_of(lerp_real), EASE_LINEAR](1.0, 9.0, 0.0, lerp_real)
    s.check(tz.done(), "zero-duration tween done before any advance")
    s.almost(Float64(tz.value()), 9.0, "zero-duration tween value == end")

    # t outside [0,1] clamps -- documented, not an error.
    var t = Tween[Real, type_of(lerp_real), EASE_LINEAR](0.0, 10.0, 1.0, lerp_real)
    s.almost(Float64(t.value_at(-5.0)), 0.0, "t<0 clamps to start")
    s.almost(Float64(t.value_at(5.0)), 10.0, "t>1 clamps to end")

    # overshoot via advance() also clamps u() to 1, not >1.
    var t2 = Tween[Real, type_of(lerp_real), EASE_LINEAR](0.0, 10.0, 1.0, lerp_real)
    _ = t2.advance(100.0)
    s.almost(Float64(t2.u()), 1.0, "advance() overshoot clamps u to 1")
    s.check(t2.done(), "overshoot tween is done")

    # negative elapsed (e.g. a caller decrementing time) clamps u to 0.
    var t3 = Tween[Real, type_of(lerp_real), EASE_LINEAR](0.0, 10.0, 1.0, lerp_real)
    _ = t3.advance(-5.0)
    s.almost(Float64(t3.u()), 0.0, "negative elapsed clamps u to 0")

    # back/elastic/bounce OUT overshoot past [0,1] mid-curve -- that is
    # correct (the whole point of an overshoot easing), only the ENDPOINTS
    # are required to land exactly on 0/1.
    var over_mid = ease[EASE_BACK_OUT](0.9)
    s.check(Float64(over_mid) > 1.0, "back_out overshoots mid-curve by design")
    s.almost(Float64(ease[EASE_BACK_OUT](1.0)), 1.0, "back_out endpoint still exact")
    _ = ease[EASE_ELASTIC_OUT](0.9)
    _ = ease[EASE_BOUNCE_OUT](0.9)


def main() raises:
    var s = Suite("tween")
    _endpoints(s)
    _symmetry(s)
    _dyn_matches_comptime(s)
    _tween_real(s)
    _tween_vec3(s)
    _tween_motor3(s)
    _tween_motor2(s)
    _extreme(s)
    s.finish()
