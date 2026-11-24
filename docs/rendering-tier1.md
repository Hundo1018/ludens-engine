# Rendering tier 1: anti-aliasing, bloom, colour grading (#139)

Four things, each built on the stage graph of `app/post.mojo` or on the renderer's own pass:

| effect | how | file |
|---|---|---|
| MSAA 4x | `RenderCaps.samples = 4`; every scene pipeline is built with that sample count | `app/msaa.mojo`, `app/render3d.mojo` |
| FXAA | one stage, `Fxaa` | `app/post_fx.mojo` |
| bloom | a mip chain of nine stages and a composite, `Bloom` | `app/post_fx.mojo` |
| colour grading | a 3D LUT after tone mapping, `Grade` | `app/post_fx.mojo` |

```mojo
comptime Look = ThenPost[Fxaa, ThenPost[Bloom, Grade]]
var r = SceneRendererOf[DefaultPasses, Look](device, format, view)
r.fxaa_strength = 1.0       # 0: the stage returns its input
r.bloom_threshold = 0.75    # brightness (0 .. 1, finished colour) above which a pixel feeds the glow
r.bloom_intensity = 1.0     # share of the thresholded energy added back; 0 returns the input
r.set_lut(device, 16, graded_lut(16, 0.6, 1.1, 0.8))
r.lut_amount = 1.0          # 0 returns the input

var caps = RenderCaps.default()
caps.samples = 4            # MSAA 4x: no stage needed
var m = SceneRendererOf[DefaultPasses, ThenPost[Bloom, Grade]](device, format, view, caps=caps)
```

Every stage returns its input unchanged at its "off" setting, and a stage added to a pipeline costs nothing else:
the numbers below say what each costs when on.

## MSAA

`RenderCaps.samples` is 1 (default, the frame is as before) or 4. 4 is the one count every WebGPU device supports for a
renderable colour format and for Depth32Float, so there is nothing to query that could fail on the web; other counts are
rejected by `RenderCaps.check`. The primitive, mesh, skinned, particle and wire passes build their pipelines from
`caps.samples`; a pass written elsewhere must do the same. The renderer draws into a 4-sample colour and depth target
and resolves the colour into the frame (no stages) or into the scene colour the stages read. WebGPU cannot resolve
depth, so with stages a small pass (`DepthResolve`) copies sample 0 into the one-sample depth the stages bind. The HUD is
drawn after the resolve; the aux target (normals, velocity) stays one sample. Not supported: Stereo (the constructor
raises). FXAA after MSAA is not an improvement (below): use one of the two.

## Anti-aliasing: measurements

All on lavapipe, `pixi run -e wasm test-post-fx` (`tests/post_fx_native.mojo`), 320 x 180, a scene of dark boxes with
slanted edges and a sphere against the sky.

**Edge error.** The reference is the same scene drawn at 1280 x 720 and box-filtered 4 x 4 down. The error is the mean
absolute channel difference, in levels of 255, over the 1249 pixels whose 3 x 3 neighbourhood in the reference has a luma
range above 8 levels.

| | edge error (levels) | against no filter |
|---|---:|---:|
| no filter | 9.99 | 1.00 |
| FXAA | 5.44 | 0.55 |
| MSAA 4x | 2.69 | 0.27 |
| MSAA 4x, then FXAA | 5.56 | 0.56 |

Pixels more than 2 pixels from an edge (a luma step above 2 levels) are bit-identical to the frame without the filter,
for FXAA and for MSAA.

**Edge crawl, and the decision on TAA.** The issue asks for TAA only after measuring. The camera slides sideways in 40
steps of 0.07 pixel past a vertical edge (dark box on the sky). The edge position is where the luma crosses half way, by
linear interpolation between the two pixels; the crawl is the RMS error of that position from the projected edge, once the
constant offset is removed. `pop` is the largest change of any one pixel between two frames (the edge's own step is about
12 levels).

| | crawl RMS (pixels) | pop (levels) |
|---|---:|---:|
| no filter | 0.282 | 167.7 |
| FXAA | 0.282 | 150.3 |
| MSAA 4x | 0.088 | 42.0 |

