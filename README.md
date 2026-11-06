# ludens-shell

ludens-shell is three things around one general core, a single wasm64 module:

- **Platform shells** (`shell/web/`; `shell/desktop/` and `shell/mobile/` would sit beside it) put the module into a
  platform's host program. A shell does one thing: implement the module's imports (`host_*` belongs to
  [ludens-wasm-rt](https://github.com/Hundo1018/ludens-wasm-rt), `wgpu*` mirrors `webgpu.h`, `net_*` is the
  WebSocket pair, `os_*` is the platform services planned in #8). It knows no application.
- **Shared UI** (`ui/`): text, layout, input and widgets for both the game and the editor. Mojo, drawn through wgpu.
- **Applications**: the game (`app/`) and the editor (`editor/`). Both are Mojo, compiled into the same module.

Dependency direction: ludens-shell → {ludens-engine, wgpu-mojo, miniaudio-mojo} → ludens-wasm-rt.

## Layout

| Path | What |
|---|---|
| `app/main.mojo` | The one Mojo entry. Calls `EmbedWorld`, wgpu and miniaudio Mojo to Mojo; the `app_*` exports are only the JS face. |
| `app/render.mojo` | Draws the bodies as boxes: one storage buffer, vertex pulling, no vertex buffer. |
| `app/bench.mojo` | The B3 bench entry (same source for native and wasm64). |
| `ui/` | Shared UI toolkit (#17). Depends on the standard library and wgpu-mojo only. Empty until #17. |
| `editor/` | The editor: command layer (`command.mojo`, `entry.mojo`) now; panels, gizmos, undo and play-in-editor follow (#10). Mojo only. |
| `tests/editor_command.mojo` | Command-layer test: the GUI and CLI entries give the same world hash. |
| `editor/scene_text.mojo`, `editor/core_main.mojo` | The flat text form of a scene (`path = value` rows) and `ludens-core`, the native process the command line drives. |
| `scripts/ludens.py`, `scripts/build_core.py` | The `ludens` command line and the build of the native core. |
| `tests/test_cli.py` | The command line end to end, across processes. |
| `scripts/check_layout.py` | The directory rules below, as a check with a selftest. |
| `shell/web/` | `app.ts`, `index.html`, `worklet.js` (AudioWorklet ring), `serve.py` (COOP/COEP), `exports.d.ts` (generated). |
| `deps.lock` | Pinned revs of the three libraries; `scripts/deps.sh` exports them to `build/deps/`. |
| `wasm.toml` | Passive manifest for ludens-wasm-rt's driver (declares `net_*`, native section). |

## Rules

Checked by `scripts/check_layout.py` (`pixi run -e wasm check-layout`; `--selftest` injects one violation per rule).

1. **Directories.**
   - `shell/<platform>/` implements imports only. It holds no editor or UI symbol (`editor_*`, `ed_*`, `ui_*`),
     no path into `editor/` or `ui/`, and uses only generic `app_*` exports.
   - `ui/` imports the standard library, `wgpu` and itself. It never imports engine packages, `app/` or `editor/`,
     so it can be split out as a library unchanged.
   - `editor/` and `ui/` hold Mojo (and Markdown) only: no TS, JS, HTML or CSS.
   - Game-specific UI (HUD, menu flow, gamepad navigation, styling) is written by the game's author in `app/` on top
     of `ui/`. This repo provides `ui/` and the sample game's demo HUD.
2. **Commands.** Every editing operation is a command in `editor/`: a name, text arguments and an inverse. The GUI and
   the CLI (#11) call the same commands, so what the GUI does can be scripted and replayed in CI. The test
   `pixi run -e wasm test-editor` moves a body once through the GUI entry and once through the CLI entry and compares
   `EmbedWorld.hash()`.
3. **Scene format.** Defined by this repo (#9). The engine provides schema read/write, diffs and parity with the
   deterministic snapshot (ludens-engine #82).
4. **Built-ins use the extension API** (#18). Pending until the registration points exist; the check is listed in
   `check_layout.py` and switched on by `EXTENSION_API_ENFORCED`.

## Command line

`ludens` edits and runs a scene without a GUI, through the same Mojo command layer the editor uses (`ludens-core`,
a native build of `editor/`).

```
pixi run -e wasm ludens new demo         # demo/ludens.toml + demo/world.scene
cd demo
pixi run -e wasm ludens list             # index, handle, position of every body
pixi run -e wasm ludens cmd move_body 2 0.7 3.0 -0.3     # edit the scene in place
pixi run -e wasm ludens run 120          # step 120 ticks, print the world hash
pixi run -e wasm ludens script edits.txt # a file of commands, one per line (`undo` allowed)
pixi run -e wasm test-cli                # this section, end to end
```

A scene file is `path = value` rows (`embed.scene_io` in ludens-engine); it holds the authored state, not the
deterministic snapshot. A failed command exits 1, names what is wrong (a script error names its line) and writes
nothing. Subcommands for assets, builds and replay arrive with #12, #15 and #13.

## Build and run

```
pixi run -e wasm build-wasm     # build/app.wasm (one wasm64 module; the declare and signature audits run in the driver)
pixi run -e wasm smoke-node     # B1: app_init + one frame under node does not trap
pixi run -e wasm build-web      # build/web/
pixi run -e wasm test-web       # headless Firefox (all checks) and Chrome (all but pixels)
pixi run -e wasm serve-web      # http://127.0.0.1:8000 (needs a WebGPU browser; memory64 needs Chrome 133+ / Firefox 134+)
pixi run -e wasm parity         # native vs wasm64 hash of a sin/cos orbit (the B4 gate's first step)
pixi run -e wasm bench          # B3 table below
```

Safari has no memory64, so the web shell does not run on iOS.

## Calls across the JS boundary

Measured by `?selftest` (counts every `wgpu*` import and, by patching the WebGPU prototypes, every browser WebGPU
call), steady state, Firefox 157 and Chrome, identical in both:

| Per rendered frame | Count |
|---|---:|
| JS → wasm exports | 1 (`app_frame`) |
| wasm → JS imports (`wgpu*` entries into the translator) | 15 |
| Browser WebGPU API calls made by the translator | 11 |

The 15 imports are one each of: SurfaceGetCurrentTexture, QueueWriteBuffer, DeviceCreateCommandEncoder,
TextureCreateView, CommandEncoderBeginRenderPass, RenderPassEncoderSetPipeline, RenderPassEncoderSetBindGroup,
RenderPassEncoderDraw, TextureViewRelease, RenderPassEncoderEnd, RenderPassEncoderRelease, CommandEncoderFinish,
CommandEncoderRelease, QueueSubmit, CommandBufferRelease. The count does not grow with
the number of bodies: all poses go up in one `wgpuQueueWriteBuffer`.

Audio is separate: `app_audio_render` is called once per 128-frame block, about six times per animation frame,
from the main thread into the shared ring.

### Pose upload

Poses leave Mojo as one contiguous `f32` array (12 floats per body) and go to `wgpuQueueWriteBuffer(ptr, size)`;
the translator passes the browser a view of wasm memory (`rt.bytes(ptr, size)`, no `.slice()`; wgpu-mojo
`57d2810`), so JS copies nothing. ludens-engine stores bodies as an array of structs (`QuatBody6`), not as SoA
buffers, so there is still a gather per frame inside Mojo; it costs 0.01 ms at 1e3 bodies and 0.15 ms at 1e4
(`gather` below).

## Bench: wasm64 against native

`app/bench.mojo` per frame: one physics tick, then the pose gather. One layer of unit boxes resting on a floor, so
every body is in contact; median of 30 (1e3) or 10 (1e4) frames after two warm-up frames in the same world.
Native is built with the engine's own native config (`native parallel`) and with `LUDENS_SERIAL=True`
(`native serial`, the same single-threaded code path as wasm). wasm64 runs under node 24.

| bodies | native serial ms/frame | wasm64 ms/frame | wasm / native serial | native parallel ms/frame | wasm / native parallel | pose hash wasm = native serial |
|---:|---:|---:|---:|---:|---:|:---:|
| 1000 | 21.53 (21.51 + 0.02) | 23.31 (23.29 + 0.01) | 1.08x | 20.36 (20.35 + 0.01) | 1.14x | yes |
| 10000 | 217.56 (217.38 + 0.18) | 255.85 (255.72 + 0.12) | 1.18x | 209.09 (208.93 + 0.15) | 1.22x | yes |

Numbers in parentheses are physics + gather. Caveats: one run, on a shared machine with a load average around 10,
x86-64 baseline target (no FMA); native "parallel" is no faster than serial at these sizes; this is CPU work only,
not GPU time. The hash column compares the final pose array bit for bit.

Pins when measured: ludens-engine `61a7bfd86f93`, wgpu-mojo `57d28106cd15`, miniaudio-mojo `fc84c21d045d`,
ludens-wasm-rt `b23d53d`.

## B4: native / web parity gate

```
pixi run -e wasm parity-gate    # scripts/parity_gate.py; exit 1 if any comparison fails
```

| Comparison | Native side | Web side | Rule |
|---|---|---|---|
| World hash | `app/parity.mojo` built `--target native` (serial engine, `x86-64`, no FMA) | same source, wasm64 under node | equal |
| PCM hash (FNV over f32 bits) | same run | same | equal |
| Pixels (960x540 RGBA8, 240 frames) | `app/pixels.mojo` through wgpu-native, headless offscreen | `app_reference_*` in Firefox, Chrome | per-browser row of `shell/web/pixel_tolerance.json` |

The same `Sim` drives all three (16 boxes falling on a floor, a contact-driven tone). The pixel target is a pinned
RGBA8Unorm texture the app owns, read back with `FrameCapture`; the canvas is not read. Chrome is measured in
offscreen mode (`?selftest=parity-offscreen`) because headless Chrome loses its device after a canvas draw.

Pixel tolerance (max channel delta of any pixel, fraction of pixels over 8 and over 32), measured on an Intel Iris Xe
(Vulkan) against wgpu-native on the same GPU, and the limits set just above:

| Browser | Measured | Limit |
|---|---|---|
| Firefox 157 | 0 / 0 / 0 | 2 / 0 / 0 |
| Chrome | 113 / 8.7e-5 / 8.3e-5 | 160 / 3e-4 / 3e-4 |

Chrome's differences are a few edge pixels. The limits are for this GPU; CI renders on lavapipe, so the rows may need
re-measuring there (`.github/workflows/parity.yml`, not yet run on GitHub).

## B5: recording and the WebSocket bridge

**Recording** (`shell/web/record.ts`): `record(canvas, seconds, audio?)` takes `canvas.captureStream(60)`, adds the
AudioWorklet output through a `MediaStreamAudioDestinationNode`, and lets `MediaRecorder` mux one WebM (VP9 / VP8 /
AV1 with Opus, first supported). MediaRecorder is used instead of WebCodecs because it muxes natively; a WebCodecs
path would need its own WebM muxer. `?selftest=record` records 5 s in Firefox, uploads the file to the dev server
(`PUT /upload/recorded.webm` -> `build/recorded.webm`), and `scripts/check_webm.py` decodes it end to end with ffmpeg.

**Network** (`app/net.mojo`, `shell/web/net_host.mjs`): two scalar imports, declared in `wasm.toml` as `net_*`.

| Import | Meaning |
|---|---|
| `net_send(ptr, len) -> i32` | one WebSocket binary message; 0 sent or queued until the socket opens, -1 no socket |
| `net_poll(buf, cap) -> i64` | next received message copied to `buf`: its length, 0 if none, -1 if it exceeds `cap` (stays queued) |

The socket opens from `?ws=<url>`. `app_frame` drains up to 16 packets per frame into a 64 KiB buffer
(one `net_poll` import call per frame when idle, not counted in the wgpu table above); `app_net_send`,
`app_net_packets`, `app_net_last_ptr`, `app_net_last_len` are the JS-facing exports. Empty messages cannot be told
from "none" and are not delivered. `scripts/echo_server.py` is a stdlib RFC 6455 echo server for the round trip
(`?selftest=net:<port>`, both browsers).
