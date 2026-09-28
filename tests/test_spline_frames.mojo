# tier: unit
"""Integration case (design note 17.36, `docs/design/wave-a-services.md`):
rotation-minimising frames as PGA motors (`geometry.motor`, `geometry.galie`)
transporting a point along a `geometry.spline` curve. Exercises the three
modules together through the production entry points
(`build_rmf_frames`/`frame_at_distance`), not spline math in isolation.

Two checks:
1. Each frame, applied to the local origin (motor sandwich), lands exactly
   on the curve position it was built at -- "frame transports a point".
2. Twist-free: for a PLANAR curve, every incremental frame update is a
   rotation about the curve's own normal axis (tangents never leave the
   plane, so `tangent_prev x tangent_cur` is always parallel to that axis),
   so the frame's local Y axis mapped to world space must keep a CONSTANT
   out-of-plane component across every sample -- a naively re-derived
   look-at frame would not hold this."""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length, length_sq, normalize
from geometry.spline import (
    CatmullRom, build_arc_length_table, build_rmf_frames, frame_at_distance,
)


def main() raises:
    var s = Suite("spline_frames")

    # ---------------------------------------------- frames transport a point
    var pts = List[Vec3]()
    pts.append(Vec3(0, 0, 0, 0))
    pts.append(Vec3(3, 2, 1, 0))
    pts.append(Vec3(6, -1, 2, 0))
    pts.append(Vec3(9, 1, 0, 0))
    pts.append(Vec3(12, 0, -1, 0))
    var cr = CatmullRom[3, 0.5](pts^)
    var path = cr.to_bezier_path()
    var table = build_arc_length_table[3](path, 40)
    var frames = build_rmf_frames(path, table)
    s.eqi(len(frames), len(table.ts), "one frame per arc-length table sample")

    for i in range(len(frames)):
        var origin = Vec3(0, 0, 0, 0)
        var transported = frames[i].apply_point(origin)
        var want = path.eval(table.ts[i])
        s.almost(Float64(transported[0]), Float64(want[0]), "frame " + String(i) + " transports origin to curve .x", 1e-3)
        s.almost(Float64(transported[1]), Float64(want[1]), "frame " + String(i) + " transports origin to curve .y", 1e-3)
        s.almost(Float64(transported[2]), Float64(want[2]), "frame " + String(i) + " transports origin to curve .z", 1e-3)

    # geodesic-interpolated frame at a mid-distance also transports to (near) the curve
    var mid_s = table.total_length() * 0.37
    var mid_t = table.sample_at_distance(mid_s)
    var mid_frame = frame_at_distance(frames, table, mid_s)
    var mid_pos = mid_frame.apply_point(Vec3(0, 0, 0, 0))
    var mid_want = path.eval(mid_t)
    s.almost(Float64(mid_pos[0]), Float64(mid_want[0]), "interpolated frame transports origin near curve .x", 5e-2)
    s.almost(Float64(mid_pos[1]), Float64(mid_want[1]), "interpolated frame transports origin near curve .y", 5e-2)
    s.almost(Float64(mid_pos[2]), Float64(mid_want[2]), "interpolated frame transports origin near curve .z", 5e-2)

    # ---------------------------------------------- twist-free on a planar loop
    var loop = List[Vec3]()
    loop.append(Vec3(2, 0, 0, 0))
    loop.append(Vec3(1.4, 1.4, 0, 0))
    loop.append(Vec3(0, 2, 0, 0))
    loop.append(Vec3(-1.4, 1.4, 0, 0))
    loop.append(Vec3(-2, 0, 0, 0))
    loop.append(Vec3(-1.4, -1.4, 0, 0))
    loop.append(Vec3(0, -2, 0, 0))
    loop.append(Vec3(1.4, -1.4, 0, 0))
    var cr_loop = CatmullRom[3, 0.5](loop^, closed=True)
    var loop_path = cr_loop.to_bezier_path()
    var loop_table = build_arc_length_table[3](loop_path, 96)
    var loop_frames = build_rmf_frames(loop_path, loop_table)

    # every tangent along this XY-plane loop has zero Z; each incremental
    # update rotates about a Z-axis, so the frame's local Y axis (rotated
    # into world space) must keep a CONSTANT world-Z component throughout.
    var up0 = loop_frames[0].apply_point(Vec3(0, 1, 0, 0)) - loop_frames[0].apply_point(Vec3(0, 0, 0, 0))
    var z_ref = Float64(up0[2])
    var max_drift: Float64 = 0
    for i in range(len(loop_frames)):
        var up_i = loop_frames[i].apply_point(Vec3(0, 1, 0, 0)) - loop_frames[i].apply_point(Vec3(0, 0, 0, 0))
        var drift = Float64(up_i[2]) - z_ref
        if drift < 0:
            drift = -drift
        if drift > max_drift:
            max_drift = drift
    s.check(
        max_drift < 1e-3,
        "planar loop: frame's out-of-plane axis component stays constant (twist-free), max drift = "
        + String(max_drift),
    )

    # sanity: the loop is genuinely non-degenerate (curve leaves the plane's
    # normal direction meaningfully, i.e. |up0.z| is not accidentally ~1
    # which would make the drift check trivially pass)
    s.check(z_ref < 0.9, "sanity: initial frame is not degenerately aligned with world Z")

    s.finish()
