# Frame budgets (#123)

What one frame costs, where it goes, and a CI gate that fails when the work of the frame grows past a budget.

| part | where | runs on |
|---|---|---|
| per-segment timers, 300-frame ring (avg / p50 / p95 / p99 / max) | `app/frame_stats.mojo` | native and wasm64 |
| counters per frame | `FrameStats`, `app/render_pass.mojo` `DrawCounts`, `GameMode.counters` | native and wasm64 |
| overlay (F3) | `app/perf_overlay.mojo` | the web shell and any host that draws the HUD |
| Chrome trace | `scripts/frame_trace.py`, `app_frame_ring` | native and wasm64 |
| GPU pass timing | `app/gpu_timer.mojo` | native with timestamp queries; absent in the browser (see below) |
| budgets and the gate | `budgets.toml`, `scripts/perf_gate.py` | native on lavapipe and wasm64 under node |

## Timers

`App.frame` times each part of its frame with one clock (`std.time.perf_counter_ns`: the OS monotonic clock natively, the
runtime's `host_now_ns` = `performance.now()` in wasm64) and keeps the last 300 frames. Per segment the stats are
`[avg, p50, p95, p99, max]` in ns and the number of frames the segment ran in (nearest-rank percentiles).

| segment | what it times |
|---|---|
| `net` | the host's queued packets |
| `step` | input, the game's step and its sound cues |
| `physics`, `ai` | inside `step`, as the game reports them (`GameMode.physics_ns`, `GameMode.ai_ns`). Do not add them to `step` |
| `scene`, `push`, `hud` | building the draw list, handing it to the renderer, `GameMode.hud` + `Hud.set` |
| `draw` | the renderer's encode and submit (CPU side) |
| `present` | surface acquire and present |
| `audio` | the mixer's work in `app_audio_render` since the previous frame ended (it runs from the audio callback, not inside a frame; the time is attached to the next frame) |
| `frame` | the whole `app_frame` call: CPU time of the frame's own work. In the native runner the wait for the GPU (`device.poll`) is outside it |
| `gpu_shadow`, `gpu_scene`, `gpu_post`, `gpu_frame` | GPU time from timestamp queries, below |

A segment that did not run in a frame is recorded as "did not run" (-1 in the ring), never as 0. Its percentiles are over the
frames it ran in and `count` says how many. A game with no AI has an empty `ai` row.

## Counters

Set once per frame; the stats are `[last, avg, max]` over the ring.

| counter | how it is counted |
|---|---|
| `draw_calls` | draw calls of the scene's colour pass and the HUD. Each pass reports its own (`RenderPass.counts`), from the batches it draws: one per mesh used, one instanced primitive draw, one per HUD pipeline in use |
| `triangles` | index count / 3 times instances, per batch; a primitive is 384 triangles (1152 vertices); the HUD's vertices / 3 |
| `texture_bytes` | every texture the renderer holds, all mip levels and layers, from the texture's size and format (`app/gpu_bytes.mojo`); not the driver's allocation |
| `particles`, `bodies`, `ai_agents` | what the game reports (`GameMode.counters`; default 0). The demo game reports its bodies |

A frame that did not draw (the browser's `?offscreen` mode draws only on capture requests) keeps the draw counters of the last frame
that did: a counter that is not set again holds its value.

Texture bytes include the targets between post stages (`PostEffect.target_bytes`: `ThenPost`'s, `Join`'s and the nine of `Bloom`), the colour-grading LUT (16 ^ 3 by default, `set_lut` changes it) and the multisampled colour and depth of MSAA 4x (`MsaaTargets.bytes`, four samples each). Not counted: the shadow passes' and the post stages' draws, the right eye of a stereo pipeline, the aux pass. A game that
draws a lot there has more draw calls than `draw_calls` says.

## Overlay

F3 toggles the overlay (`KEY_F3`, `shell/web/keys.ts`): one row per segment that ran (avg, p95, p99, max in ms over the last
300 frames), `gpu absent (no timestamp queries)` when no frame had GPU timing, and the six counters (last and max). The text
is built by `overlay_lines` so a test reads what the screen shows.

## Trace

`app_frame_ring(app, ptr)` writes the frames in the ring, oldest first, 21 i64 each (15 segment times, then 6 counters).
`scripts/frame_trace.py native|wasm OUT.json` runs the scripted scene and writes a Chrome trace (load it in Perfetto or
`chrome://tracing`): frames end to end, `X` events for the segments (physics and ai inside step; audio and the GPU passes on
their own threads), `C` events for the counters. `perf-gate` writes `build/perf_gate/trace.json` on every run and CI uploads it.

## GPU pass timing

`GpuTimer` (`app/gpu_timer.mojo`) writes a timestamp on the frame's command encoder before the shadow passes, after them,
after the scene colour pass, and after the post stages and HUD; the differences are `gpu_shadow`, `gpu_scene` and `gpu_post`,
and `gpu_frame` is their sum. It needs the device to be requested with the timestamp-query feature and
wgpu-native's timestamps-inside-encoders feature (`gpu_timer_features()`); the native runner asks for them and falls back to a plain device.
Without the features `SceneRendererOf.enable_gpu_timing` returns False and the GPU rows are "did not run".

In the browser there is no GPU timing: wgpu-mojo's web host traps in `wgpuDeviceCreateQuerySet` and `wgpuCommandEncoderWriteTimestamp`
(`build/deps/wgpu-mojo/web/webgpu_host.mjs`), and WebGPU has no encoder-level timestamp; a browser would use the
`timestampWrites` of the render-pass descriptor, which wgpu-mojo's pass helpers do not take (they pass a null pointer). That
is a change in wgpu-mojo, not here. The overlay and the gate report the rows as absent.

The native timer measures lavapipe (software Vulkan) in CI, so `gpu_*` there is CPU time spent rasterising; it is not gated.

## Budgets and the gate

`budgets.toml` (a project's own file next to its game; `--budgets` names another):

```toml
[scene]                 # the scripted scene of docs/automation.md
name = "arena"
seed = 7
frames = 600            # at least 300: the budgets are over the last 300
width = 1280
height = 720

[counters]              # work counts: FAIL when the largest value in the last 300 frames is above
draw_calls = 4
triangles = 4000
texture_bytes = 30000000
particles = 0
bodies = 12
ai_agents = 0

[frame_ms]              # p95 of a segment in ms: WARN when above
frame = 0.5
```

`pixi run -e wasm perf-gate` runs the scene twice. Natively on lavapipe (`app/frame_budget.mojo`, the real renderer, an
offscreen target) for `draw_calls`, `triangles`, `texture_bytes` and the CPU time of each segment. As wasm64 under node
(`scripts/frame_stats_node.mjs`, through the `window.game` hook: seed, scene, `hold` and `press` as in `docs/automation.md`) for
the game's own counters and the step, physics and audio time of the real build. Counters both runs report (`particles`,
`bodies`, `ai_agents`) must be equal; a difference fails.

Exit codes: 0 passed (warnings possible), 1 a counter is over its budget or the runs disagree, 2 the budgets file is wrong
(unknown key, negative or non-numeric budget, a scene shorter than the ring). A budget is a maximum: a value equal to it passes.
Under GitHub Actions the failures and warnings are annotations, and the table goes to the job summary.

The scripted scene's three crates are asleep by frame 100 (the world's sleeping flag read at frames 100, 300, 450 and 600), so the timed
frames step the ball and sleeping crates: `step` and `physics` are the cost of a settled scene, not of a pile in motion. The
counters do not change (`bodies` counts every body). CI runs `perf-gate --runs 3` and judges the run with the median frame p95.

Why counters fail and times warn: a draw-call count is the same on every machine, so a rise is a change in the code. A p95
on a shared runner moves with the machine. `--runs N --spread` runs the native scene N times and prints the min, median and max
of each p95, which is the room a time budget needs.

### Spread of the wall-clock p95

The native scene, 1280x720, 600 frames, 10 runs each, on this container's 4 cores (the p95 of each run, in ms):

| segment | idle: min / median / max | every core busy: min / median / max |
|---|---|---|
| `step` | 0.043 / 0.047 / 0.052 | 0.030 / 0.041 / 0.049 |
| `draw` | 0.123 / 0.133 / 0.155 | 0.091 / 0.140 / 0.168 |
| `frame` | 0.171 / 0.179 / 0.196 | 0.124 / 0.182 / 0.208 |
| `gpu_frame` (lavapipe) | 1.926 / 2.164 / 2.308 | 8.831 / 9.734 / 10.393 |

`frame` is budgeted at 0.5 ms, 2.4 times the largest of the 20 runs. `gpu_frame` is not budgeted: it moved 4.5 times between
idle and loaded. The counters did not move in any run (2 draw calls, 3,460 triangles, 25,881,248 texture bytes, 9 bodies; 28,109,472 since the IES table, 128 KB, and the 8 light cookies, 2 MB).

### Cost of the timers and counters

`scripts/frame_ab.py` runs the native frame runner of `main` (before this change) and of this change alternately, 10 runs each,
1280x720, 600 frames, on lavapipe (ms; p95 also min..max over the runs):

| segment | before p50 | after p50 | before p95 | after p95 |
|---|---:|---:|---|---|
| `step` | 0.028 | 0.031 | 0.043 (0.039..0.055) | 0.047 (0.044..0.058) |
| `draw` | 0.083 | 0.095 | 0.122 (0.100..0.157) | 0.136 (0.117..0.154) |
| `frame` | 0.113 | 0.130 | 0.161 (0.134..0.206) | 0.182 (0.158..0.205) |

The p50 of `frame` rose by 0.017 ms; the p95 ranges overlap. The "after" runner has GPU timing on (3 timestamps, a resolve and a
copy per frame, in `draw`); the browser has none. `step` includes `GameMode.counters`, which lists the world's bodies once per
frame. The two were not measured apart.

## Tests

| command | what it checks | CI |
|---|---|---|
| `pixi run -e wasm test-frame-stats` | the ring against worked values (percentiles of 1..100 us, 450 frames into 300, segments that did not run, counters, audio attribution, ring export, overlay text) | parity.yml |
| `pixi run -e wasm test-frame-counters` | draw calls, triangles and texture bytes of a known scene on lavapipe; the GPU timer (3 marks, 2 spans, the span with work is longer; no features, no timer) | parity.yml |
| `pixi run -e wasm test-perf-gate` | the stats layout against the Mojo source; the gate's pass / fail / warn rules; the trace; the wasm64 and native runs; an injected breach (`draw_calls = 1`) exits 1 | parity.yml |
| `pixi run -e wasm perf-overlay-web` | in headless Chrome: F3 draws the overlay and F3 again hides it; `app_frame_stats` after 300 frames has the demo scene's counters (texture bytes equal to the sizes of the 960x540 canvas) and no GPU rows | parity.yml |
| `pixi run -e wasm perf-gate` | the shipped `budgets.toml` against the scripted scene | parity.yml |
| `pixi run -e wasm mutation-perf` | each test above fails under one deliberate change to the code it covers; a test that exits non-zero without naming a failed check (a crash) counts as an escape | not in CI (about 40 minutes) |

## Not done

- GPU timing in the browser (above).
- Counters for the shadow passes, post stages and the right eye of a stereo pipeline.
- Memory by category beyond `texture_bytes` (no buffer or CPU-heap counter).
- An AI subsystem: `ai` and `ai_agents` are in the layout and the trait, the demo game has none.
- A budget on `gpu_*`: the only GPU in CI is lavapipe.
