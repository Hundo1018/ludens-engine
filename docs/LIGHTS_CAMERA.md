# Lights and camera

What the renderer (`SceneRendererOf`, app/render3d.mojo) offers for lighting a scene and for looking at it. Every
number below is printed by a test: `pixi run -e wasm test-lights-camera` (tests/lights_native.mojo, camera_native.mojo,
lens_native.mojo, env_probe_native.mojo, motion_native.mojo), on lavapipe.

With nothing set the renderer is as it was: a fixed white sun toward (0.4, 1.0, 0.6) at 0.6 on a 0.4 ambient, a
perspective view, no culling. `tests/scene_frame_native.mojo` prints the same frame hash (6884648193079427197) before
and after this file's features were added.

## Lights

| light | call | limit | shadow |
|---|---|---:|---|
| the sun | `set_sun(device, to_sun, color, intensity)`; `set_shadow(device, sun_shadow_vp(to_sun, centre, half_extent, depth), True)` | 1 | a 1024 x 1024 map |
| directional | `set_dir_lights(device, [DirLight(dir, color, intensity, True, centre, half_extent, depth)])` | 4 | one atlas tile (a box) |
| point | `set_lights(device, [PointLight(pos, range, color, intensity, shadow=True)])` | 16 | six atlas tiles (a cube) |
| spot | `set_spot_lights(device, [SpotLight(pos, dir, range, inner, outer, color, intensity, True)])` | 8 | one atlas tile |
| area (rectangle) | `set_area_lights(device, [AreaLight(centre, half_x, half_y, color, intensity, True, range)])` | 4 | one atlas tile, soft |
| environment | `set_environment(device, sky_environment(top, horizon, ground))`, `uniform_environment(color)`, `equirect_environment(pixels, w, h)`; captured from the scene: `EnvProbe` | 1 | - |

Types and helpers are in app/lights.mojo; the shader side is `POINT_LIGHTS_WGSL` in app/wgsl.mojo.

- **Units.** A light's colour times intensity is what a white matte surface facing it reflects: at the light for a point
  or spot light, with the panel filling its view for an area light, anywhere for a directional light.
- **Falloff.** Point and spot lights: `(1 - (d / range)^2)^2`, nothing beyond `range`. A spot is full inside `inner`
  radians of its axis and none beyond `outer` (smoothstep between).
- **Area lights** are nine samples of the rectangle (3 x 3 Gauss-Legendre). Against the closed-form form factor of a
  2 x 2 m panel: 0.17 % off at 2 m, 5.4 % at 1 m, 44 % too dark at 0.5 m. They are accurate from about one panel width.
- **Area light shadows** are soft by the panel's size (percentage-closer soft shadows from one view at the panel's
  centre, 120 degrees across). Over a plate's edge the 10-90 % penumbra is 0.50 m for a 1 m panel (similar triangles
  give 0.53) and 2.0 m for a 3 m panel (1.6). A point outside the 120 degrees is not shadowed.
- **Directional light shadows** cover a box (`centre`, `half_extent`, `depth`), as the sun's; outside it nothing is
  shadowed.
- **Environment.** Its radiance as order-2 spherical harmonics gives the ambient by the surface's normal. For a sky
  gradient the harmonics are within 0.03 of the exact irradiance facing up and facing down. `MatPbr` also reflects it:
  the gradient for a smooth surface, the irradiance for a rough one, through the split-sum fit.
