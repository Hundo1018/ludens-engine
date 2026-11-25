"""Anti-aliasing, bloom and colour grading as stages of the post graph (app/post.mojo).

    comptime Look = ThenPost[Fxaa, ThenPost[Bloom, Grade]]
    var r = SceneRendererOf[DefaultPasses, Look](device, format, view)
    r.fxaa_strength = 1.0        # Fxaa: 0 returns the input unchanged
    r.bloom_threshold = 0.8      # Bloom: brightness above which a pixel feeds the glow (0 .. 1, of the finished colour)
    r.bloom_intensity = 0.6      # Bloom: the share of the blurred highlights added back; 0 returns the input unchanged
    r.set_lut(device, 16, neutral_lut(16))
    r.lut_amount = 1.0           # Grade: 0 returns the input unchanged, 1 the full grade

The passes' colour is already tone mapped (ACES, app/render_res.mojo, when the atmosphere is on the linear workflow), so
the stages work on display colour in 0 .. 1 and Grade runs after tone mapping.

Fxaa     one pass. Edge detection on luma from the four neighbours and four corners, the edge's direction from
         their second derivatives, a search along the edge for its two ends (12 steps each way), then the pixel is
         read from the point half way between it and its neighbour, shifted by how far along the edge it lies;
         low-contrast pixels (range below 1/8 of the local maximum, and below 0.0312) are returned unchanged.
Bloom    a mip chain, nine passes and one composite: the source is thresholded (a soft knee of 0.1) and halved (a 4 x 4 box), then
         halved four more times (a 13-tap filter each), then summed back up (each level 1/2 of itself and 1/2 of
         the coarser sum, tent filtered). The weights of the five levels are 1/2, 1/4, 1/8, 1/16, 1/16: they add up to
         1, so `bloom_intensity` is the share of the thresholded energy added back, whatever the number of levels.
Grade    a 3D lookup table stored as a strip (`SceneRendererOf.set_lut`): `size` squares side by side, texel
         (b * size + r, g). Eight texels are read and interpolated in the shader. A LUT of size 16 holding
         `neutral_lut(16)` returns every 8-bit input unchanged, because 255 / 15 = 17 is a whole number: the table's
         entries are exact and the interpolation between them lands on the input. (Sizes where 255 / (size - 1) is not
         a whole number, such as 17 or 32, round the entries and are off by one level in places.)

MSAA is not a stage: it is `RenderCaps.samples` (app/render_res.mojo), see app/msaa.mojo.
"""
from std.math import floor
from wgpu.device import Device
from wgpu.command import CommandEncoder
from wgpu.texture import Texture, TextureView
from app.post import (
    PostEffect, PostInputs, Stage, Scaled, Style, _target, _target_bytes,
)

# ---------------------------------------------------------------------------------------------------------------------
# FXAA


