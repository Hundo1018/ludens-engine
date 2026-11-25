# Rendering tier 3: mesh LOD, volumetric fog, baked irradiance probes (#141)

| feature | how | file | test |
|---|---|---|---|
| mesh LOD | chains made offline by edge collapse (quadric error metric); a level per instance from its error in pixels, with hysteresis | `app/mesh_lod.mojo` | `tests/mesh_lod.mojo` (CPU), `tests/mesh_lod_native.mojo` (dense scene) |
| volumetric fog | a froxel grid, 160 x 90 x 64, filled and integrated by two compute passes, read by one full-screen stage | `app/volumetric.mojo` | `tests/volumetric_native.mojo` |
| global illumination | a grid of irradiance probes (order-2 spherical harmonics), baked by rendering six faces per probe, blended per pixel by the mesh and skinned passes | `app/irradiance.mojo` | `tests/probes_native.mojo` |

`pixi run -e wasm test-tier3` runs the four tests (the parity workflow runs it in CI); `pixi run -e wasm tier3-shots`
writes the reference images to `build/shots/tier3/` (`--docs` copies them to `docs/images/tier3/`). Not built here:
clouds, dynamic GI, the browser images. See "Left open" below.

All numbers below are from lavapipe (Mesa's CPU Vulkan driver) on a 4-core container, measured with the commands named.
Frame times there are CPU rasteriser times: they rank the features against each other and against the frame without
them, but they are not GPU times.

## Mesh LOD

```mojo
var chain = LodChain.build(r.meshes, mesh_id, [1.0, 0.5, 0.25, 0.125, 0.0625])
var states = List[LodState]()            # one per instance, kept between frames
var id = chain.pick(states[i], centre, scale, view, Float64(height_px))   # tol_px = 1.0 by default
r.push(DrawItem(..., id, ...))
```

Simplification is edge collapse ordered by the quadric error metric (Garland and Heckbert 1997). The kept vertex is one
of the edge's two ends, so a level only reuses vertices of the full mesh (positions, normals, uv unchanged). Vertices at
one position (uv seams, the poles of a sphere) are welded for the topology, so a seam does not open; a collapse that
would turn a neighbouring triangle over is refused; open borders get penalty planes and keep their outline.

Each level stores its error: the symmetric Hausdorff distance to the full mesh, measured at the vertices of both. `pick`
projects that error to pixels at the instance's distance and takes the coarsest level within `tol_px`. Hysteresis: a
change to a coarser level needs the error under `tol_px * (1 - 0.15)`, a change back needs the current level's error
over `tol_px * (1 + 0.15)`.

`tests/mesh_lod.mojo`, a sphere of 64 x 48 segments (radius 0.5):

| level | triangles | error (object units) |
|---:|---:|---:|
| 0 | 6144 | 0 |
| 1 | 3072 | 0.0024 |
| 2 | 1536 | 0.0064 |
| 3 | 768 | 0.0128 |
| 4 | 384 | 0.0206 |

At 1080 pixels high and 60 degrees across: level 0 up to 1.5 m, level 1 at 3 and 6 m, level 2 at 12 m, level 4 from
24 m. A distance that wobbles by 5 % around the 0 to 1 switch (2.75 m) for 120 frames: 0 switches with the band, 26
without it. A flat 32 x 32 grid goes from 2048 to 256 triangles with error 6e-17 and keeps its four corners. Two builds
are bit for bit equal.

Dense scene, `tests/mesh_lod_native.mojo`: 600 of those spheres in 30 rows from 4 m to 120 m, at 1920 x 1080.

| | triangles drawn | ms, run 1 | ms, run 2 |
|---|---:|---:|---:|
| full mesh everywhere | 3 538 956 | 764 | 595 |
| LOD, 1 pixel of error | 290 316 | 101 | 72 |

The triangle counts are the renderer's counter (`r.counts.triangles`, the floor included). The levels used: 0 instances at
level 0, 20 at level 1, 40 at level 2, 40 at level 3, 500 at level 4. The LOD frame against the full one: mean
difference 0.12 levels, 2915 pixels (0.14 %) off by more than 16 levels, at the silhouettes of the far spheres. Building
the chain (four levels and their errors) took 573 ms on the CPU.

## Volumetric fog

```mojo
var r = SceneRendererOf[Then[ShadowPass, DefaultPasses], VolumetricFog](device, format, view)
r.vol_density = 0.03       # extinction per metre at vol_base; 0 returns the input unchanged
r.vol_anisotropy = 0.6     # Henyey-Greenstein g
r.vol_falloff = 0.1        # per metre above vol_base
r.vol_albedo = 0.9
r.vol_far = 64.0           # metres: the far end of the grid
r.vol_ambient = 0.3
```

1. **inject** (compute): at each froxel's centre, the extinction and the light scattered toward the eye. The sun is
   the renderer's (`set_sun`) and is cut by its shadow map (`set_shadow`; the map is drawn when a `ShadowPass` is in the
   pass list), which makes the light shafts. Point lights add with the passes' range falloff, without shadows. An
   ambient share of the environment's mean radiance is added evenly.
