# ludens-shell

A shell puts one general core (a single wasm64 module) into a platform's host program. The browser is the first shell
(`shell/web/`); `shell/desktop/` and `shell/mobile/` would sit beside it. Every shell does one thing: implement the
same imports (`host_*` belongs to [ludens-wasm-rt](https://github.com/Hundo1018/ludens-wasm-rt), `wgpu*` mirrors
`webgpu.h`, `net_*` is the WebSocket pair).

Dependency direction: ludens-shell → {ludens-engine, wgpu-mojo, miniaudio-mojo} → ludens-wasm-rt.

## Layout

| Path | What |
|---|---|
| `app/main.mojo` | The one Mojo entry. Calls `EmbedWorld`, wgpu and miniaudio Mojo to Mojo; the `app_*` exports are only the JS face. |
| `app/render.mojo` | Draws the bodies as boxes: one storage buffer, vertex pulling, no vertex buffer. |
| `app/bench.mojo` | The B3 bench entry (same source for native and wasm64). |
| `shell/web/` | `app.ts`, `index.html`, `worklet.js` (AudioWorklet ring), `serve.py` (COOP/COEP), `exports.d.ts` (generated). |
| `deps.lock` | Pinned revs of the three libraries; `scripts/deps.sh` exports them to `build/deps/`. |
| `wasm.toml` | Passive manifest for ludens-wasm-rt's driver (declares `net_*`, native section). |

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