struct FxaaStyle(Style):
    comptime NAME: StaticString = "fxaa"
    comptime AFTER: StaticString = "FXAA 3.11 (T. Lottes), written from its description"
    comptime WGSL: StaticString = """
fn fx_luma(uv : vec2<f32>) -> f32 { return luma(src_at(uv)); }
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let c = src_at(uv);
  let strength = frame.fx.w;
  if strength <= 0.0 { return c; }
  let o = frame.res.zw;
  let lM = luma(c);
  let lN = fx_luma(uv + vec2<f32>(0.0, -o.y));
  let lS = fx_luma(uv + vec2<f32>(0.0, o.y));
  let lW = fx_luma(uv + vec2<f32>(-o.x, 0.0));
  let lE = fx_luma(uv + vec2<f32>(o.x, 0.0));
  let lmin = min(lM, min(min(lN, lS), min(lW, lE)));
  let lmax = max(lM, max(max(lN, lS), max(lW, lE)));
  let range = lmax - lmin;
  if range < max(0.0312, lmax * 0.125) { return c; }
  let lNW = fx_luma(uv + vec2<f32>(-o.x, -o.y));
  let lNE = fx_luma(uv + vec2<f32>(o.x, -o.y));
  let lSW = fx_luma(uv + vec2<f32>(-o.x, o.y));
  let lSE = fx_luma(uv + vec2<f32>(o.x, o.y));
  // how much of the pixel is a lone bright or dark point: blend toward the neighbourhood by this much at least
  let lAvg = (2.0 * (lN + lS + lW + lE) + lNW + lNE + lSW + lSE) / 12.0;
  var sub = clamp(abs(lAvg - lM) / range, 0.0, 1.0);
  sub = smoothstep(0.0, 1.0, sub);
  sub = sub * sub * 0.75;
  // the edge runs along x (horizontal) when the vertical second derivative is the larger
  let eH = abs(-2.0 * lW + lNW + lSW) + abs(-2.0 * lM + lN + lS) * 2.0 + abs(-2.0 * lE + lNE + lSE);
  let eV = abs(-2.0 * lN + lNW + lNE) + abs(-2.0 * lM + lW + lE) * 2.0 + abs(-2.0 * lS + lSW + lSE);
  let horiz = eH >= eV;
  let l1 = select(lW, lN, horiz);
  let l2 = select(lE, lS, horiz);
  let g1 = l1 - lM;
  let g2 = l2 - lM;
  let side1 = abs(g1) >= abs(g2);
  let grad = 0.25 * max(abs(g1), abs(g2));
  var step_len = select(o.x, o.y, horiz);
  var avg = 0.5 * (l2 + lM);
  if side1 {
    step_len = -step_len;
    avg = 0.5 * (l1 + lM);
  }
  var edge_uv = uv;
  if horiz { edge_uv.y += step_len * 0.5; } else { edge_uv.x += step_len * 0.5; }
  let along = select(vec2<f32>(0.0, o.y), vec2<f32>(o.x, 0.0), horiz);
  var uv1 = edge_uv - along;
  var uv2 = edge_uv + along;
  var e1 = fx_luma(uv1) - avg;
  var e2 = fx_luma(uv2) - avg;
  var done1 = abs(e1) >= grad;
  var done2 = abs(e2) >= grad;
  for (var i = 0; i < 12; i++) {
    if done1 && done2 { break; }
    if !done1 { uv1 -= along; e1 = fx_luma(uv1) - avg; done1 = abs(e1) >= grad; }
    if !done2 { uv2 += along; e2 = fx_luma(uv2) - avg; done2 = abs(e2) >= grad; }
  }
  let d1 = select(uv.y - uv1.y, uv.x - uv1.x, horiz);
  let d2 = select(uv2.y - uv.y, uv2.x - uv.x, horiz);
  let near1 = d1 < d2;
  let dist = min(d1, d2);
  let span = d1 + d2;
  // the end nearer to the pixel must be on the far side of the edge from the pixel's own luma, or the pixel is
  // already on the right side of it and the edge moves it nowhere
  let mid_below = lM < avg;
  let end_below = select(e2 < 0.0, e1 < 0.0, near1);
  var shift = 0.0;
  if end_below != mid_below { shift = 0.5 - dist / span; }
  shift = max(shift, sub);
  var out_uv = uv;
  if horiz { out_uv.y += shift * step_len; } else { out_uv.x += shift * step_len; }
  return mix(c, src_at(out_uv), strength);
}
"""


comptime Fxaa = Stage[FxaaStyle]

# ---------------------------------------------------------------------------------------------------------------------
# Bloom


struct BloomPre(Style):
    comptime NAME: StaticString = "bloom_prefilter"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