2. **integrate** (compute): front to back along each column, Hillaire's energy-conserving step
   (SIGGRAPH 2015): `S += T * L * (1 - exp(-sigma dl)) / sigma; T *= exp(-sigma dl)`.
3. **composite** (fragment): the grid read at the pixel's depth with trilinear filtering; `colour * T + S`.

The renderer hands the effect its lights uniform, its shadow uniform and its shadow map through `PostInputs`
(`with_lights`). The buffers go as handles, not shared `Buffer`s: `wgpuBufferAddRef` traps on the web host.

`tests/volumetric_native.mojo`, 320 x 180:

| check | measured |
|---|---|
| density 0 | the frame without the effect, 0 pixels differ |
| uniform fog against `colour * T + L / sigma * (1 - T)` at a sky pixel, densities 0.01, 0.03, 0.08 | largest difference 0.46 levels |
| height falloff 0.3 / m, looking up 0.4 rad: change of the top 20 rows | 28.4 levels, against 148.2 with no falloff |
| roof over the left half, sun shadow on: light the fog adds below the horizon | under the roof 2.2 levels (10.2 with the shadow off); in the open 11.06 with and without |
| point light (intensity 20, range 5 m) 8 m ahead | +27.7 levels at the centre, 0 at the corner |

Cost, `volumetric_native --cost`, 1920 x 1080, two runs:

| frame | ms |
|---|---:|
| no stage | 28.8 to 29.8 |
| one copy stage (the offscreen scene target every stage needs) | 35.3 to 36.6 |
| volumetric fog | 68.1 to 71.8 |
| added by the fog over the copy stage | 32.9 to 35.2 |

The two froxel textures are RGBA16Float, 14.7 MB together (counted by `target_bytes`). Not handled: spot,
directional and area lights in the fog; the point lights' shadows; temporal reprojection (every frame is computed from
scratch).

## Baked irradiance probes

```mojo
var grid = ProbeGrid(origin, cell, nx, ny, nz)                 # up to MAX_PROBES = 2048
var sh = bake_probes(device, r, format, grid, items)            # 6 renders of 32 x 32 per probe
r.set_probes(device, grid.origin, grid.cell, grid.nx, grid.ny, grid.nz, sh)
r.clear_probes(device)                                          # back to the environment's harmonics
```

A probe is what `EnvProbe` captures, without the cube map: six faces read back and projected onto the nine harmonics
(`cube_environment`). The engine already had the harmonics for one environment (`Lights.sh`, `sh_lit`); the probes put
a grid of them in a storage buffer (288 KB, always bound) and `sh_lit_at(wpos, n)` blends the eight around a surface
point by trilinear weights. So moving bodies get the light of where they are. Primitives (items with no mesh) keep the
environment's ambient. The renderer's ambient at baking time lights the faces, so baking again with the grid set adds a
second bounce.

`tests/probes_native.mojo`:

| check | measured |
|---|---|
| a grid whose light changes along one axis; a box face at one value of that axis against one environment of the blended harmonics (`probe_sh_at`), for x, y and z | 0 levels apart on all three |
| `clear_probes` | the environment's frame, 0 pixels differ |
| room, red wall left, green wall right; irradiance facing the wall at the probe beside it | red 0.79 / green 0.26 by the red wall; green 0.41 / red 0.11 by the green wall |
| pixels the baked probes change in the room's frame | 34479 of 57600 |
| bake | 30 probes in 245 ms, 8.2 ms per probe |

Cost, `probes_native --cost`, 1920 x 1080 (the room): environment only 45.7 ms, with the 3 x 2 x 5 grid 89.2 ms, so
43.5 ms added. The lookup reads 8 probes of 9 coefficients per pixel (72 storage reads); blending the coefficients
before evaluating, or a 3D texture with hardware filtering, would cut that and is the next step if a GPU measurement
shows the same share.

Leaks: a probe on one side of a thin wall lights the other side. Keep walls a cell thick or split the grid.

## Reference images

`pixi run -e wasm tier3-shots -- --docs` (lavapipe, 320 x 180), in `docs/images/tier3/`:

| file | what |
|---|---|
| `lod_full.png`, `lod_picked.png` | the dense scene with the full mesh and with the picked levels |
| `vol_off.png`, `vol_wall.png` | a wall and a pillar, without and with fog |
| `vol_uniform.png` | uniform fog, density 0.03, over the sky |
| `vol_shafts.png` | the roof's shadow in the fog: dark under the roof, lit in the open |
| `vol_point.png` | a point light in the fog |
| `gi_environment.png`, `gi_probes.png` | the red and green room with the sky's ambient, then with the baked probes |

## Left open

- **Clouds.** The issue asks for them as a separate step. Not built.
- **Dynamic GI.** The issue asks for it only after measuring on WebGPU; the baked probes' own cost (above) is the first
  measurement, on lavapipe only.
- **Browser images and browser frame times.** Everything above ran natively on lavapipe. The compute passes use a 3D
  RGBA16Float storage texture and a fragment-stage storage buffer, both core WebGPU, but no browser has run them here.
- **Spot, directional and area lights in the fog; temporal reprojection of the froxels.**
