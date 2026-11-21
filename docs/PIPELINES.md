# Render pipelines

A render pipeline is a type:

```mojo
SceneRendererOf[P: RenderPass, F: PostEffect = NoPost, A: AuxTarget = NoAux]   # app/render3d.mojo
AppOf[M: GameMode, P: RenderPass, F: PostEffect = NoPost, A: AuxTarget = NoAux] # app/main.mojo, the shell around a game
```

- `P`: the pass list drawn into the scene target (colour + depth).
- `A`: a second pass list drawn from the same items into a target of its own (`aux`), for the stages to read.
- `F`: the graph of full-frame stages that turns those targets into the frame. `NoPost` draws `P` straight into the frame.

All three are chosen at compile time; the renderer has no list of known passes, materials or stages. The default,
`SceneRendererOf[DefaultPasses]`, is the engine's renderer as it was before any of this: `tests/scene_frame_native.mojo`
prints the same frame hash (6884648193079427197 on lavapipe) with and without the code described here.

Two files show the whole surface in use:

- `tests/custom_pipeline_native.mojo`: a pipeline whose material, pass, wire kind and stage are all defined in the test
  file. Nothing in `app/` names them. It checks that each part changes pixels when removed from the type.
- `tests/style_gallery_native.mojo`: 53 pipelines, listed with their structure in
  [STYLE_PIPELINES.md](STYLE_PIPELINES.md).

## What each part can do that a stage over the finished frame cannot

A stage (`Style`) is a fragment shader over finished targets. It can only use what those targets hold. The other parts
exist to put different things into them.

| part | what it adds | example (numbers are from the gallery test) |
|---|---|---|
| `Material` | the shading terms before they are combined (normal, light, shadow, world position per fragment), a vertex hook, blend / cull / depth-write state | `radiograph`: additive, no depth write, so surfaces behind others add up; 45198 pixels denser than one surface could make them |
| a pass in `P` | geometry that is not in the frame | `blueprint`: a second wire pass with `DEPTH_GREATER` draws the edges behind surfaces, dashed; 2187 hidden-edge pixels next to 2115 visible ones |
| `Aux[G]` | a second render of the scene with other materials | `one_bit`, `pencil_sketch`: per-pixel normals; `risograph`, `de_stijl`: unlit colour |
| `SceneSize` | the scene itself rasterised at a fixed size | `spectrum`: 256 x 192, then 0 of 768 cells hold more than 2 colours |
| `Stereo` | the scene from a second eye | `anaglyph`: 13539 pixels differ between the eyes |
| `History` | the previous frame | `daguerreotype`: 8 frames accumulated into one exposure |
| `Join`, `Scaled`, `Sized` | intermediate targets of other sizes, two branches read by one stage | `anamorphic`: a quarter-size streak branch joined with the full-size frame |
| `Strokes[K]` | instanced quads placed from the frame, overlapping, with a blend mode | `comic_cmyk`: three multiply plates of dots at different screen angles |

## Writing the parts

### A material (`app/material.mojo`)

```mojo
struct MatRings(Material):
    comptime ID: Int = MAT_COLOR          # which DrawItem.material it shades
    comptime NAME: StaticString = "rings by height"
    comptime BODY: StaticString = """
  let band = step(0.5, fract(s.wpos.y * 4.0));
  return vec4<f32>(s.base * mix(0.55, 1.0, band) * (0.5 + 0.5 * s.lit), 1.0);"""

comptime Rings = MeshPassOf[MatRings, MatSky]   # a mesh pass over a pack of materials
```

