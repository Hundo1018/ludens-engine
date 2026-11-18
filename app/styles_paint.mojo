"""Post styles after painting and craft techniques (app/post.mojo Style). Several are the second stage of a chain that
starts with `styles_util.Kuwahara`."""
from app.post import Style


struct Pointillism(Style):
    """Separate round touches of unmixed colour on a pale ground; a shadow gets touches of the complementary hue."""

    comptime NAME: StaticString = "pointillism"
    comptime AFTER: StaticString = "Georges Seurat's Pointillism"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  var o = vec3<f32>(0.93, 0.90, 0.82);
  var cover = 0.0;
  for (var layer = 0; layer < 2; layer++) {
    let size = 5.0 + 1.5 * f32(layer);
    let p = px / size + f32(layer) * 13.7;
    let id = floor(p);
    for (var j = -1; j <= 1; j++) { for (var i = -1; i <= 1; i++) {
      let c = id + vec2<f32>(f32(i), f32(j));
      let h = hash22(c + f32(layer) * 5.0);
      let d = length(p - c - h);
      let m = smoothstep(0.52, 0.40, d);
      if m > cover * 0.999 && m > 0.0 {
        var hsv = rgb2hsv(src_at((c + h - f32(layer) * 13.7) * size * frame.res.zw));
        let r = hash21(c * 3.1 + 2.0);
        hsv.x = fract(hsv.x + (r - 0.5) * 0.12 + select(0.0, 0.5, r > 0.86 && hsv.z < 0.55));
        hsv.y = clamp(hsv.y * 1.8 + 0.15, 0.0, 1.0);
        hsv.z = clamp(hsv.z * 1.1 + (r - 0.5) * 0.2, 0.0, 1.0);
        o = mix(o, hsv2rgb(hsv), m);
        cover = m;
      }
    } }
  }
  return o;
}
"""


struct ImpastoRelief(Style):
    """Second stage after Kuwahara: the paint has thickness. The filtered image's brightness, broken up by a stroke
    noise, is treated as a height field and lit from the upper left; a canvas weave shows through."""

    comptime NAME: StaticString = "impasto"
    comptime AFTER: StaticString = "Impressionist oil impasto: Claude Monet"
    comptime WGSL: StaticString = """
fn height(uv : vec2<f32>) -> f32 {
  let p = uv * frame.res.xy;
  return luma(src_at(uv)) * 0.6 + 0.5 * fbm(vec2<f32>(p.x * 0.11 + p.y * 0.05, p.y * 0.34 - p.x * 0.04));
}
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let e = frame.res.zw * 1.5;
  let gx = height(uv + vec2<f32>(e.x, 0.0)) - height(uv - vec2<f32>(e.x, 0.0));
  let gy = height(uv + vec2<f32>(0.0, e.y)) - height(uv - vec2<f32>(0.0, e.y));
  let relief = clamp(1.0 + (-gx - gy) * 3.5, 0.55, 1.6);
  var c = src_at(uv);
  let g = luma(c);
  c = clamp(mix(vec3<f32>(g), c, 1.45), vec3<f32>(0.0), vec3<f32>(1.0));
  let weave = 0.96 + 0.04 * sin(px.x * 2.1) * sin(px.y * 2.1);
  return c * relief * weave;
}
"""


struct SwirlStrokes(Style):
    """Long strokes that follow a turbulent flow: colour and a stroke texture are both averaged along the flow line
    through each pixel, and the strokes are edged in dark blue."""

    comptime NAME: StaticString = "swirl_strokes"
    comptime AFTER: StaticString = "Vincent van Gogh's late brushwork (The Starry Night)"
    comptime WGSL: StaticString = """
