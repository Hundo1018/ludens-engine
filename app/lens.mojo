"""The camera's lens as stages (app/post.mojo): depth of field, the bokeh's shape, motion blur and the anamorphic streak.

    comptime Lens = ThenPost[Stage[MotionBlur], Stage[DepthOfField]]
    var r = SceneRendererOf[MyPasses, Lens](device, format, view)
    r.lens_focus = 8.0      # metres
    r.lens_fstop = 2.0      # 0 (the default) is a pinhole: DepthOfField then returns its input unchanged
    r.shutter = 0.5         # the shutter is open for half the time between two frames; 0 (default): no motion blur

    comptime Cine = ThenPost[Bokeh, AnamorphicStreak]   # shaped bokeh with highlight sprites, then the streak
    r.bokeh_blades = 6      # 0 (default) a round aperture; 3 .. 16 a polygon
    r.bokeh_rotation = 0.0  # radians: a corner at this angle (counter-clockwise from +x on the screen)
    r.bokeh_roundness = 0.2 # 0 straight blades .. 1 a circle
    r.bokeh_squeeze = 1.5   # an anamorphic lens: the discs are 1.5 times taller than wide (1, the default: spherical)
    r.bokeh_gain = 32.0     # Bokeh only: the highlights' sprites (0, the default: none)
    r.streak_intensity = 1.0

Depth of field is the thin lens: a point at distance z, with the lens focused at zf, is drawn as a disc of diameter
    c = f^2 / (N (zf - f)) * |1 - zf / z|
on the sensor, f the focal length and N the f-number. f follows from the view's field of view and the sensor's height
(lens_sensor, 0.024 m by default): f = sensor / 2 / tan(fov / 2). The stage gathers 48 samples over the largest disc
(lens_max_coc pixels across, and at most twice the disc of a point at infinity); a sample counts where its own disc reaches the pixel, and a sample behind the pixel's
surface no further than the pixel's own disc, so a sharp surface is not smeared by the blurred ground behind it.
It is one pass of a gather, not a simulation of the lens.

The aperture's shape: with blades or a squeeze set, the gather takes 64 samples of the same spiral, each pushed out to
the polygon's outline in its direction and narrowed along x by the squeeze. A gather cannot show the shape of a small
highlight (it covers too few samples), so `Bokeh` adds BokehSprites: every 4 x 4 pixel cell brighter than
bokeh_threshold draws one quad as large as its blur disc, cut to the aperture's outline, carrying the light above the
threshold times bokeh_gain spread over the outline's area. The colour the passes hand over is already tone mapped and
at most 1, so a highlight carries little light; bokeh_gain stands in for the range a camera's sensor would have seen.

MotionBlur follows the camera only: each pixel's world point (from depth) is projected with the previous frame's
camera, and the stage averages 16 samples from where the point is to where it was, scaled by the shutter. A body that
moves while the camera stands still is not blurred by it. ObjectMotionBlur also blurs bodies that move, from the
velocity target of app/velocity.mojo.

AnamorphicStreak is the horizontal line an anamorphic lens draws through a bright light (the cylinder elements spread
it sideways): the light above streak_threshold, blurred along x only, tinted streak_tint and added.
"""
from game.camera_view import View
from wgpu.device import Device
from wgpu.command import CommandEncoder
from wgpu import WGPUTextureFormat, WGPUTextureUsage
from wgpu.texture import Texture, TextureView
from app.gpu_bytes import texture_bytes
from app.post import PostEffect, PostInputs, Stage, Scaled, Style, _target, _target_bytes
from app.strokes import StrokeKind, Strokes
from app.gpu_blend import BLEND_ADD


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
// the focus distance from the camera), so the samples are not spread over discs nothing in the frame has
fn coc_max() -> f32 { return min(frame.lens.z, 2.0 * frame.lens.y); }
fn coc_r(z : f32) -> f32 {   // the blur disc's radius in pixels
  return min(frame.lens.y * abs(1.0 - frame.lens.x / max(z, 1e-3)), coc_max()) * 0.5;
}
// The aperture's outline (APERTURE_WGSL below, repeated here: a Style's WGSL is one literal) at angle a, counted
// counter-clockwise on the screen from +x with y up, as a share of its circumscribed circle: 1 for a round aperture,
// else a regular polygon of `blades` sides with a corner at angle `rotation`, bent toward the circle by `roundness`.
fn aperture_r(a : f32) -> f32 {
  let n = floor(frame.bokeh.x);
  if n < 3.0 { return 1.0; }
  let seg = TAU / n;
  let t = a - frame.bokeh.y;
  let k = t - floor(t / seg) * seg - 0.5 * seg;
  return mix(cos(0.5 * seg) / cos(k), 1.0, clamp(frame.bokeh.z, 0.0, 1.0));
}
fn shaped() -> bool { return frame.bokeh.x >= 3.0 || frame.bokeh.w != 1.0; }
// the round aperture of the first form: 48 samples on a disc, the same frame as before the shapes existed
fn dof_round(uv : vec2<f32>, c : vec3<f32>, z0 : f32, r0 : f32, rmax : f32) -> vec3<f32> {
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
// A shaped aperture: 64 samples of the same spiral, each moved out to rho * aperture_r of the disc in its direction.
// A point is spread over the pixels p = point - offset, so a sample at uv direction a (y down) lands on the bokeh at
// screen angle -(a + pi) (y up): the outline is looked up there, and the bokeh has the aperture's orientation. The
// anamorphic squeeze narrows every offset along x; the reach test is in the aperture's own units, as before.
fn dof_shaped(uv : vec2<f32>, c : vec3<f32>, z0 : f32, r0 : f32, rmax : f32) -> vec3<f32> {
  let sq = max(frame.bokeh.w, 1e-3);
  var sum = c;
  var wsum = 1.0;
  for (var i = 0; i < 64; i++) {
    let rr = sqrt((f32(i) + 0.5) / 64.0) * rmax;
    let a = f32(i) * 2.39996323;
    let off = vec2<f32>(cos(a), sin(a)) * rr * aperture_r(-(a + 3.14159265));
    let suv = uv + vec2<f32>(off.x / sq, off.y) * frame.res.zw;
    let zs = view_z(suv);
    let rs = coc_r(zs);
    let reach = select(min(rs, r0), rs, zs < z0);
    let w = clamp(reach - rr + 0.5, 0.0, 1.0);
    sum += src_at(suv) * w;
    wsum += w;
  }
  return sum / wsum;
}
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let c = src_at(uv);
  if frame.lens.y <= 0.0 { return c; }
  let z0 = view_z(uv);
  let r0 = coc_r(z0);
  let rmax = coc_max() * 0.5;
  if shaped() { return dof_shaped(uv, c, z0, r0, rmax); }
  return dof_round(uv, c, z0, r0, rmax);
}
"""


struct BokehSprites(StrokeKind):
    """The highlights' bokeh, scattered: one quad per 2 x 2 cell of a half-size grid; a cell brighter than
    bokeh_threshold draws the aperture's outline, as large as its blur disc, carrying the light above the threshold
    times bokeh_gain, spread over the outline's area (so a larger disc is dimmer, as the light of one point is). The
    quads add up on a black canvas. A gather cannot draw this: a small highlight covers too few of its samples."""

    comptime NAME: StaticString = "bokeh_sprites"
    comptime WHAT: StaticString = "aperture-shaped sprites of the highlights"
    comptime AFTER: StaticString = ""
    comptime CELL: Int = 2
    comptime BLEND: Int = BLEND_ADD
    comptime CANVAS_R: Float64 = 0.0
    comptime CANVAS_G: Float64 = 0.0
    comptime CANVAS_B: Float64 = 0.0
    comptime WGSL: StaticString = """