`BODY` is the body of a WGSL function that returns the fragment colour; `s` holds the surface's terms. Optional
members, read from the first material of the pack: `BLEND` (`BLEND_NONE / ALPHA / ADD / MULTIPLY`), `CULL`,
`DEPTH_WRITE`, and the vertex hooks `VERT_WORLD` (moves the world position, e.g. the hull's extrusion) and `VERT_CLIP`
(moves the clip position, e.g. `console_32bit`'s snap to a pixel grid).

### A pass (`app/render_pass.mojo`)

```mojo
struct MarkerPass(RenderPass):
    comptime SHADOW: Bool = False
    @staticmethod
    def sig() -> String: ...                       # one line for listings
    @staticmethod
    def create(device, color_format, depth_format, ref textures, ref res, caps) raises -> Self: ...
    def prepare(mut self, device, items, meshes, mut gpu, palette, view, res) raises: ...   # may raise; uploads
    def record_color(self, mut rpass, meshes, gpu): ...                                     # must not raise
```

`Then[P, Q]` runs two passes in order in the same render pass. A pass that only needs different items can wrap an
existing one (`MarkerPass` wraps `PrimitivePass` and hands it items of its own). `WirePassOf[K: WireKind]`
(`app/wire_pass.mojo`) draws each item's edges as lines; `K` gives the fragment body, blend and depth comparison.

### An aux target

`Aux[G: RenderPass]` draws `G` into an RGBA8 target with its own depth buffer, cleared to (0.5, 0.5, 1, 0).
`app/gbuffer.mojo` has `NormalPasses` (world normal as colour) and `AlbedoPasses` (unlit colour). Stages read it with
`aux_at(uv)` or `gnormal(uv)`.

### A stage (`app/post.mojo`)

```mojo
struct Split(Style):
    comptime NAME: StaticString = "split"
    comptime AFTER: StaticString = ""     # what it imitates; "" for none
    comptime WGSL: StaticString = """
fn style(uv : vec2<f32>, px : vec2<f32>) -> vec3<f32> {
  if uv.x > 0.5 { return aux_at(uv).rgb * aux_at(uv).a; }
  return src_at(uv);
}
"""
```

Inputs: `src` (the stage before it, or the scene), `src2` (the second branch of a `Join`, or the second eye),
`scene`, `zbuf`, `aux`, `prev`. Helpers in the prelude: `src_at`, `src_texel`, `src2_at`, `scene_at`, `prev_at`,
`aux_at`, `gnormal`, `view_z`, `world_at`, `is_far`, `normal_at`, `edge`, `gedge`, `cell_uv`, `fit_uv`, `luma`,
`hash21`, `vnoise`, `fbm`, `bayer4`, `bayer8`, `sobel`, `rgb2hsv`, `hsv2rgb`, `blur9`. The uniform `frame` carries the
size, the camera basis, `t` (time, frame number, seed) and `user`: four numbers the host sets each frame through
`SceneRendererOf.post_user` (`state_fingerprint` passes a 64-bit hash of the simulation state this way).

### Combining stages

| type | meaning |
|---|---|
| `Stage[S]` | one stage |
| `ThenPost[A, B]` | `A`, then `B` reading it as `src` |
| `Join[A, B, C]` | `A` and `B` both from the same input; `C` reads `A` as `src` and `B` as `src2` |
| `Scaled[A, D]` | `A` at 1 / D of the size |
| `Sized[A, W, H]` | `A` at exactly W x H |
| `History[A]` | `A` may read the previous finished frame as `prev` |
| `SceneSize[A, W, H, AW, AH]` | the scene, depth and aux are rasterised at W x H; the camera uses AW : AH if given |
| `Stereo[A]` | the scene is drawn a second time from the other eye (`eye_sep` metres apart) into `src2` |
| `Strokes[K: StrokeKind]` | instanced quads on a grid of `CELL` pixels; `K`'s WGSL places and shapes each one |

The HUD is drawn after the last stage, at the frame's size.

### Using it

```mojo
comptime MyPasses = Then[Rings, Then[WirePassOf[OrangeEdges], MarkerPass]]
var r = SceneRendererOf[MyPasses, Stage[Split], Aux[NormalPasses]](device, format, view)

comptime MyApp = AppOf[MyMode, MyPasses, Stage[Split], Aux[NormalPasses]]   # the same pipeline as a whole program
```

## Checks

```sh
pixi run -e wasm test-styles           # style_own (numbers, no GPU), custom_pipeline_native, style_gallery_native
pixi run -e wasm style-gallery         # the same frames as PNGs and contact sheets in build/gallery/
pixi run -e wasm style-gallery -- --doc --check   # STYLE_PIPELINES.md matches the run (CI)
```

The gallery test fails a pipeline whose `P`, `A` and `F` are the default pass list, no aux target and one bare stage,
and any two pipelines whose pictures are closer than a threshold; it also checks stated properties (cell colour
counts, hidden-edge pixels, per-eye difference).

## Limits

- One scene target and one aux target. A pipeline that needs three or more G-buffer layers has to pack them.
- `History` keeps one previous frame, at the frame's size.
- Material state (`BLEND`, `CULL`, `DEPTH_WRITE`, vertex hooks) is per mesh pass, taken from the first material of its
  pack. Two blend modes need two mesh passes.
- All of it has run on lavapipe only (native wgpu). The web build draws the default pipeline; no styled pipeline has
  been run in a browser.