fn flow(p : vec2<f32>) -> vec2<f32> {
  let e = 2.0;
  let a = fbm(p * 0.012 + vec2<f32>(0.0, e * 0.012)) - fbm(p * 0.012 - vec2<f32>(0.0, e * 0.012));
  let b = fbm(p * 0.012 + vec2<f32>(e * 0.012, 0.0)) - fbm(p * 0.012 - vec2<f32>(e * 0.012, 0.0));
  let g = sobel(p * frame.res.zw, 3.0);
  let v = vec2<f32>(a, -b) * 60.0 + vec2<f32>(-g.y, g.x) * 2.0;
  return v / max(length(v), 1e-4);
}
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  var c = vec3<f32>(0.0);
  var tex = 0.0;
  var pa = px;
  var pb = px;
  for (var i = 0; i < 10; i++) {
    pa += flow(pa) * 1.6;
    pb -= flow(pb) * 1.6;
    c += src_at(pa * frame.res.zw) + src_at(pb * frame.res.zw);
    tex += hash21(floor(pa / 2.0)) + hash21(floor(pb / 2.0));
  }
  c /= 20.0;
  tex = tex / 20.0;
  let g = luma(c);
  c = clamp(mix(vec3<f32>(g), c, 1.7), vec3<f32>(0.0), vec3<f32>(1.0));
  let ridge = smoothstep(0.42, 0.58, tex);
  c = mix(c * 0.62 + vec3<f32>(0.0, 0.02, 0.10), c * 1.12, ridge);
  return mix(c, vec3<f32>(0.06, 0.09, 0.25), 0.7 * step(0.5, edge(uv, 1.5)));
}
"""


struct WatercolourPaper(Style):
    """Second stage after Kuwahara: thin washes on cold-pressed paper. The washes are lightened toward the paper,
    pigment pools darker along wash borders, settles into the paper's grain, and the borders wander."""

    comptime NAME: StaticString = "watercolour"
    comptime AFTER: StaticString = "English watercolour: J. M. W. Turner's washes"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let wob = (vec2<f32>(fbm(px * 0.03), fbm(px * 0.03 + 40.0)) - 0.5) * 9.0 * frame.res.zw;
  let u = uv + wob;
  var c = src_at(u);
  let g = luma(c);
  c = mix(vec3<f32>(g), c, 1.25);
  let pool = sobel(u, 2.0).z;
  let grain = fbm(px * 0.45);
  let paper = vec3<f32>(0.97, 0.95, 0.90);
  let density = clamp(0.62 + 0.9 * pool + 0.35 * (grain - 0.5) + 0.25 * (fbm(px * 0.015) - 0.5), 0.0, 1.0);
  var o = mix(paper, c, density);
  o *= 1.0 - 0.5 * smoothstep(0.08, 0.3, pool);
  return o * (0.96 + 0.06 * vnoise(px * 0.8));
}
"""


struct SumiE(Style):
    """Black ink and water only: three dilutions of wash, a brush line of uneven width and dryness, absorbent paper,
    a vermilion seal."""

    comptime NAME: StaticString = "sumi_e"
    comptime AFTER: StaticString = "East Asian ink-wash painting (sumi-e, shuimo)"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let wob = (vec2<f32>(fbm(px * 0.02), fbm(px * 0.02 + 9.0)) - 0.5) * 12.0 * frame.res.zw;
  let l = luma(blur9(uv + wob, 3.0));
  let far = is_far(uv, 60.0);
  var wash = smoothstep(0.75, 0.2, l) * (1.0 - far);
  wash = (floor(wash * 3.0 + fbm(px * 0.05)) / 3.0) * 0.55;
  wash += 0.25 * (1.0 - far) * smoothstep(0.55, 0.9, fbm(px * 0.006 + 3.0)) ;
  let dry = smoothstep(0.25, 0.6, vnoise(vec2<f32>(px.x * 0.08, px.y * 0.9)));
  let width = 1.0 + 2.5 * vnoise(px * 0.02);
  let stroke = step(0.4, edge(uv + wob * 0.5, width)) * mix(0.55, 1.0, dry);
  let ink = clamp(max(wash, stroke * 0.92), 0.0, 1.0);
  var o = mix(vec3<f32>(0.94, 0.92, 0.85), vec3<f32>(0.08, 0.08, 0.09), ink);
  o *= 0.95 + 0.07 * vnoise(vec2<f32>(px.x * 0.05, px.y * 0.7));
  let s = (uv - vec2<f32>(0.925, 0.84)) * frame.res.xy / frame.res.y;
  if abs(s.x) < 0.035 && abs(s.y) < 0.035 {
    let inner = step(abs(s.x), 0.027) * step(abs(s.y), 0.027) * step(0.5, vnoise(s * 160.0 + 4.0));
    o = mix(vec3<f32>(0.78, 0.13, 0.10), vec3<f32>(0.94, 0.92, 0.85), inner * 0.9);
  }
  return o;
}
"""


