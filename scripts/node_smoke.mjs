// B1 acceptance: app_init + 1 frame under node must not trap (no WebGPU -> wgpu* imports are stubs).
// usage: node node_smoke.mjs app.wasm <ludens-wasm-rt host.mjs> <wgpu-mojo dir> <miniaudio-mojo dir>

const [wasm, hostMjs, wgpuDir, maDir] = process.argv.slice(2);
const { bootApp } = await import(new URL("./node_app.mjs", import.meta.url));
const { rt } = await bootApp({ wasm, hostMjs, wgpuDir, maDir });

const [ptr, len] = rt.str_in("#canvas");
const app = rt.call("app_init", ptr, len, 640, 480);
console.log("app_init ->", app);
if (app === 0n) throw new Error("app_init returned 0");
console.log("app_frame ->", rt.call("app_frame", app, 1 / 60));
// Audio: 128 stereo frames must come back finite (silence is fine before any sound is started).
const buf = rt.alloc(128 * 2 * 4);
const rc = rt.call("app_audio_render", app, buf, 128);
const pcm = rt.f32(buf, 128 * 2);
if (rc !== 0 || !pcm.every(Number.isFinite)) throw new Error(`app_audio_render failed rc=${rc}`);
console.log("app_audio_render -> 0, 128 frames finite");
console.log("exports:", Object.keys(rt.exports).filter((k) => k.startsWith("app_")).join(","));