// the part of a colour above the threshold: a soft knee of 0.1 below it, then linear in the brightest channel
fn bloom_cut(c : vec3<f32>) -> vec3<f32> {
  let t = frame.fx.x;
  let knee = 0.1;
  let l = max(c.r, max(c.g, c.b));
  var soft = clamp(l - t + knee, 0.0, 2.0 * knee);
  soft = soft * soft / (4.0 * knee);
  let w = max(soft, l - t) / max(l, 1e-4);
  return c * w;
}
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  // the half-size target: each of its pixels is the mean of the 4 x 4 source pixels around it, each cut at the
  // threshold first (a single bright pixel keeps its share)
  let t = 1.0 / src_size();
  var sum = vec3<f32>(0.0);
  for (var j = 0; j < 4; j++) {
    for (var i = 0; i < 4; i++) {
      let d = vec2<f32>(f32(i) - 1.5, f32(j) - 1.5) * t;
      sum += bloom_cut(src_texel(uv + d));
    }
  }
  return sum / 16.0;
}
"""


struct BloomDown(Style):
    comptime NAME: StaticString = "bloom_down"
    comptime AFTER: StaticString = "13-tap downsample (Call of Duty: Advanced Warfare, SIGGRAPH 2014)"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let t = 1.0 / src_size();
  let e = src_at(uv);
  let a = src_at(uv + vec2<f32>(-2.0, 2.0) * t);
  let b = src_at(uv + vec2<f32>(0.0, 2.0) * t);
  let c = src_at(uv + vec2<f32>(2.0, 2.0) * t);
  let d = src_at(uv + vec2<f32>(-2.0, 0.0) * t);
  let f = src_at(uv + vec2<f32>(2.0, 0.0) * t);
  let g = src_at(uv + vec2<f32>(-2.0, -2.0) * t);
  let h = src_at(uv + vec2<f32>(0.0, -2.0) * t);
  let i = src_at(uv + vec2<f32>(2.0, -2.0) * t);
  let j = src_at(uv + vec2<f32>(-1.0, 1.0) * t);
  let k = src_at(uv + vec2<f32>(1.0, 1.0) * t);
  let l = src_at(uv + vec2<f32>(-1.0, -1.0) * t);
  let m = src_at(uv + vec2<f32>(1.0, -1.0) * t);
  return e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
}
"""


struct BloomUp(Style):
    comptime NAME: StaticString = "bloom_up"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
// src: this level's own pixels; src2: the sum of the coarser levels, half the size, read through a 3 x 3 tent
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let t = 1.0 / vec2<f32>(textureDimensions(src2));
  var s = src2_at(uv) * 4.0;
  s += (src2_at(uv + vec2<f32>(-t.x, 0.0)) + src2_at(uv + vec2<f32>(t.x, 0.0))
      + src2_at(uv + vec2<f32>(0.0, -t.y)) + src2_at(uv + vec2<f32>(0.0, t.y))) * 2.0;
  s += src2_at(uv + vec2<f32>(-t.x, -t.y)) + src2_at(uv + vec2<f32>(t.x, -t.y))
     + src2_at(uv + vec2<f32>(-t.x, t.y)) + src2_at(uv + vec2<f32>(t.x, t.y));
  return 0.5 * src_at(uv) + 0.5 * (s / 16.0);
}
"""


struct BloomMix(Style):
    comptime NAME: StaticString = "bloom"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  return min(src_texel(uv) + src2_at(uv) * frame.fx.y, vec3<f32>(1.0));
}
"""