struct DeStijl(Style):
    """An irregular grid of rectangles, each filled with white, red, yellow, blue or black by what lies behind it,
    between heavy black bars."""

    comptime NAME: StaticString = "de_stijl"
    comptime AFTER: StaticString = "Piet Mondrian's De Stijl compositions"
    comptime WGSL: StaticString = """
fn cut(i : f32, n : f32, seed : f32) -> f32 { return (i + 0.6 * (hash21(vec2<f32>(i, seed)) - 0.5) * step(0.5, i) * step(i, n - 0.5)) / n; }
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let n = vec2<f32>(13.0, 8.0);
  var lo = vec2<f32>(0.0);
  var hi = vec2<f32>(1.0);
  for (var i = 0; i < 13; i++) {
    let a = cut(f32(i), n.x, 1.0);
    let b = cut(f32(i) + 1.0, n.x, 1.0);
    if uv.x >= a && uv.x < b { lo.x = a; hi.x = b; }
  }
  for (var j = 0; j < 8; j++) {
    let a = cut(f32(j), n.y, 2.0);
    let b = cut(f32(j) + 1.0, n.y, 2.0);
    if uv.y >= a && uv.y < b { lo.y = a; hi.y = b; }
  }
  var hsv = vec3<f32>(0.0, -1.0, 0.0);
  for (var j = 0; j < 3; j++) { for (var i = 0; i < 3; i++) {
    let h = rgb2hsv(src_at(mix(lo, hi, (vec2<f32>(f32(i), f32(j)) + 0.5) / 3.0)));
    if h.y > hsv.y { hsv = h; }
  } }
  var o = vec3<f32>(0.95, 0.94, 0.90);
  if hsv.y > 0.3 {
    o = vec3<f32>(0.85, 0.12, 0.10);
    if hsv.x > 0.10 && hsv.x < 0.24 { o = vec3<f32>(0.97, 0.82, 0.10); }
    if hsv.x >= 0.24 && hsv.x < 0.80 { o = vec3<f32>(0.08, 0.20, 0.60); }
  }
  if hsv.z < 0.3 { o = vec3<f32>(0.07); }
  let d = min(min(uv.x - lo.x, hi.x - uv.x) * frame.res.x, min(uv.y - lo.y, hi.y - uv.y) * frame.res.y);
  return mix(vec3<f32>(0.06), o, step(2.5, d));
}
"""