fn coc_max() -> f32 { return min(frame.lens.z, 2.0 * frame.lens.y); }
fn coc_r(z : f32) -> f32 { return min(frame.lens.y * abs(1.0 - frame.lens.x / max(z, 1e-3)), coc_max()) * 0.5; }
fn aperture_r(a : f32) -> f32 {   // as in DepthOfField
  let n = floor(frame.bokeh.x);
  if n < 3.0 { return 1.0; }
  let seg = TAU / n;
  let t = a - frame.bokeh.y;
  let k = t - floor(t / seg) * seg - 0.5 * seg;
  return mix(cos(0.5 * seg) / cos(k), 1.0, clamp(frame.bokeh.z, 0.0, 1.0));
}
// the outline's area as a share of its circle's: the mean of aperture_r^2 over 32 directions
fn aperture_area() -> f32 {
  var s = 0.0;
  for (var i = 0; i < 32; i++) { let r = aperture_r(f32(i) * TAU / 32.0); s += r * r; }
  return s / 32.0;
}
fn place(cell : vec2<f32>, layer : u32) -> Stroke {
  let centre = (cell + 0.5) * STROKE_CELL;          // pixels of this half-size target
  let none = Stroke(centre, vec2<f32>(0.0), 0.0, vec4<f32>(0.0), 0.0);
  if frame.bokeh2.x <= 0.0 || frame.lens.y <= 0.0 { return none; }
  let uv = centre * frame.res.zw;
  let e = 0.5 * frame.res.zw;
  // the cell is 4 x 4 pixels of the source: four bilinear reads at the centres of its 2 x 2 quarters
  let c = 0.25 * (src_at(uv + vec2<f32>(-e.x, -e.y)) + src_at(uv + vec2<f32>(e.x, -e.y))
                + src_at(uv + vec2<f32>(-e.x, e.y)) + src_at(uv + vec2<f32>(e.x, e.y)));
  let l = max(c.r, max(c.g, c.b));
  let t = frame.bokeh2.y;
  if l <= t { return none; }
  let r = coc_r(view_z(uv)) * 0.5;                   // the blur disc's radius in this target's pixels
  if r < 1.5 { return none; }
  let sq = max(frame.bokeh.w, 1e-3);
  let area = 3.14159265 * r * r * aperture_area() / sq;
  let light = c * ((l - t) / l) * frame.bokeh2.x * STROKE_CELL * STROKE_CELL / area;
  return Stroke(centre, vec2<f32>(r / sq + 1.0, r + 1.0), 0.0, vec4<f32>(light, 1.0), r);
}
// q is -1 .. 1 across the quad, y down; seed carries the disc's radius in pixels
fn shape(q : vec2<f32>, color : vec4<f32>, seed : f32) -> vec4<f32> {
  let r = seed;
  let sq = max(frame.bokeh.w, 1e-3);
  let off = q * vec2<f32>(r / sq + 1.0, r + 1.0);    // pixels from the centre
  let a = vec2<f32>(off.x * sq, -off.y);              // the aperture's units, y up
  let edge = aperture_r(atan2(a.y, a.x)) * r;
  let cover = clamp(edge - length(a) + 0.5, 0.0, 1.0);
  return vec4<f32>(color.rgb * cover, cover);
}
"""


struct BokehMix(Style):
    comptime NAME: StaticString = "bokeh"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
// src: the gathered depth of field; src2: the highlights' sprites, half the size
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  return min(src_texel(uv) + src2_at(uv), vec3<f32>(1.0));
}
"""


