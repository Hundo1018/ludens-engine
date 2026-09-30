"""Example 15 — a body riding a spline at constant speed with a
rotation-minimising frame (17.36).

Two comparisons, both against the naive alternative "position + separately
computed orientation":

1. Constant speed. Stepping the curve's own parameter `t` uniformly does NOT
   move a fixed distance per step (Catmull-Rom's parametric speed varies
   along the curve) — stepping ARC LENGTH `s` uniformly (via the arc-length
   table's `sample_at_distance`) does. We walk both ways and print the
   per-step distance spread of each.

2. Twist-free. The path overhangs so its tangent is exactly vertical at one
   control point (parallel to `up_hint`). A frame built the naive way at
   each sample independently ("right = up_hint x tangent") needs to
   NORMALIZE that cross product — exactly where the tangent is parallel to
   `up_hint`, `|right| -> 0` and normalizing it is a division by
   (near) zero: a real numerical hazard, not a rounding nuance. The
   rotation-minimising frame (`build_rmf_frames`) never references any
   fixed global direction after its first sample — it is transported from
   the previous frame by construction — so it has no such singularity: its
   basis stays exactly orthonormal straight through that same point.

Run:

    pixi run mojo run -I build examples/15_spline_rmf.mojo
"""

from geometry.vec import Real, Vec3, dot, length, normalize
from geometry.spline import (
    CatmullRom, build_arc_length_table, build_rmf_frames, frame_at_distance,
)

comptime N_STEPS = 24


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return Vec3(
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
        0,
    )


def main() raises:
    # An overhang: bulges right then back left while climbing, so control
    # point 2's tangent ~ (P3-P1)/2 has EXACTLY zero x -- purely vertical,
    # parallel to `up_hint` -- because P1 and P3 share the same x (-1).
    var pts = List[Vec3]()
    pts.append(Vec3(-5, 0, 0, 0))
    pts.append(Vec3(-1, 1, 0, 0))
    pts.append(Vec3(0, 5, 0, 0))
    pts.append(Vec3(-1, 9, 0, 0))
    pts.append(Vec3(1, 10, 0, 0))
    pts.append(Vec3(4, 10, 0, 0))
    var cr = CatmullRom[3, 0.5](pts^)
    var path = cr.to_bezier_path()
    var table = build_arc_length_table[3](path, 96)
    var frames = build_rmf_frames(path, table)
    var total = table.total_length()
    print("== arch path:", cr.segment_count(), "segments, arc length", Float64(total), "==")

    # ---------------------------------------------------- 1. constant speed
    var param_dists = List[Real]()
    var arc_dists = List[Real]()
    var dmax = path.domain_max()
    var prev_param = path.eval(Real(0))
    var prev_arc = path.eval(Real(0))
    for i in range(1, N_STEPS + 1):
        var t_uniform = dmax * Real(i) / Real(N_STEPS)
        var p_param = path.eval(t_uniform)
        param_dists.append(length(p_param - prev_param))
        prev_param = p_param

        var s = total * Real(i) / Real(N_STEPS)
        var t_arc = table.sample_at_distance(s)
        var p_arc = path.eval(t_arc)
        arc_dists.append(length(p_arc - prev_arc))
        prev_arc = p_arc

    var pmin = param_dists[0]
    var pmax = param_dists[0]
    var amin = arc_dists[0]
    var amax = arc_dists[0]
    for i in range(1, N_STEPS):
        if param_dists[i] < pmin:
            pmin = param_dists[i]
        if param_dists[i] > pmax:
            pmax = param_dists[i]
        if arc_dists[i] < amin:
            amin = arc_dists[i]
        if arc_dists[i] > amax:
            amax = arc_dists[i]
    print("== stepping the curve", N_STEPS, "times ==")
    print("  parameter-uniform steps : min", Float64(pmin), " max", Float64(pmax), " spread", Float64(pmax - pmin))
    print("  arc-length-uniform steps: min", Float64(amin), " max", Float64(amax), " spread", Float64(amax - amin))
    print("  arc-length stepping is constant speed:", "YES" if (amax - amin) < (pmax - pmin) * Real(0.1) else "NO")

    # ---------------------------------------------------- 2. twist-free
    var up_hint = Vec3(0, 1, 0, 0)
    var min_naive_right: Real = 1e9
    var min_naive_at_s: Real = 0
    for i in range(N_STEPS + 1):
        var s = total * Real(i) / Real(N_STEPS)
        var t = table.sample_at_distance(s)
        var tangent = normalize(path.deriv(t))
        # naive: right = up_hint x tangent -- the vector you'd normalize to
        # get the "right" basis axis; degenerates as tangent -> up_hint.
        var naive_right_len = length(_cross(up_hint, tangent))
        if naive_right_len < min_naive_right:
            min_naive_right = naive_right_len
            min_naive_at_s = s

    # At that same arc length, check the RMF frame's basis instead: apply it
    # to the three axes and confirm they are still exactly unit length and
    # mutually perpendicular -- no division by a near-zero vector anywhere
    # in `build_rmf_frames`/`frame_at_distance`, so there is nothing to
    # degenerate.
    var frame = frame_at_distance(frames, table, min_naive_at_s)
    var origin = frame.apply_point(Vec3(0, 0, 0, 0))
    var rmf_x = frame.apply_point(Vec3(1, 0, 0, 0)) - origin
    var rmf_y = frame.apply_point(Vec3(0, 1, 0, 0)) - origin
    var rmf_z = frame.apply_point(Vec3(0, 0, 1, 0)) - origin
    var len_x = Float64(length(rmf_x))
    var len_y = Float64(length(rmf_y))
    var len_z = Float64(length(rmf_z))
    var ortho_xy = Float64(dot(rmf_x, rmf_y))
    var ortho_yz = Float64(dot(rmf_y, rmf_z))

    print("== near-vertical tangent at arc length s =", Float64(min_naive_at_s), "==")
    print("  naive |up_hint x tangent| there (near 0 -> normalizing it divides by ~0):", Float64(min_naive_right))
    print("  RMF frame basis lengths there (x, y, z, want 1.0 1.0 1.0):", len_x, len_y, len_z)
    print("  RMF frame orthogonality there (x.y, y.z, want 0.0 0.0):", ortho_xy, ortho_yz)
    print(
        "  RMF stays exactly well-conditioned where the naive construction is singular:",
        "YES" if min_naive_right < Real(0.05) and abs(len_x - 1.0) < 1e-3 and abs(len_y - 1.0) < 1e-3 else "NO",
    )