struct StainedGlass(Style):
    """Irregular panes of saturated glass, each one colour, uneven in thickness, held in dark lead cames, lit from
    behind."""

    comptime NAME: StaticString = "stained_glass"
    comptime AFTER: StaticString = "Gothic cathedral stained glass"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let p = px / 22.0;
  let id = floor(p);
  var d1 = 9.0;
  var d2 = 9.0;
  var site = vec2<f32>(0.0);
  for (var j = -1; j <= 1; j++) { for (var i = -1; i <= 1; i++) {
    let c = id + vec2<f32>(f32(i), f32(j));
    let s = c + hash22(c);
    let d = length(p - s);
    if d < d1 { d2 = d1; d1 = d; site = s; } else if d < d2 { d2 = d; }
  } }
  var hsv = rgb2hsv(src_at(site * 22.0 * frame.res.zw));
  hsv.y = clamp(hsv.y * 1.9 + 0.25, 0.0, 1.0);
  hsv.z = clamp(hsv.z * 1.15, 0.0, 1.0);
  var o = hsv2rgb(hsv);
  o *= 0.75 + 0.5 * vnoise(px * 0.12 + site * 7.0) ;
  o += 0.25 * pow(max(1.0 - d1 * 1.2, 0.0), 3.0);
  let lead = smoothstep(0.10, 0.04, d2 - d1);
  return mix(o, vec3<f32>(0.04, 0.04, 0.05), lead);
}
"""


struct Mosaic(Style):
    """Small square stones set in rows with pale grout, each cut a little differently; the sky is gold."""

    comptime NAME: StaticString = "mosaic"
    comptime AFTER: StaticString = "Byzantine wall mosaics (Ravenna)"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let size = 9.0;
  let row = floor(px.y / size);
  let p = vec2<f32>(px.x + 4.0 * sin(row * 1.7) + 3.0 * sin(px.y * 0.03), px.y + 2.5 * sin(px.x * 0.025));
  let id = floor(p / size);
  let cu = (id + 0.5) * size * frame.res.zw;
  let r = hash21(id);
  var c = src_at(cu);
  let g = luma(c);
  c = clamp(mix(vec3<f32>(g), c, 1.35), vec3<f32>(0.0), vec3<f32>(1.0)) * (0.82 + 0.3 * r);
  if is_far(cu, 60.0) > 0.5 { c = vec3<f32>(0.85, 0.64, 0.18) * (0.7 + 0.5 * r) + 0.25 * step(0.9, r); }
  let f = fract(p / size) - 0.5;
  let inset = 0.40 + 0.06 * hash21(id + 9.0);
  let tile = smoothstep(inset + 0.04, inset - 0.02, max(abs(f.x), abs(f.y)));
  let bevel = 1.0 + 0.25 * (f.y - f.x);
  return mix(vec3<f32>(0.78, 0.75, 0.68), c * bevel, tile);
}
"""