struct Bloom(PostEffect):
    """The bloom of the file's header: ten stages and nine small targets, from the frame's size down to 1 / 32 of it."""

    comptime NAME: StaticString = "bloom"
    comptime AFTER: StaticString = ""
    comptime STAGES: Int = 10
    comptime ON: Bool = True

    @staticmethod
    def sig() -> String:
        return "bloom"
    var pre: Scaled[Stage[BloomPre], 2]
    var down2: Scaled[Stage[BloomDown], 4]
    var down3: Scaled[Stage[BloomDown], 8]
    var down4: Scaled[Stage[BloomDown], 16]
    var down5: Scaled[Stage[BloomDown], 32]
    var up4: Scaled[Stage[BloomUp], 16]
    var up3: Scaled[Stage[BloomUp], 8]
    var up2: Scaled[Stage[BloomUp], 4]
    var up1: Scaled[Stage[BloomUp], 2]
    var mix: Stage[BloomMix]
    var targets: List[Texture]  # level 1 .. 5, then the sums at level 4, 3, 2, 1
    var views: List[TextureView]
    var target_size: Int  # bytes of `targets`

    def __init__(
        out self,
        var pre: Scaled[Stage[BloomPre], 2], var down2: Scaled[Stage[BloomDown], 4],
        var down3: Scaled[Stage[BloomDown], 8], var down4: Scaled[Stage[BloomDown], 16],
        var down5: Scaled[Stage[BloomDown], 32], var up4: Scaled[Stage[BloomUp], 16],
        var up3: Scaled[Stage[BloomUp], 8], var up2: Scaled[Stage[BloomUp], 4], var up1: Scaled[Stage[BloomUp], 2],
        var mix: Stage[BloomMix],
    ):
        self.pre = pre^
        self.down2 = down2^
        self.down3 = down3^
        self.down4 = down4^
        self.down5 = down5^
        self.up4 = up4^
        self.up3 = up3^
        self.up2 = up2^
        self.up1 = up1^
        self.mix = mix^
        self.targets = List[Texture]()
        self.views = List[TextureView]()
        self.target_size = 0

    def target_bytes(self) raises -> Int:
        return self.target_size

    @staticmethod
    def create(device: Device, color_format: UInt32) raises -> Self:
        return Self(
            Scaled[Stage[BloomPre], 2].create(device, color_format),
            Scaled[Stage[BloomDown], 4].create(device, color_format),
            Scaled[Stage[BloomDown], 8].create(device, color_format),
            Scaled[Stage[BloomDown], 16].create(device, color_format),
            Scaled[Stage[BloomDown], 32].create(device, color_format),
            Scaled[Stage[BloomUp], 16].create(device, color_format),
            Scaled[Stage[BloomUp], 8].create(device, color_format),
            Scaled[Stage[BloomUp], 4].create(device, color_format),
            Scaled[Stage[BloomUp], 2].create(device, color_format),
            Stage[BloomMix].create(device, color_format),
        )

    def bind(mut self, device: Device, color_format: UInt32, width: UInt32, height: UInt32, inp: PostInputs) raises:
        self.views.clear()
        self.targets.clear()
        self.target_size = 0
        for d in [2, 4, 8, 16, 32, 16, 8, 4, 2]:
            self.target_size += _target_bytes(color_format, width, height, d, 0, 0)
            self.targets.append(_target(device, color_format, width, height, d, 0, 0))
            self.views.append(self.targets[len(self.targets) - 1].create_view_default())
        self.pre.bind(device, color_format, width, height, inp)
        self.down2.bind(device, color_format, width, height, inp.with_src(self.views[0].clone()))
        self.down3.bind(device, color_format, width, height, inp.with_src(self.views[1].clone()))
        self.down4.bind(device, color_format, width, height, inp.with_src(self.views[2].clone()))
        self.down5.bind(device, color_format, width, height, inp.with_src(self.views[3].clone()))
        self.up4.bind(device, color_format, width, height, inp.with_src2(self.views[3].clone(), self.views[4].clone()))
        self.up3.bind(device, color_format, width, height, inp.with_src2(self.views[2].clone(), self.views[5].clone()))
        self.up2.bind(device, color_format, width, height, inp.with_src2(self.views[1].clone(), self.views[6].clone()))
        self.up1.bind(device, color_format, width, height, inp.with_src2(self.views[0].clone(), self.views[7].clone()))
        self.mix.bind(device, color_format, width, height, inp.with_src2(inp.src.clone(), self.views[8].clone()))

    def update(self, device: Device, frame: List[Float32]) raises:
        self.pre.update(device, frame)
        self.down2.update(device, frame)
        self.down3.update(device, frame)
        self.down4.update(device, frame)
        self.down5.update(device, frame)
        self.up4.update(device, frame)
        self.up3.update(device, frame)
        self.up2.update(device, frame)
        self.up1.update(device, frame)
        self.mix.update(device, frame)

    def record(self, enc: CommandEncoder, var dst: TextureView):
        self.pre.record(enc, self.views[0].clone())
        self.down2.record(enc, self.views[1].clone())
        self.down3.record(enc, self.views[2].clone())
        self.down4.record(enc, self.views[3].clone())
        self.down5.record(enc, self.views[4].clone())
        self.up4.record(enc, self.views[5].clone())
        self.up3.record(enc, self.views[6].clone())
        self.up2.record(enc, self.views[7].clone())
        self.up1.record(enc, self.views[8].clone())
        self.mix.record(enc, dst^)


# ---------------------------------------------------------------------------------------------------------------------
# Colour grading