FXAA has no sub-pixel information, so it does not reduce the crawl of an edge that is aligned with the pixel grid; MSAA 4x
removes 69 % of it and a quarter of the pop. TAA is **not built** here. With MSAA 4x available in the forward renderer
the remaining crawl is 0.088 pixel RMS, and TAA needs three things that do not exist yet: a sub-pixel jitter of the
projection (`View` has none), a history target with reprojection and clamping (`History` and the velocity target exist),
and a measurement on content with shading aliasing (specular, textures), which this scene does not have. The static edge
test above cannot decide that. It is left open in this issue.

## Bloom

`Bloom` is ten stages: a prefilter at half size, four 13-tap downsamples to 1/32, four upsamples that add each level to the
tent-filtered sum of the coarser ones, and a composite. The levels' weights are 1/2, 1/4, 1/8, 1/16, 1/16, so they add up
to 1. The prefilter cuts each source pixel at the threshold (a soft knee of 0.1 below it) before averaging 4 x 4 pixels.
The frame is 8 bits per channel, so the threshold and the glow are in display colour.

Measured on a 34-pixel box of brightness 176 on a wall of 4, threshold 88, intensity 1:

- energy above the threshold, computed on the CPU from the frame: 101 728 level-pixels; added by the stage: 98 564
  (ratio 0.969);
- brightness added at 2, 6, 12, 24, 48 pixels from the box's edge: 13, 6, 3, 1, 0 levels;
- 14 423 of the 98 564 (15 %) lands outside the box's own area;
- intensity 0.5 adds 0.489 of the energy of intensity 1 (8-bit rounding of the faint tails);
- intensity 0, or a threshold above the brightest pixel, or a box below the threshold minus the knee: the frame is the
  frame without the stage, pixel for pixel.

## Colour grading

`Grade` reads a 3D LUT stored as a strip, `size` squares of `size` x `size` texels side by side (texel
`(b * size + r, g)`), through eight `textureLoad`s and a trilinear mix in the shader. A 2D strip, not a 3D texture, so a
native and a browser device read the same texels the same way. It runs after the passes' tone mapping (ACES), so it
grades display colour.

`neutral_lut(16)` leaves every 8-bit input unchanged: 255 / 15 = 17, so the entries are exact and the interpolation
lands on the input. The test draws a 256 x 256 ramp of (red, green) for each of the 256 blue levels through the stage and
compares: **0 of 16 777 216 inputs changed**. Sizes where 255 / (size - 1) is not a whole number (17, 32) round their
entries and are off by one level in places; use 16 for a neutral table. A renderer made with a stage reads this neutral
16-table until `set_lut` is called.

`graded_lut(size, warmth, contrast, saturation)` makes a table in code. The LUT assets of this repository are generated
by that function, so no image, and no licence, is added to the build. A table loaded from a file goes through the same
`set_lut(device, size, rgba)`. A graded table read back from the GPU differs from the CPU reading (`lut_lookup`) by at
most 0.4999 level over 8 x 86 x 86 sampled inputs, which is the rounding of the output.

## Frame cost at 1920 x 1080

`pixi run -e wasm post-fx-cost` (`scripts/post_fx_cost.py`): a scene of three boxes and a sphere, every pipeline drawn once
per round in turn, median of 11 rounds after 2 warm-up rounds. The timer covers `draw()` (encode and submit) and the wait
for the pixels to be mapped; the scene is pushed before the timer starts, and every row reads the same 8 MB back.
lavapipe is a CPU rasteriser: these numbers rank the work each effect adds; they are not GPU times.

| pipeline | ms / frame | min | max | added over |
|---|---:|---:|---:|---|
| no stages (frame drawn directly) | 4.85 | 4.64 | 6.33 | - |
| one copy stage (the baseline for every stage below) | 11.32 | 9.86 | 13.06 | no stages: +6.47 |
| FXAA | 18.74 | 17.16 | 22.37 | copy stage: +7.42 |
| bloom (5 levels) | 34.60 | 30.99 | 41.31 | copy stage: +23.28 |
| grade (LUT 16^3) | 24.94 | 23.44 | 29.17 | copy stage: +13.62 |
| MSAA 4x, no stages | 13.28 | 12.82 | 16.66 | no stages: +8.43 |
| MSAA 4x + one copy stage | 26.14 | 23.74 | 35.38 | MSAA alone: +12.86 ; copy stage: +14.81 |
| FXAA + bloom + grade | 76.15 | 67.12 | 83.02 | copy stage: +64.83 |
| MSAA 4x + bloom + grade | 67.80 | 63.96 | 87.38 | MSAA + copy stage: +41.66 |
| edge-dense scene: one copy stage | 32.07 | 27.85 | 37.88 | - |
| edge-dense scene: FXAA | 42.60 | 40.76 | 56.12 | copy stage, same scene: +10.53 |