struct CrossStitch(Style):
    """One crossed pair of threads per 8-pixel square of an even-weave cloth, in a limited set of floss colours."""

    comptime NAME: StaticString = "cross_stitch"
    comptime AFTER: StaticString = "counted cross-stitch samplers"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let size = 8.0;
  let id = floor(px / size);
  let cu = (id + 0.5) * size * frame.res.zw;
  var c = src_at(cu);
  let cg = luma(c);
  c = floor(clamp(mix(vec3<f32>(cg), c, 1.5), vec3<f32>(0.0), vec3<f32>(1.0)) * 5.0 + 0.5) / 5.0;
  let f = fract(px / size);
  let a = abs(f.x - f.y);
  let b = abs(f.x + f.y - 1.0);
  let over = smoothstep(0.36, 0.24, a);
  let under = smoothstep(0.36, 0.24, b) * (1.0 - over);
  let twist = 0.85 + 0.15 * sin((f.x + f.y) * 40.0);
  let twist2 = 0.85 + 0.15 * sin((f.x - f.y) * 40.0);
  let hole = smoothstep(0.16, 0.08, length(fract(px / size + 0.5) - 0.5));
  var cloth = vec3<f32>(0.90, 0.87, 0.78) * (0.92 + 0.08 * sin(px.x * 3.14159 / 2.0) * sin(px.y * 3.14159 / 2.0));
  cloth = mix(cloth, vec3<f32>(0.55, 0.52, 0.45), hole);
  if is_far(cu, 60.0) > 0.5 { return cloth; }
  var o = mix(cloth, c * 0.8 * twist2, under);
  o = mix(o, c * (1.1 - 0.4 * a) * twist, over);
  return o;
}
"""


struct PencilSketch(Style):
    """Graphite on drawing paper: a soft outline drawn twice, slightly apart, and tone laid in with short strokes in
    one direction, heavier where it is darker."""

    comptime NAME: StaticString = "pencil_sketch"
    comptime AFTER: StaticString = "graphite pencil drawing"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let l = luma(blur9(uv, 1.5));
  let j = (vec2<f32>(vnoise(px * 0.04), vnoise(px * 0.04 + 7.0)) - 0.5) * 5.0 * frame.res.zw;
  let outline = 0.75 * edge(uv + j, 1.0) + 0.45 * edge(uv - j * 1.7, 1.0);
  let d = px.x * 0.62 + px.y * 0.78;
  let along = px.x * 0.78 - px.y * 0.62;
  let stroke = vnoise(vec2<f32>(d * 0.9, along * 0.05)) * 0.7 + 0.3 * vnoise(vec2<f32>(d * 2.3, along * 0.02));
  let tone = smoothstep(0.85, 0.15, l) * (1.0 - is_far(uv, 60.0));
  let shade = smoothstep(1.0 - tone, 1.0 - tone + 0.35, stroke) * (0.35 + 0.5 * tone);
  let tooth = 0.85 + 0.3 * hash21(floor(px));
  let graphite = clamp((outline + shade) * tooth, 0.0, 1.0);
  return mix(vec3<f32>(0.95, 0.94, 0.91), vec3<f32>(0.22, 0.22, 0.24), graphite);
}
"""


struct Chalkboard(Style):
    """Chalk on a wiped green board: broken dusty outlines, the lit faces rubbed in with the side of the stick in a
    faint tint of their colour."""

    comptime NAME: StaticString = "chalkboard"
    comptime AFTER: StaticString = "chalk drawings on a classroom blackboard"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let c = src_at(uv);
  let l = luma(c);
  let dust = hash21(floor(px / 1.5)) * 0.6 + 0.4 * vnoise(px * 0.3);
  let board = vec3<f32>(0.10, 0.20, 0.16) * (0.8 + 0.5 * fbm(vec2<f32>(px.x * 0.004, px.y * 0.02))) + 0.03 * fbm(px * 0.02);
  let line = edge(uv, 1.6) * step(0.3, dust);
  let rub = smoothstep(0.6, 0.9, l) * step(0.5, dust) * step(fract((px.x - px.y) / 5.0), 0.5) * 0.22 * (1.0 - is_far(uv, 60.0));
  let tint = mix(vec3<f32>(0.95), normalize(c + 0.05) * 1.5, 0.55);
  return board + line * vec3<f32>(0.92, 0.92, 0.88) + rub * tint;
}
"""


struct Chiaroscuro(Style):
    """One light from the upper left on a dark ground: the shadows are crushed to brown-black, the lights glazed
    warm, the varnish finely cracked."""

    comptime NAME: StaticString = "chiaroscuro"
    comptime AFTER: StaticString = "Baroque chiaroscuro: Caravaggio, Rembrandt"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let w = world_at(uv);
  let n = normal_at(uv);
  let far = is_far(uv, 60.0);
  let lp = vec3<f32>(-4.0, 6.0, 5.0);
  let to = lp - w;
  let ndl = max(dot(n, normalize(to)), 0.0);
  let pool = smoothstep(17.0, 7.0, length(to));
  let light = (0.10 + 2.8 * ndl * pool) * (1.0 - far);
  var c = src_at(uv);
  c = c * c * light * vec3<f32>(1.0, 0.82, 0.55) * 1.7;
  c = c / (c + 0.35) * 1.25;
  c += vec3<f32>(0.035, 0.022, 0.012);
  let p = px / 14.0;
  let id = floor(p);
  var d1 = 9.0;
  var d2 = 9.0;
  for (var j = -1; j <= 1; j++) { for (var i = -1; i <= 1; i++) {
    let s = id + vec2<f32>(f32(i), f32(j));
    let d = length(p - s - hash22(s));
    if d < d1 { d2 = d1; d1 = d; } else if d < d2 { d2 = d; }
  } }
  c *= 1.0 - 0.25 * smoothstep(0.05, 0.0, d2 - d1);
  return c * vignette(uv, 1.6);
}
"""