struct Bokeh(PostEffect):
    """Depth of field with the highlights drawn as sprites of the aperture's shape: DepthOfField gathers the blur into
    a target of the frame's size, BokehSprites scatters the points brighter than `bokeh_threshold` (with `bokeh_gain`
    above 0) into a half-size RGBA16Float target (thousands of faint sprites add up there; in 8 bits each addition
    would round), and BokehMix adds the two. With the gain at 0 the sprites draw nothing and the frame is
    DepthOfField's."""

    comptime NAME: StaticString = "bokeh"
    comptime AFTER: StaticString = ""
    comptime STAGES: Int = 3
    comptime ON: Bool = True

    @staticmethod
    def sig() -> String:
        return "(depth_of_field | Strokes[aperture-shaped sprites of the highlights] / 2) > bokeh"

    var dof: Stage[DepthOfField]
    var sprites: Scaled[Strokes[BokehSprites], 2]
    var mix: Stage[BokehMix]
    var ta: Optional[Texture]
    var tb: Optional[Texture]
    var va: Optional[TextureView]
    var vb: Optional[TextureView]
    var target_size: Int

    def __init__(out self, var dof: Stage[DepthOfField], var sprites: Scaled[Strokes[BokehSprites], 2], var mix: Stage[BokehMix]):
        self.dof = dof^
        self.sprites = sprites^
        self.mix = mix^
        self.ta = None
        self.tb = None
        self.va = None
        self.vb = None
        self.target_size = 0

    def target_bytes(self) raises -> Int:
        return self.target_size

    @staticmethod
    def create(device: Device, color_format: UInt32) raises -> Self:
        return Self(
            Stage[DepthOfField].create(device, color_format),
            Scaled[Strokes[BokehSprites], 2].create(device, WGPUTextureFormat.RGBA16Float),
            Stage[BokehMix].create(device, color_format),
        )

    def bind(mut self, device: Device, color_format: UInt32, width: UInt32, height: UInt32, inp: PostInputs) raises:
        self.va = None
        self.vb = None
        self.ta = _target(device, color_format, width, height, 1, 0, 0)
        var hw = max(width // 2, 1)
        var hh = max(height // 2, 1)
        self.tb = device.create_texture(
            hw, hh, 1, WGPUTextureFormat.RGBA16Float, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING,
            label="bokeh_sprites",
        )
        self.target_size = _target_bytes(color_format, width, height, 1, 0, 0) + texture_bytes(Int(hw), Int(hh), 1, 1, WGPUTextureFormat.RGBA16Float)
        self.va = self.ta.value().create_view_default()
        self.vb = self.tb.value().create_view_default()
        self.dof.bind(device, color_format, width, height, inp)
        self.sprites.bind(device, color_format, width, height, inp)
        self.mix.bind(device, color_format, width, height, inp.with_src2(self.va.value(), self.vb.value()))

    def update(self, device: Device, frame: List[Float32]) raises:
        self.dof.update(device, frame)
        self.sprites.update(device, frame)
        self.mix.update(device, frame)

    def record(self, enc: CommandEncoder, var dst: TextureView):
        self.dof.record(enc, self.va.value().clone())
        self.sprites.record(enc, self.vb.value().clone())
        self.mix.record(enc, dst^)


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


struct Exposure(Style):
    """The photo mode's exposure (game/photo_camera.mojo): the colour times 2^EV, EV from `SceneRendererOf.exposure_ev`
    (Frame.t.w), clamped to the displayable range. EV 0 gives the input back."""

    comptime NAME: StaticString = "exposure"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let c = src_texel(uv);
  if frame.t.w == 0.0 { return c; }
  return clamp(c * exp2(frame.t.w), vec3<f32>(0.0), vec3<f32>(1.0));
}
"""


# ---------------------------------------------------------------------------------------------------------------------
# The anamorphic lens's horizontal streak


struct StreakPre(Style):
    comptime NAME: StaticString = "streak_prefilter"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
// the part of a colour above the streak's threshold (a soft knee of 0.1), each half-size pixel the mean of the 2 x 2
// source pixels under it
fn streak_cut(c : vec3<f32>) -> vec3<f32> {
  let t = frame.streak.y;
  let knee = 0.1;
  let l = max(c.r, max(c.g, c.b));
  var soft = clamp(l - t + knee, 0.0, 2.0 * knee);
  soft = soft * soft / (4.0 * knee);
  return c * max(soft, l - t) / max(l, 1e-4);
}
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let t = 0.5 / src_size();
  return 0.25 * (streak_cut(src_texel(uv + vec2<f32>(-t.x, -t.y))) + streak_cut(src_texel(uv + vec2<f32>(t.x, -t.y)))
               + streak_cut(src_texel(uv + vec2<f32>(-t.x, t.y))) + streak_cut(src_texel(uv + vec2<f32>(t.x, t.y))));
}
"""


struct StreakBlur1(Style):
    comptime NAME: StaticString = "streak_blur_1"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
// 9 taps along x, 1 of this target's pixels times the streak's length apart, weighted exp(-0.35 |i|), normalised
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let d = vec2<f32>(1.0 * max(frame.streak.z, 0.0) / src_size().x, 0.0);
  var sum = vec3<f32>(0.0);
  var wsum = 0.0;
  for (var i = -4; i <= 4; i++) {
    let w = exp(-0.35 * abs(f32(i)));
    sum += src_at(uv + d * f32(i)) * w;
    wsum += w;
  }
  return sum / wsum;
}
"""


struct StreakBlur3(Style):
    comptime NAME: StaticString = "streak_blur_3"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
// 9 taps along x, 3 of this target's pixels times the streak's length apart, weighted exp(-0.35 |i|), normalised
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let d = vec2<f32>(3.0 * max(frame.streak.z, 0.0) / src_size().x, 0.0);
  var sum = vec3<f32>(0.0);
  var wsum = 0.0;
  for (var i = -4; i <= 4; i++) {
    let w = exp(-0.35 * abs(f32(i)));
    sum += src_at(uv + d * f32(i)) * w;
    wsum += w;
  }
  return sum / wsum;
}
"""