- **Captured environment** (app/env_probe.mojo). `EnvProbe` draws the scene six times from a point into a 128 x 128
  cube map with mips; `MatPbr` then reflects the scene. In a room of six coloured walls a mirror ball at the probe
  shows the wall the law of reflection gives at six points (each within 0.08 of the wall's colour), and the captured
  ambient is within 0.001 of the room's exact irradiance. Limits: one probe; looked up by direction only, so
  reflections shift for surfaces away from the probe; rougher surfaces read box-filtered mips, not a GGX filter;
  nothing recaptures on its own.
- **Shadow atlas.** 2048 x 2048, 4 x 4 tiles of 512: 16 tiles; a point light takes six, a spot, directional or area
  light one. A pipeline needs `ShadowPass` in its pass list (as for the sun). Only items with a mesh cast, and primitives
  do not receive shadows, as for the sun.
- **What the sun's shadow darkens.** Until an environment is set, the fixed 0.4 ambient and the point lights are inside
  the sun's shadow factor, as before. After `set_environment` the factor applies to the sun's light only. Spot,
  directional and area lights are never inside it.
- **Custom materials.** `Surface` has a new field `extra` (light outside the sun's shadow factor). The built-in
  materials add it; a material that reads only `s.lit` shows the sun and, before an environment is set, the point
  lights.

## Camera

| feature | how |
|---|---|
| perspective | `View(pose, aspect)` |
| orthographic | `View.orthographic(pose, half_height, aspect)` |
| frustum culling | `r.cull = True`; `r.culled` is the number dropped by the latest draw |
| viewports | `SplitScreen(device, format, w, h, split_rects(n, w, h))`, `draw` into `split.target(i)`, `split.compose(device, frame, hud)` |
| depth of field | `Stage[DepthOfField]` in the stage graph; `r.lens_focus`, `r.lens_fstop`, `r.lens_sensor`, `r.lens_max_coc` |
| motion blur, camera | `Stage[MotionBlur]`; `r.shutter` (0 .. 1) |
| motion blur, bodies too | `Stage[ObjectMotionBlur]` with `Aux[VelocityPass]` as the aux target; `r.shutter` |
| two eyes | `Stereo[...]`, `r.eye_sep` (docs/PIPELINES.md) |
| fixed raster size | `SceneSize[...]` (docs/PIPELINES.md) |

Pose helpers (springs, shake, framing, rails, the simulation's frustum tests) are in ludens-core's
`procedural/camera_math.mojo`.

- **Orthographic.** A 2 m box is 67 pixels wide at 5 m and at 25 m (the scale gives 68); in perspective 170 and 1.
  Shadows, point lights and the stages' `world_at` work in it. Depth of field does nothing in a parallel view.
- **Culling** drops an item whose bounding sphere is outside the view (app/cull.mojo). It keeps one whose sun shadow,
  followed `cull_shadow_reach` metres (100 by default), crosses the view, and one within range of a shadow-casting
  spot or point light. Measured: 209 of 305 items dropped in a perspective view and 279 in a parallel one, 0 pixels
  changed. Skinned items are never dropped.
- **Viewports.** Each view is drawn into a texture of its rectangle's size and copied texel for texel: 2 and 4 views
  composed differ from the views drawn alone in 0 pixels. At most four; a pipeline with `History` needs a renderer per
  view.
- **Depth of field** is the thin lens: disc diameter `f^2 / (N (zf - f)) * |1 - zf / z|` on the sensor. Focused at
  8 m: a box at 3 m (disc 17.6 px) has an edge 9 px wide, one at 25 m (7.2 px) 5 px, the one in focus 0 px. One gather
  pass of 48 samples; discs are flat and round, and no larger than twice the disc of a point at infinity.
- **MotionBlur** follows the camera only: the camera turned 0.05 rad moves the picture 19 px, and a vertical edge is
  16 px wide (a 19 px ramp measures 15.2); the edge along the motion stays 1 px.
- **ObjectMotionBlur** also blurs bodies that move (app/velocity.mojo): `VelocityPass` draws every rigid item with
  this frame's and the previous frame's transform and stores each pixel's move on screen. A box that moved 24.0 px
  is stored as 24.6 px (steps of 0.6 px at this width) and its edge is 22 px wide (a 24 px ramp measures 19.2); a
  standing box's edge stays 0 px; a turning box's upper and lower halves hold opposite moves. Items are matched to
  the previous frame by mesh, size and nearest position within 64 places of the list. Skinned items are not drawn
  into the velocity target; moves beyond an eighth of the frame are clipped.

## Planned: water, reflections, ray tracing (issue #138)

Not built. Decided 2026-11-23: on the roadmap now, built later.

1. **Water surface.**
   - A heightfield mesh from ludens-core's FFT ocean or shallow water (core ROADMAP 17.60).
   - A Fresnel term.
   - Refraction from a copy of the scene's colour and depth, offset by depth.
   - Foam.
2. **Water reflections.** Two candidates, compared on cost and image:
   - **Planar reflection:** the scene drawn again, mirrored at the water plane, through the existing passes. Exact,
     but it costs a second scene draw each frame.
   - **Screen-space reflection (SSR):** reflects only what is on screen, and the probe fills in what is not.
3. **Probes.** Parallax correction, several probes blended by position, and recapture when the surroundings change.
4. **Compute ray tracing.**
   - `app/rt_gpu.mojo` extended from AABBs to a triangle BVH.
   - Ray-traced shadows, reflections or AO.
   - WebGPU has no hardware ray-tracing API, so this runs in compute shaders. Its cost decides whether it is a
     default or a high-end option.

Every phase reports the frame time it adds at 1080p, natively and in a browser, and keeps a reference image per
pipeline.


- Reflection parallax, several probes, light probes for moving bodies, global illumination.
- Per-bone velocity for skinned meshes; bokeh shapes.
- More than 16 shadow tiles; cascaded sun shadows.
- All of this has run on lavapipe only (native wgpu); none of it has been run in a browser.