struct PaperCut(Style):
    """Sheets of flat coloured paper, one per form, each casting a soft shadow on the sheet behind it."""

    comptime NAME: StaticString = "paper_cut"
    comptime AFTER: StaticString = "Henri Matisse's paper cut-outs"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  var hsv = rgb2hsv(blur9(uv, 2.0));
  hsv.x = floor(hsv.x * 10.0 + 0.5) / 10.0;
  hsv.y = clamp(floor(hsv.y * 2.0 + 0.8) / 2.0, 0.0, 0.85);
  hsv.z = mix(0.45, 0.92, step(0.4, hsv.z));
  var o = hsv2rgb(hsv);
  if is_far(uv, 60.0) > 0.5 { o = vec3<f32>(0.93, 0.89, 0.78); }
  let z = view_z(uv);
  var sh = 0.0;
  for (var i = 1; i <= 6; i++) {
    let zs = view_z(uv + vec2<f32>(-1.4, -1.8) * f32(i) * frame.res.zw);
    sh += step(zs, z * 0.94) * (1.0 - f32(i) / 7.0);
  }
  o *= 1.0 - 0.38 * clamp(sh / 2.5, 0.0, 1.0);
  return o * (0.95 + 0.06 * vnoise(px * 0.7) + 0.03 * vnoise(vec2<f32>(px.x * 0.05, px.y * 0.9)));
}
"""


struct Porcelain(Style):
    """Cobalt under a clear glaze on white: a brushed outline, the shade as two strengths of blue wash, a soft
    highlight of the glaze across the piece."""

    comptime NAME: StaticString = "porcelain"
    comptime AFTER: StaticString = "Ming blue-and-white porcelain (qinghua)"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  let l = luma(blur9(uv, 2.0));
  let far = is_far(uv, 60.0);
  let brush = 0.75 + 0.25 * vnoise(vec2<f32>(px.x * 0.06 + px.y * 0.02, px.y * 0.4));
  var blue = step(0.4, edge(uv, 1.5 + vnoise(px * 0.03))) * 0.95;
  blue = max(blue, (1.0 - far) * (0.30 * step(l, 0.62) + 0.32 * step(l, 0.42)) * brush);
  let n = normal_at(uv);
  let scroll = step(0.5, far) * smoothstep(0.06, 0.02, abs(fract(uv.x * 9.0 + 0.3 * sin(uv.y * 40.0)) - 0.5) - 0.2) * step(uv.y, 0.09) * 0.6;
  blue = max(blue, scroll);
  var o = mix(vec3<f32>(0.95, 0.96, 0.97), vec3<f32>(0.07, 0.16, 0.52), clamp(blue, 0.0, 1.0));
  o += 0.10 * smoothstep(0.75, 1.0, dot(n, normalize(vec3<f32>(-0.3, 0.8, 0.5)))) * (1.0 - far);
  return o * vignette(uv, 0.5);
}
"""


struct InkLine(Style):
    """The post stage of the cel pipeline: a black outline over whatever the passes drew. The two-tone shading is
    done before it, on the surface, by the material `MatCel`."""

    comptime NAME: StaticString = "cel_animation"
    comptime AFTER: StaticString = "hand-painted animation cels: two tones of paint per colour under an ink line"
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  return mix(src_at(uv), vec3<f32>(0.05, 0.04, 0.08), step(0.35, edge(uv, 1.4)));
}
"""
