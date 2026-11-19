"""The camera's lens as stages (app/post.mojo): depth of field and motion blur.

    comptime Lens = ThenPost[Stage[MotionBlur], Stage[DepthOfField]]
    var r = ArenaRendererOf[MyPasses, Lens](device, format, view)
    r.lens_focus = 8.0      # metres
    r.lens_fstop = 2.0      # 0 (the default) is a pinhole: DepthOfField then returns its input unchanged
    r.shutter = 0.5         # the shutter is open for half the time between two frames; 0 (default): no motion blur

Depth of field is the thin lens: a point at distance z, with the lens focused at zf, is drawn as a disc of diameter
    c = f^2 / (N (zf - f)) * |1 - zf / z|
on the sensor, f the focal length and N the f-number. f follows from the view's field of view and the sensor's height
(lens_sensor, 0.024 m by default): f = sensor / 2 / tan(fov / 2). The stage gathers 48 samples over the largest disc
(lens_max_coc pixels across, and at most twice the disc of a point at infinity); a sample counts where its own disc reaches the pixel, and a sample behind the pixel's
surface no further than the pixel's own disc, so a sharp surface is not smeared by the blurred ground behind it.
It is one pass of a gather, not a simulation of the lens: discs are flat and have no shape.

MotionBlur follows the camera only: each pixel's world point (from depth) is projected with the previous frame's
camera, and the stage averages 16 samples from where the point is to where it was, scaled by the shutter. A body that
moves while the camera stands still is not blurred by it. ObjectMotionBlur also blurs bodies that move, from the
velocity target of app/velocity.mojo.
"""
from game.camera_view import View
from app.post import Style


def focal_length(v: View, sensor: Float32) -> Float64:
    """The focal length (m) that gives the view's vertical field on a sensor of this height."""
    return Float64(sensor) * 0.5 * Float64(v.sy)


def coc_scale(v: View, focus: Float32, fstop: Float32, sensor: Float32, height: Float32) -> Float32:
    """K in `blur disc diameter in pixels = K * |1 - focus / z|` for a frame `height` pixels tall; 0 for a pinhole
    (fstop <= 0), a parallel view, or a focus nearer than the focal length."""
    if not (fstop > 0) or v.ortho:
        return 0.0
    var f = focal_length(v, sensor)
    if not (Float64(focus) > f):
        return 0.0
    return Float32(f * f / (Float64(fstop) * (Float64(focus) - f)) / Float64(sensor) * Float64(height))


def coc_pixels(v: View, focus: Float32, fstop: Float32, sensor: Float32, height: Float32, z: Float64) -> Float64:
    """The blur disc's diameter in pixels of a point z metres along the view."""
    return Float64(coc_scale(v, focus, fstop, sensor, height)) * abs(1.0 - Float64(focus) / z)


struct DepthOfField(Style):
    comptime NAME: StaticString = "depth_of_field"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