struct LutStyle(Style):
    comptime NAME: StaticString = "grade"
    comptime AFTER: StaticString = ""
    comptime WGSL: StaticString = """
fn lut_texel(n : i32, r : i32, g : i32, b : i32) -> vec3<f32> {
  return textureLoad(lutt, vec2<i32>(b * n + r, g), 0).rgb;
}
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let c = clamp(src_texel(uv), vec3<f32>(0.0), vec3<f32>(1.0));
  let n = i32(textureDimensions(lutt).y);
  if frame.fx.z <= 0.0 || n < 2 { return c; }
  let t = c * f32(n - 1);
  let lo = min(vec3<i32>(floor(t)), vec3<i32>(n - 2));
  let f = t - vec3<f32>(lo);
  let c000 = lut_texel(n, lo.x, lo.y, lo.z);
  let c100 = lut_texel(n, lo.x + 1, lo.y, lo.z);
  let c010 = lut_texel(n, lo.x, lo.y + 1, lo.z);
  let c110 = lut_texel(n, lo.x + 1, lo.y + 1, lo.z);
  let c001 = lut_texel(n, lo.x, lo.y, lo.z + 1);
  let c101 = lut_texel(n, lo.x + 1, lo.y, lo.z + 1);
  let c011 = lut_texel(n, lo.x, lo.y + 1, lo.z + 1);
  let c111 = lut_texel(n, lo.x + 1, lo.y + 1, lo.z + 1);
  let graded = mix(mix(mix(c000, c100, f.x), mix(c010, c110, f.x), f.y), mix(mix(c001, c101, f.x), mix(c011, c111, f.x), f.y), f.z);
  return mix(c, graded, frame.fx.z);
}
"""


comptime Grade = Stage[LutStyle]


def neutral_lut(size: Int) -> List[UInt8]:
    """The identity table of `size` ^ 3 entries as the strip `SceneRendererOf.set_lut` takes. Entry i of a channel is
    round(255 * i / (size - 1)); for size 16 that is 17 * i, exact."""
    var out = List[UInt8]()
    for g in range(size):
        for b in range(size):
            for r in range(size):
                for v in [r, g, b]:
                    out.append(UInt8((v * 255 * 2 + (size - 1)) // (2 * (size - 1))))
                out.append(255)
    return out^


def graded_lut(size: Int, warmth: Float64, contrast: Float64, saturation: Float64) -> List[UInt8]:
    """A table made in code (no image is shipped): a grey-point contrast about 0.5, a saturation about the luma, and a
    warm (red up, blue down) or cool tint of `warmth` (-1 .. 1, 0.08 of the range at 1). Computed per entry in Float64."""
    var out = List[UInt8]()
    for g in range(size):
        for b in range(size):
            for r in range(size):
                var rgb = [Float64(r) / Float64(size - 1), Float64(g) / Float64(size - 1), Float64(b) / Float64(size - 1)]
                var l = 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2]
                for i in range(3):
                    var v = l + (rgb[i] - l) * saturation
                    v = (v - 0.5) * contrast + 0.5
                    if i == 0:
                        v += 0.08 * warmth
                    elif i == 2:
                        v -= 0.08 * warmth
                    v = max(0.0, min(1.0, v))
                    out.append(UInt8(Int(floor(v * 255.0 + 0.5))))
                out.append(255)
    return out^


def lut_lookup(lut: List[UInt8], size: Int, r: Int, g: Int, b: Int) -> List[Float64]:
    """What `Grade` returns at full amount for the 8-bit input (r, g, b): the table read as the shader reads it
    (trilinear between the eight nearest entries), in 0 .. 255 and before the output is rounded."""
    var t = [Float64(r) / 255.0 * Float64(size - 1), Float64(g) / 255.0 * Float64(size - 1), Float64(b) / 255.0 * Float64(size - 1)]
    var lo = [min(Int(floor(t[0])), size - 2), min(Int(floor(t[1])), size - 2), min(Int(floor(t[2])), size - 2)]
    var out: List[Float64] = [0.0, 0.0, 0.0]
    for k in range(8):
        var dx = k & 1
        var dy = (k >> 1) & 1
        var dz = (k >> 2) & 1
        var w = (Float64(dx) * (t[0] - Float64(lo[0])) + Float64(1 - dx) * (1.0 - (t[0] - Float64(lo[0]))))
        w *= (Float64(dy) * (t[1] - Float64(lo[1])) + Float64(1 - dy) * (1.0 - (t[1] - Float64(lo[1]))))
        w *= (Float64(dz) * (t[2] - Float64(lo[2])) + Float64(1 - dz) * (1.0 - (t[2] - Float64(lo[2]))))
        var o = ((lo[1] + dy) * size * size + (lo[2] + dz) * size + (lo[0] + dx)) * 4
        for c in range(3):
            out[c] += w * Float64(Int(lut[o + c]))
    return out^
