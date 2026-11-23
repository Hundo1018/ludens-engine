# Particles and effects (#121)

Emitters are rows of a data table (`docs/data-tables.md`). The CPU runs them with a seeded generator, the renderer draws
the live particles as camera-facing quads in one instanced draw per blend mode. Hit sparks, dust, smoke and UI
feedback use the same path.

Code: `game/particles.mojo` (simulation, packing), `game/data/particles.schema` and `particles.table` (the emitter
fields and three sample emitters), `game/particles_table.mojo` (generated accessors), `app/particle_pass.mojo` (the
`RenderPass`). Tests: `pixi run -e wasm test-particles`, `test-particles-native`, `particles-same`.

## Emitter fields

One row of the `particles` table is one emitter asset. Units are metres, seconds and degrees.

| field | meaning |
|---|---|
| `rate` | particles per second while playing |
| `burst_count`, `burst_every` | `burst_count` particles at time 0, again every `burst_every` seconds (0: once) |
| `lifetime_min`, `lifetime_max` | life of each particle, uniform between |
| `speed_min`, `speed_max` | initial speed, uniform between |
| `direction`, `cone_deg` | axis and half angle of the velocity cone. Directions are uniform over the cone's solid angle |
| `gravity`, `drag` | acceleration, and the divisor `1 + drag * dt` applied to the velocity each step |
| `size_curve` | 1 to 16 sizes at equal steps of life, linear between |
| `size_jitter` | each particle's size is scaled by a factor in `1 - jitter .. 1` |
| `color_start`, `color_mid`, `color_end` | r g b a at life 0, 0.5 and 1, linear between |
| `blend` | `alpha` or `add` |
| `layer`, `flipbook_cols`, `flipbook_rows` | texture array layer; the cell shown goes from the first to the last over the life |
| `max_particles` | budget of this emitter |
| `lod_near`, `lod_far`, `lod_min` | emission LOD, below |

`rate` and bursts can be combined. `ludens check` validates a particles table like any other (ranges, `size_curve`
required). `ParticleSystem.add(row, x, y, z, seed)` makes an emitter from a row; `Emitter.burst(n)` queues n more
particles for the next step.

## The scene component

The scene component `particles` (`docs/scene-format.md` §8a) is the same fields as rows `particles.<field>`, plus
`particles.seed` (integer, default 1) and `particles.playing` (`true` / `false`, default `true`). Position comes from
the entity's `transform`. `particles_component(rows)` reads the rows of one entity under the table's schema and raises
an error with the file, the row and the reason (`particles.main.cone_deg: 200 is above the maximum 180`);
`ParticleSystem.add_component` makes the emitter. This repository has no scene loader yet (§8a is a design), so the
function takes the component's rows as text; the loader will call it once per entity.

## Determinism

The step uses `+ - * /` and `sqrt` on `Float64`, which are exactly rounded, and one splitmix64 stream per emitter. It
has no `sin`, `cos`, `exp` or `pow`; the cone's cosine is a Taylor sum. The random draws of a spawn are made even when
the spawn is dropped, so a drop does not shift later particles. The same seed, rows and `step` calls give the same bytes
on native and on wasm64: `pixi run -e wasm particles-same` compares the hash of every particle's state and the hash of
the records the pass uploads.

Step order: LOD scale, emission, then every particle ages and moves (velocity += gravity * dt; velocity /= 1 + drag *
dt; position += velocity * dt). A particle spawned in a step moves in that step. A dead particle is replaced by the last
one (swap-remove), which is deterministic and does not preserve order.

## Budgets, cap, LOD

- `max_particles` of an emitter: a spawn past it is dropped and counted in `dropped_budget`.
- `ParticleSystem.cap`, over all emitters: a spawn past it is dropped and counted in `dropped_cap`. Emitters are served
  in the order they were added.