// the largest disc drawn: lens_max_coc, and no more than twice the disc of a point at infinity (reached a third of
// the focus distance from the camera), so the 48 samples are not spread over discs nothing in the frame has
fn coc_max() -> f32 { return min(frame.lens.z, 2.0 * frame.lens.y); }
fn coc_r(z : f32) -> f32 {   // the blur disc's radius in pixels
  return min(frame.lens.y * abs(1.0 - frame.lens.x / max(z, 1e-3)), coc_max()) * 0.5;
}
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let c = src_at(uv);
  if frame.lens.y <= 0.0 { return c; }
  let z0 = view_z(uv);
  let r0 = coc_r(z0);
  let rmax = coc_max() * 0.5;
  var sum = c;
  var wsum = 1.0;
  for (var i = 0; i < 48; i++) {
    let rr = sqrt((f32(i) + 0.5) / 48.0) * rmax;
    let a = f32(i) * 2.39996323;
    let suv = uv + vec2<f32>(cos(a), sin(a)) * rr * frame.res.zw;
    let zs = view_z(suv);
    let rs = coc_r(zs);
    let reach = select(min(rs, r0), rs, zs < z0);
    let w = clamp(reach - rr + 0.5, 0.0, 1.0);
    sum += src_at(suv) * w;
    wsum += w;
  }
  return sum / wsum;
}
"""


struct MotionBlur(Style):
    comptime NAME: StaticString = "motion_blur"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
// where a world point was on the previous frame's screen; behind that camera: where it is now
fn prev_uv(world : vec3<f32>, now : vec2<f32>) -> vec2<f32> {
  let d = world - frame.peye.xyz;
  let x = dot(d, frame.pright.xyz);
  let y = dot(d, frame.pup.xyz);
  let z = dot(d, frame.pfwd.xyz);
  if frame.peye.w < 0.0 { return vec2<f32>(-x * frame.peye.w * 0.5 + 0.5, 0.5 - y * frame.pright.w * 0.5); }
  if z <= 1e-3 { return now; }
  return vec2<f32>(x * frame.peye.w / z * 0.5 + 0.5, 0.5 - y * frame.pright.w / z * 0.5);
}
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  if frame.lens.w <= 0.0 { return src_at(uv); }
  var v = (prev_uv(world_at(uv), uv) - uv) * frame.lens.w;
  let len_px = length(v * frame.res.xy);
  if len_px < 0.5 { return src_at(uv); }
  v *= min(1.0, 96.0 / len_px);   // at most 96 pixels of blur
  var sum = vec3<f32>(0.0);
  for (var i = 0; i < 16; i++) {
    sum += src_at(uv + v * (f32(i) / 15.0));
  }
  return sum / 16.0;
}
"""


struct ObjectMotionBlur(Style):
    """Motion blur of the camera and of the bodies: needs `Aux[VelocityPass]` (app/velocity.mojo) as the pipeline's
    aux target. A pixel a body covers blurs along that body's move on screen; a pixel next to a faster body takes
    that body's velocity when the move reaches it, so the smear leaves the silhouette; elsewhere the camera's motion
    decides, as in MotionBlur."""

    comptime NAME: StaticString = "object_motion_blur"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn prev_uv(world : vec3<f32>, now : vec2<f32>) -> vec2<f32> {
  let d = world - frame.peye.xyz;
  let x = dot(d, frame.pright.xyz);
  let y = dot(d, frame.pup.xyz);
  let z = dot(d, frame.pfwd.xyz);
  if frame.peye.w < 0.0 { return vec2<f32>(-x * frame.peye.w * 0.5 + 0.5, 0.5 - y * frame.pright.w * 0.5); }
  if z <= 1e-3 { return now; }
  return vec2<f32>(x * frame.peye.w / z * 0.5 + 0.5, 0.5 - y * frame.pright.w / z * 0.5);
}
// the move in uv, over the exposure, of what is at uv: the velocity target where a body was drawn, else the camera's
fn move_at(uv : vec2<f32>) -> vec2<f32> {
  let a = aux_at(uv);
  if a.a > 0.5 { return (a.rg * 255.0 - 128.0) / 127.0 * 0.125 * frame.lens.w; }
  return (uv - prev_uv(world_at(uv), uv)) * frame.lens.w;
}
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  if frame.lens.w <= 0.0 { return src_at(uv); }
  var v = move_at(uv);
  var best = length(v * frame.res.xy);
  // a faster neighbour whose move reaches this pixel: 8 directions at 3 distances
  for (var k = 0; k < 24; k++) {
    let a = f32(k % 8) * 0.78539816;
    let r = 6.0 * f32(1 << u32(k / 8));   // 6, 12, 24 pixels
    let n = move_at(uv + vec2<f32>(cos(a), sin(a)) * r * frame.res.zw);
    let len_n = length(n * frame.res.xy);
    if len_n > best && len_n >= r { v = n; best = len_n; }
  }
  if best < 0.5 { return src_at(uv); }
  v *= min(1.0, 96.0 / best);
  var sum = vec3<f32>(0.0);
  for (var i = 0; i < 16; i++) {
    sum += src_at(uv - v * (f32(i) / 15.0 - 0.5));
  }
  return sum / 16.0;
}
"""