struct StreakBlur9(Style):
    comptime NAME: StaticString = "streak_blur_9"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
// 9 taps along x, 9 of this target's pixels times the streak's length apart, weighted exp(-0.35 |i|), normalised
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let d = vec2<f32>(9.0 * max(frame.streak.z, 0.0) / src_size().x, 0.0);
  var sum = vec3<f32>(0.0);
  var wsum = 0.0;
  for (var i = -4; i <= 4; i++) {
    let w = exp(-0.35 * abs(f32(i)));
    sum += src_at(uv + d * f32(i)) * w;
    wsum += w;
  }
  return sum / wsum;
}
"""


struct StreakBlur27(Style):
    comptime NAME: StaticString = "streak_blur_27"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
// 9 taps along x, 27 of this target's pixels times the streak's length apart, weighted exp(-0.35 |i|), normalised
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let d = vec2<f32>(27.0 * max(frame.streak.z, 0.0) / src_size().x, 0.0);
  var sum = vec3<f32>(0.0);
  var wsum = 0.0;
  for (var i = -4; i <= 4; i++) {
    let w = exp(-0.35 * abs(f32(i)));
    sum += src_at(uv + d * f32(i)) * w;
    wsum += w;
  }
  return sum / wsum;
}
"""


struct StreakMix(Style):
    comptime NAME: StaticString = "anamorphic_streak"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let c = src_texel(uv);
  if frame.streak.x <= 0.0 { return c; }
  return min(c + src2_at(uv) * frame.stint.rgb * frame.streak.x, vec3<f32>(1.0));
}
"""


struct StreakSum(Style):
    comptime NAME: StaticString = "streak_sum"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
// the second blur (src, a short core) and the fourth (src2, the long tail), both RGBA16Float and normalised:
// the core carries the source's light above the threshold once, the tail 24 times (the streak is a look, not an
// energy balance: spread over a third of the frame, the tail would otherwise be a few levels at most)
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  return src_at(uv) + src2_at(uv) * 24.0;
}
"""