- Distance LOD: the emission rate is multiplied by 1 up to `lod_near` metres from the camera, by `lod_min` from
  `lod_far`, linear between. `lod_far = 0` turns it off. A burst's count is scaled the same way (rounded down). What the
  scale removed is counted in `lod_skipped` (a rate of 600 / s over 60 steps at `lod_min` 0.25: 150 spawned, 450 skipped).
- The pass draws at most `PARTICLE_RECORDS` (131072) per frame; the surplus is counted in `ParticlePass.dropped_render`.

## The render pass

`ParticlePass` is a `RenderPass` (`app/render_pass.mojo`). It owns a `ParticleSystem`; the host calls
`advance(dt, view)` per simulation step. `prepare` packs the live particles for the frame's camera and uploads them
(one storage buffer, 3 vec4 per particle); `record_color` draws them.

```mojo
comptime Passes = Then[DefaultPasses, ParticlePass]
var r = SceneRendererOf[Passes](device, format, view)
_ = r.passes.second.system.add(particles_row(table, "spark"), 0.0, 1.0, 1.0, 7)
r.passes.second.advance(1.0 / 60.0, view)
```

- Alpha-blended particles of all emitters are sorted far to near along the camera's forward axis and drawn first (equal
  depth: by position in the packed list, so the order is total and repeatable). Additive particles follow, unsorted:
  addition does not depend on order.
- Both blend modes test depth against the scene and do not write it. Put the pass after the opaque passes.
- Particles are not lit, fogged, tone mapped or shadowed. Layer 0 (the white layer) draws a soft disc; another layer is
  sampled as it is, times the colour, with the flipbook cell for the particle's age.

## Measured

Machine: this session's container (shared CPU), Mojo 1.2.0, 2026-11-23.

CPU cost of one frame (`step` + sort + pack) for n live alpha particles, native serial against wasm64 under node
(`pixi run -e wasm bench`, medians of 20 frames, 5 at 100 000). The packed bytes are equal on both.

| live particles | native ms (step + pack) | wasm64 ms (step + pack) | wasm / native |
|---:|---:|---:|---:|
| 1 000 | 0.10 (0.01 + 0.10) | 0.23 (0.01 + 0.22) | 2.23 |
| 10 000 | 1.57 (0.06 + 1.51) | 2.55 (0.07 + 2.48) | 1.62 |
| 100 000 | 31.26 (0.72 + 30.54) | 33.49 (0.73 + 32.75) | 1.07 |

At 100 000 the sort is nearly all of the pack time, and 31 ms is two frames at 60 Hz. For that many particles the next
step is a GPU sort or an additive-only effect (additive particles skip the sort).

Whole frame on lavapipe (software Vulkan, a CPU rasteriser: `pixi run -e wasm test-particles-native`, 480 x 270, median
of 5, draw + readback). These are not GPU times; they show that the instanced draw scales with the particle count and
that the upload and sort are a small part at 1k and 10k.

| live particles | draw + readback ms | sort + pack alone ms |
|---:|---:|---:|
| 1 000 | 3.6 | 0.11 |
| 10 000 | 20.6 | 1.5 |
| 100 000 | 154.4 | 38.5 |

## Not done here

- Browser pixels: the native and wasm64 simulations and uploaded bytes are compared for equality (`particles-same`), and
  the native frame is checked against tile means (`tests/golden/particles_frame_tiles.txt`). A native-against-browser
  pixel row needs a page that draws a particle scene; the existing page (`shell/web/app.ts`, the `?selftest=parity` frame)
  draws a fixed reference frame and was not changed.
- A texture layer other than 0 in the pass is not drawn by any test; the flipbook cell is checked in the packed records
  (`tests/particles.mojo`), not in pixels.
- Particle rotation, soft particles (fade against scene depth), collision with the world, trails and sub-emitters.
- GPU simulation. The CPU step is the reference a GPU one would have to match.
- Emission shapes other than a point (box, sphere, mesh surface).