Two runs of the table on one machine differed by 1 to 3 ms per row (the min and max columns show the spread inside a
run), so read the rows to about 2 ms. FXAA returns after five taps on a pixel with no contrast, so its row in the first
scene (three boxes, a sphere, mostly sky) is the cheap case; the edge-dense scene (a grid of 336 turned boxes) is the
expensive one: +10.5 ms instead of +7.4. Bloom costs the same on any content (nine passes over fixed-size targets, +23 ms
here). Grade is eight texture reads a pixel on any content. MSAA costs +8.4 ms with no stages on this scene, whose
shading is trivial; on a scene with heavy fragment shading the shading cost does not grow (each covered pixel is shaded
once), while the rasteriser and the resolve do four times the work.

A stage pipeline draws the scene into an offscreen target first; that is the "one copy stage" row, the baseline for the
rows below it.

## Native against browser

Two 480 x 270 frames, one with FXAA + bloom + grade and one with MSAA 4x + bloom + grade, are drawn by
`app/post_fx_frame.mojo` natively (lavapipe, `app/post_fx_pixels.mojo`) and in the web app, and compared by
`shell/web/app.ts` (`?selftest=parity`) under the existing per-browser rows of `shell/web/pixel_tolerance.json`, which
are unchanged. Headless Chrome (SwiftShader) against lavapipe:

| frame | max delta | fraction > 8 | fraction > 32 | row (chrome) |
|---|---:|---:|---:|---|
| FXAA + bloom + grade | 66 | 1.9e-4 | 3.9e-5 | 160 / 3e-4 / 3e-4: inside |
| MSAA 4x + bloom + grade | 79 | 1.7e-3 | 6.2e-5 | fraction > 8 is over the row |

The MSAA frame exceeds the row on one number. Splitting its pixels shows why: pixels away from edges differ by at most 2
levels (none above 8); of the 3122 edge pixels 218 (7 %) differ by more than 8, 8 by more than 32, the largest by 79. Where
the four samples lie inside a pixel is the rasteriser's choice, so an edge pixel gets a different coverage, one step of
the pattern, from another rasteriser. The existing rows are not changed. The MSAA frame's pixels away from edges meet them
as they stand, and its edge pixels meet a row of their own, `msaaEdge` (96 / 0.10 / 0.005, above the measured 79 / 0.070 /
0.0026), recorded with this measurement in the file's comment. Firefox could not be run where this was written; CI runs
it, and the row applies to both browsers.

## The web host and `TextureView.clone()`

Every stage pipeline hands a target to the next stage with `TextureView.clone()`, which calls `wgpuTextureViewAddRef`. The
browser host of the pinned wgpu-mojo (`web/webgpu_host.mjs`) traps on that call, and its `wgpuTextureViewRelease` deletes
the handle at the first release. So no stage pipeline could run in a browser before this change; FXAA "for the web" needed
it. `shell/web/view_refs.mjs` wraps the two imports with a reference count (`tests/test_view_refs.mjs`,
`pixi run -e wasm test-view-refs`); `app.ts` applies it when it builds the imports. The fix belongs in wgpu-mojo.

## Tests and checks

| check | command | in CI |
|---|---|---|
| every number above except cost and the browser rows | `pixi run -e wasm test-post-fx` | the parity workflow |
| native against browser pixels | `pixi run -e wasm web-check` (`?selftest=parity`) | the parity workflow |
| TextureView counts | `pixi run -e wasm test-view-refs` | the editor workflow |
| frame cost | `pixi run -e wasm post-fx-cost` | no: it takes about a minute and is a CPU rasteriser's time |
| each test fails under a mutation | `pixi run -e wasm python3 scripts/mutation_post_fx.py` | no: it rebuilds the test once per mutation |