struct AnamorphicStreak(PostEffect):
    """The horizontal streak an anamorphic lens draws through a bright light: the source's highlights above
    `streak_threshold`, at half the frame's size, blurred along x only by four passes of 9 taps each (1, 3, 9 and 27
    pixels of that target apart, times `streak_length`), the second and the fourth output mixed (StreakSum), then
    added to the frame in `streak_tint` times `streak_intensity`. Six RGBA16Float targets of half the size (in 8 bits
    the long tail, a few thousandths of the source per pixel, would round to 0); with the intensity at 0 the frame is
    returned unchanged."""

    comptime NAME: StaticString = "anamorphic_streak"
    comptime AFTER: StaticString = ""
    comptime STAGES: Int = 7
    comptime ON: Bool = True

    @staticmethod
    def sig() -> String:
        return "anamorphic_streak"

    var pre: Scaled[Stage[StreakPre], 2]
    var b1: Scaled[Stage[StreakBlur1], 2]
    var b3: Scaled[Stage[StreakBlur3], 2]
    var b9: Scaled[Stage[StreakBlur9], 2]
    var b27: Scaled[Stage[StreakBlur27], 2]
    var sum: Scaled[Stage[StreakSum], 2]
    var mix: Stage[StreakMix]
    var targets: List[Texture]  # pre, b1, b3, b9, b27, sum
    var views: List[TextureView]
    var target_size: Int

    def __init__(
        out self, var pre: Scaled[Stage[StreakPre], 2], var b1: Scaled[Stage[StreakBlur1], 2],
        var b3: Scaled[Stage[StreakBlur3], 2], var b9: Scaled[Stage[StreakBlur9], 2], var b27: Scaled[Stage[StreakBlur27], 2],
        var sum: Scaled[Stage[StreakSum], 2], var mix: Stage[StreakMix],
    ):
        self.pre = pre^
        self.b1 = b1^
        self.b3 = b3^
        self.b9 = b9^
        self.b27 = b27^
        self.sum = sum^
        self.mix = mix^
        self.targets = List[Texture]()
        self.views = List[TextureView]()
        self.target_size = 0

    def target_bytes(self) raises -> Int:
        return self.target_size

    @staticmethod
    def create(device: Device, color_format: UInt32) raises -> Self:
        comptime F = WGPUTextureFormat.RGBA16Float  # the inner stages draw into half-float targets
        return Self(
            Scaled[Stage[StreakPre], 2].create(device, F),
            Scaled[Stage[StreakBlur1], 2].create(device, F),
            Scaled[Stage[StreakBlur3], 2].create(device, F),
            Scaled[Stage[StreakBlur9], 2].create(device, F),
            Scaled[Stage[StreakBlur27], 2].create(device, F),
            Scaled[Stage[StreakSum], 2].create(device, F),
            Stage[StreakMix].create(device, color_format),
        )

    def bind(mut self, device: Device, color_format: UInt32, width: UInt32, height: UInt32, inp: PostInputs) raises:
        self.views.clear()
        self.targets.clear()
        self.target_size = 0
        var w = max(width // 2, 1)
        var h = max(height // 2, 1)
        for _ in range(6):
            self.target_size += texture_bytes(Int(w), Int(h), 1, 1, WGPUTextureFormat.RGBA16Float)
            self.targets.append(device.create_texture(
                w, h, 1, WGPUTextureFormat.RGBA16Float, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.TEXTURE_BINDING,
                label="streak_target",
            ))
            self.views.append(self.targets[len(self.targets) - 1].create_view_default())
        self.pre.bind(device, color_format, width, height, inp)
        self.b1.bind(device, color_format, width, height, inp.with_src(self.views[0].clone()))
        self.b3.bind(device, color_format, width, height, inp.with_src(self.views[1].clone()))
        self.b9.bind(device, color_format, width, height, inp.with_src(self.views[2].clone()))
        self.b27.bind(device, color_format, width, height, inp.with_src(self.views[3].clone()))
        self.sum.bind(device, color_format, width, height, inp.with_src2(self.views[2].clone(), self.views[4].clone()))
        self.mix.bind(device, color_format, width, height, inp.with_src2(inp.src.clone(), self.views[5].clone()))

    def update(self, device: Device, frame: List[Float32]) raises:
        self.pre.update(device, frame)
        self.b1.update(device, frame)
        self.b3.update(device, frame)
        self.b9.update(device, frame)
        self.b27.update(device, frame)
        self.sum.update(device, frame)
        self.mix.update(device, frame)

    def record(self, enc: CommandEncoder, var dst: TextureView):
        self.pre.record(enc, self.views[0].clone())
        self.b1.record(enc, self.views[1].clone())
        self.b3.record(enc, self.views[2].clone())
        self.b9.record(enc, self.views[3].clone())
        self.b27.record(enc, self.views[4].clone())
        self.sum.record(enc, self.views[5].clone())
        self.mix.record(enc, dst^)
